package main

import (
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const modelAPIRouteStateFile = "model-api-route.json"

type ModelAPIRouteSync struct {
	mu      sync.Mutex
	appData string
}

type modelAPIRouteState struct {
	Port      int    `json:"port"`
	UpdatedAt string `json:"updatedAt"`
}

type portForwardState struct {
	Forwards []portForward `json:"forwards"`
}

type portForward struct {
	MacHost   string `json:"macHost"`
	MacPort   int    `json:"macPort"`
	VMPort    int    `json:"vmPort"`
	Protocol  string `json:"protocol"`
	Direction string `json:"direction"`
}

func NewModelAPIRouteSync(appDir string) *ModelAPIRouteSync {
	return &ModelAPIRouteSync{appData: defaultAppDataDir(appDir)}
}

func defaultAppDataDir(appDir string) string {
	if v := strings.TrimSpace(os.Getenv("VEGPU_APP_DATA_DIR")); v != "" {
		return expandPath(v)
	}
	if home, err := os.UserHomeDir(); err == nil {
		return filepath.Join(home, "Library", "Application Support", "vEGPU", "Machine")
	}
	return appDir
}

func (s *ModelAPIRouteSync) Sync(cfg AppConfig) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	port := cfg.Server.Port
	if !validProxyPort(port) {
		port = 9292
	}

	machineDir := filepath.Join(s.appData, "machines", "default")
	portsPath := filepath.Join(machineDir, "ports.json")
	statePath := filepath.Join(machineDir, modelAPIRouteStateFile)

	previous, _ := readModelAPIRouteState(statePath)
	ports, err := readPortForwardState(portsPath)
	if err != nil {
		return err
	}

	forwards := make([]portForward, 0, len(ports.Forwards)+1)
	for _, forward := range ports.Forwards {
		normalized := normalizePortForward(forward)
		if isModelAPIConflict(normalized, port) {
			continue
		}
		if previous.Port != 0 && previous.Port != port && isModelAPIConflict(normalized, previous.Port) {
			continue
		}
		forwards = append(forwards, normalized)
	}
	forwards = append(forwards, portForward{
		MacHost:   vmnetGatewayHost,
		MacPort:   port,
		VMPort:    port,
		Protocol:  "tcp",
		Direction: "macToVM",
	})
	sortPortForwards(forwards)

	if err := writeJSONAtomic(portsPath, portForwardState{Forwards: forwards}); err != nil {
		return err
	}
	return writeJSONAtomic(statePath, modelAPIRouteState{
		Port:      port,
		UpdatedAt: time.Now().UTC().Format(time.RFC3339),
	})
}

func (s *ModelAPIRouteSync) Endpoints(cfg AppConfig) map[string]string {
	port := cfg.Server.Port
	if !validProxyPort(port) {
		port = 9292
	}
	return map[string]string{
		"macBaseURL": "http://127.0.0.1:" + strconvPort(port),
		"vmBaseURL":  "http://" + vmnetGatewayHost + ":" + strconvPort(port),
	}
}

func readModelAPIRouteState(path string) (modelAPIRouteState, error) {
	var state modelAPIRouteState
	err := readJSONFile(path, &state)
	if errors.Is(err, os.ErrNotExist) {
		return state, nil
	}
	return state, err
}

func readPortForwardState(path string) (portForwardState, error) {
	var state portForwardState
	err := readJSONFile(path, &state)
	if errors.Is(err, os.ErrNotExist) {
		return state, nil
	}
	return state, err
}

func normalizePortForward(forward portForward) portForward {
	forward.Protocol = strings.ToLower(strings.TrimSpace(forward.Protocol))
	if forward.Protocol == "" {
		forward.Protocol = "tcp"
	}
	forward.Direction = strings.TrimSpace(forward.Direction)
	if forward.Direction == "" {
		forward.Direction = "vmToMac"
	}
	return forward
}

func isModelAPIConflict(forward portForward, port int) bool {
	return forward.Direction == "macToVM" &&
		forward.Protocol == "tcp" &&
		forward.VMPort == port
}

func sortPortForwards(forwards []portForward) {
	sort.SliceStable(forwards, func(i, j int) bool {
		if forwards[i].Direction != forwards[j].Direction {
			return forwards[i].Direction < forwards[j].Direction
		}
		if forwards[i].Protocol != forwards[j].Protocol {
			return forwards[i].Protocol < forwards[j].Protocol
		}
		if forwards[i].VMPort != forwards[j].VMPort {
			return forwards[i].VMPort < forwards[j].VMPort
		}
		return forwards[i].MacPort < forwards[j].MacPort
	})
}

func validProxyPort(port int) bool {
	return port > 0 && port < 65536
}

func strconvPort(port int) string {
	return strconv.Itoa(port)
}
