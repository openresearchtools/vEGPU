package main

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const deviceProbeTimeout = 3 * time.Second
const bridgeDeviceProbeTimeout = 8 * time.Second
const deviceProbeCacheTTL = 5 * time.Minute
const deviceProbeCoalesceWindow = 2 * time.Second

type RuntimeService struct {
	appDir        string
	store         *ConfigStore
	client        *http.Client
	deviceCacheMu sync.Mutex
	deviceCacheAt time.Time
	deviceCache   []DeviceInfo
	deviceErr     error
	deviceCached  bool
	deviceProbeMu sync.Mutex
}

type RuntimeStatus struct {
	Path        string `json:"path"`
	Exists      bool   `json:"exists"`
	Version     string `json:"version"`
	Error       string `json:"error,omitempty"`
	ReleaseRepo string `json:"releaseRepo"`
}

type RuntimeFlag struct {
	Name        string   `json:"name"`
	Aliases     []string `json:"aliases"`
	ValueName   string   `json:"valueName,omitempty"`
	Description string   `json:"description"`
	Category    string   `json:"category"`
}

type DeviceInfo struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Backend     string `json:"backend"`
	TotalMiB    int64  `json:"totalMiB"`
	FreeMiB     int64  `json:"freeMiB"`
	PCIAddress  string `json:"pciAddress,omitempty"`
	UUID        string `json:"uuid,omitempty"`
	Remote      bool   `json:"remote"`
	Endpoint    string `json:"endpoint,omitempty"`
	Location    string `json:"location,omitempty"`
}

func NewRuntimeService(appDir string, store *ConfigStore) *RuntimeService {
	return &RuntimeService{
		appDir: appDir,
		store:  store,
		client: &http.Client{Timeout: 60 * time.Second},
	}
}

func (r *RuntimeService) LlamaServerPath(cfg AppConfig) string {
	path := strings.TrimSpace(cfg.Runtime.LlamaServerPath)
	if path == "" {
		path = "./llama-server"
	}
	return r.resolveRuntimeConfigPath(path)
}

func (r *RuntimeService) resolveRuntimeConfigPath(path string) string {
	path = strings.TrimSpace(path)
	if filepath.IsAbs(path) {
		return filepath.Clean(expandPath(path))
	}
	if strings.HasPrefix(path, "./") || path == "." || strings.HasPrefix(path, "../") || path == ".." {
		return filepath.Clean(filepath.Join(r.WorkDir(), path))
	}
	if root := r.ProfileRoot(); root != "" {
		return filepath.Clean(filepath.Join(root, path))
	}
	return filepath.Clean(filepath.Join(r.appDir, path))
}

func (r *RuntimeService) WorkDir() string {
	if r.store != nil {
		if dir := filepath.Dir(r.store.Path()); dir != "." && strings.TrimSpace(dir) != "" {
			return dir
		}
	}
	return r.appDir
}

func (r *RuntimeService) ProfileRoot() string {
	return profileRootFromWorkDir(r.WorkDir())
}

func (r *RuntimeService) command(ctx context.Context, path string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, path, args...)
	if workDir := r.WorkDir(); workDir != "" {
		_ = os.MkdirAll(workDir, 0o755)
		cmd.Dir = workDir
	}
	return cmd
}

func (r *RuntimeService) Status(ctx context.Context) RuntimeStatus {
	cfg := r.store.Get()
	path := r.LlamaServerPath(cfg)
	status := RuntimeStatus{Path: path, ReleaseRepo: cfg.Runtime.ReleaseRepo}
	if _, err := os.Stat(path); err != nil {
		status.Exists = false
		status.Error = err.Error()
		return status
	}
	status.Exists = true
	cmd := r.command(ctx, path, "--version")
	out, err := cmd.CombinedOutput()
	raw := strings.TrimSpace(string(out))
	if err != nil {
		status.Error = err.Error()
		if raw != "" {
			status.Error = raw
		}
	}
	status.Version = cleanRuntimeVersion(raw)
	return status
}

func cleanRuntimeVersion(raw string) string {
	lines := strings.Split(raw, "\n")
	picked := []string{}
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "version:") || strings.HasPrefix(trimmed, "built with ") {
			picked = append(picked, trimmed)
		}
	}
	if len(picked) > 0 {
		return strings.Join(picked, "\n")
	}
	return raw
}

func (r *RuntimeService) Flags(ctx context.Context) []RuntimeFlag {
	cfg := r.store.Get()
	path := r.LlamaServerPath(cfg)
	cmd := r.command(ctx, path, "--help")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return defaultRuntimeFlags()
	}
	flags := parseRuntimeFlags(string(out))
	if len(flags) == 0 {
		return defaultRuntimeFlags()
	}
	return flags
}

func parseRuntimeFlags(help string) []RuntimeFlag {
	lines := strings.Split(help, "\n")
	re := regexp.MustCompile(`^\s*((?:-\S+,\s*)*--[a-zA-Z0-9][a-zA-Z0-9-]*)(?:\s+([A-Z][A-Z0-9_|{},.-]*|<[^>]+>|\[[^\]]+\]))?\s*(.*)$`)
	var flags []RuntimeFlag
	for _, line := range lines {
		m := re.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		aliases := splitAliases(m[1])
		name := ""
		for _, alias := range aliases {
			if strings.HasPrefix(alias, "--") {
				name = strings.TrimPrefix(alias, "--")
				break
			}
		}
		if name == "" {
			continue
		}
		flags = append(flags, RuntimeFlag{
			Name:        name,
			Aliases:     aliases,
			ValueName:   strings.TrimSpace(m[2]),
			Description: strings.TrimSpace(m[3]),
			Category:    flagCategory(name),
		})
	}
	sort.Slice(flags, func(i, j int) bool {
		if flags[i].Category == flags[j].Category {
			return flags[i].Name < flags[j].Name
		}
		return flags[i].Category < flags[j].Category
	})
	return flags
}

func splitAliases(raw string) []string {
	parts := strings.Split(raw, ",")
	out := []string{}
	for _, part := range parts {
		fields := strings.Fields(strings.TrimSpace(part))
		if len(fields) > 0 {
			out = append(out, fields[0])
		}
	}
	return out
}

func flagCategory(name string) string {
	switch {
	case strings.Contains(name, "ctx") || strings.Contains(name, "predict"):
		return "context"
	case strings.Contains(name, "batch") || strings.Contains(name, "parallel"):
		return "batching"
	case strings.Contains(name, "gpu") || strings.Contains(name, "device") || strings.Contains(name, "split") || name == "rpc":
		return "devices"
	case strings.Contains(name, "cache") || strings.Contains(name, "kv"):
		return "kv-cache"
	case strings.Contains(name, "mmproj") || strings.Contains(name, "image"):
		return "multimodal"
	case strings.Contains(name, "spec"):
		return "speculative"
	case strings.Contains(name, "flash"):
		return "performance"
	default:
		return "general"
	}
}

func defaultRuntimeFlags() []RuntimeFlag {
	names := []string{"ctx-size", "predict", "batch-size", "ubatch-size", "parallel", "gpu-layers", "device", "rpc", "split-mode", "tensor-split", "main-gpu", "flash-attn", "kv-unified", "kv-offload", "cache-type-k", "cache-type-v", "mmproj", "mmproj-offload", "embedding", "pooling"}
	out := make([]RuntimeFlag, 0, len(names))
	for _, name := range names {
		out = append(out, RuntimeFlag{Name: name, Aliases: []string{"--" + name}, Category: flagCategory(name)})
	}
	return out
}

func (r *RuntimeService) Devices(ctx context.Context) ([]DeviceInfo, error) {
	if devices, err, ok := r.cachedDevices(); ok {
		return devices, err
	}
	return nil, nil
}

func (r *RuntimeService) RefreshDevices(ctx context.Context) ([]DeviceInfo, error) {
	r.deviceProbeMu.Lock()
	defer r.deviceProbeMu.Unlock()

	if devices, err, ok := r.cachedDevicesYoungerThan(deviceProbeCoalesceWindow); ok {
		return devices, err
	}
	previousDevices, _, hadPreviousDevices := r.cachedDevicesSnapshot()

	cfg := r.store.Get()
	path := r.LlamaServerPath(cfg)
	rpcEndpoints := externalRPCEndpoints(enabledRPCEndpoints(cfg))

	type probeResult struct {
		name    string
		devices []DeviceInfo
		err     error
	}

	results := make(chan probeResult, 3)
	probeCount := 0
	runProbe := func(name string, timeout time.Duration, fn func(context.Context) ([]DeviceInfo, error)) {
		probeCount++
		go func() {
			probeCtx, cancel := context.WithTimeout(ctx, timeout)
			defer cancel()
			devices, err := fn(probeCtx)
			results <- probeResult{name: name, devices: devices, err: err}
		}()
	}

	runProbe("local", deviceProbeTimeout, func(probeCtx context.Context) ([]DeviceInfo, error) {
		devices, err := r.listDevices(probeCtx, path, []string{"--list-devices"})
		for i := range devices {
			if devices[i].Remote {
				devices[i].Location = devices[i].Endpoint
			} else {
				devices[i].Location = "macOS"
			}
		}
		return devices, err
	})
	if len(rpcEndpoints) > 0 {
		runProbe("rpc", deviceProbeTimeout, func(probeCtx context.Context) ([]DeviceInfo, error) {
			return r.rpcDevices(probeCtx, path, rpcEndpoints)
		})
	}
	runProbe("bridge", bridgeDeviceProbeTimeout, func(probeCtx context.Context) ([]DeviceInfo, error) {
		devices, err := r.BridgeDevicesIfRunning(probeCtx)
		for i := range devices {
			devices[i].Location = "PEGPU VM"
		}
		return devices, err
	})

	var local, rpc, bridge []DeviceInfo
	var localErr, rpcErr, bridgeErr error
	for i := 0; i < probeCount; i++ {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case result := <-results:
			switch result.name {
			case "local":
				local, localErr = result.devices, result.err
			case "rpc":
				rpc, rpcErr = result.devices, result.err
			case "bridge":
				bridge, bridgeErr = result.devices, result.err
			}
		}
	}

	if bridgeErr != nil && len(bridge) == 0 && hadPreviousDevices {
		bridge = cachedVMDevices(previousDevices)
	}
	devices := mergeDeviceInfo(local, rpc, bridge)
	err := combineProbeErrors(
		probeError{"macOS devices", localErr},
		probeError{"RPC devices", rpcErr},
		probeError{"VM devices", bridgeErr},
	)
	if len(devices) > 0 {
		r.storeDeviceCache(devices, err)
		return devices, err
	}
	r.storeDeviceCache(devices, err)
	return devices, err
}

func (r *RuntimeService) cachedDevices() ([]DeviceInfo, error, bool) {
	return r.cachedDevicesYoungerThan(deviceProbeCacheTTL)
}

func (r *RuntimeService) cachedDevicesYoungerThan(maxAge time.Duration) ([]DeviceInfo, error, bool) {
	r.deviceCacheMu.Lock()
	defer r.deviceCacheMu.Unlock()
	if !r.deviceCached || r.deviceCacheAt.IsZero() || time.Since(r.deviceCacheAt) > maxAge {
		return nil, nil, false
	}
	return cloneDeviceInfo(r.deviceCache), r.deviceErr, true
}

func (r *RuntimeService) cachedDevicesSnapshot() ([]DeviceInfo, error, bool) {
	r.deviceCacheMu.Lock()
	defer r.deviceCacheMu.Unlock()
	if !r.deviceCached || r.deviceCacheAt.IsZero() {
		return nil, nil, false
	}
	return cloneDeviceInfo(r.deviceCache), r.deviceErr, true
}

func (r *RuntimeService) storeDeviceCache(devices []DeviceInfo, err error) {
	r.deviceCacheMu.Lock()
	defer r.deviceCacheMu.Unlock()
	r.deviceCacheAt = time.Now()
	r.deviceCache = cloneDeviceInfo(devices)
	r.deviceErr = err
	r.deviceCached = true
}

func cloneDeviceInfo(devices []DeviceInfo) []DeviceInfo {
	if devices == nil {
		return nil
	}
	return append([]DeviceInfo(nil), devices...)
}

func cachedVMDevices(devices []DeviceInfo) []DeviceInfo {
	out := make([]DeviceInfo, 0, len(devices))
	for _, dev := range devices {
		if strings.EqualFold(strings.TrimSpace(dev.Location), "PEGPU VM") {
			out = append(out, dev)
		}
	}
	return out
}

func (r *RuntimeService) listDevices(ctx context.Context, path string, args []string) ([]DeviceInfo, error) {
	cmd := r.command(ctx, path, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		if text := strings.TrimSpace(string(out)); text != "" {
			return parseDevices(text), fmt.Errorf("%v: %s", err, text)
		}
		return parseDevices(string(out)), err
	}
	return parseDevices(string(out)), nil
}

func (r *RuntimeService) rpcDevices(ctx context.Context, path string, endpoints []string) ([]DeviceInfo, error) {
	if len(endpoints) == 0 {
		return nil, nil
	}
	devices, err := r.listDevices(ctx, path, []string{"--rpc", strings.Join(endpoints, ","), "--list-devices"})
	rpcOnly := make([]DeviceInfo, 0, len(devices))
	for i := range devices {
		if !devices[i].Remote {
			continue
		}
		if devices[i].Location == "" {
			devices[i].Location = devices[i].Endpoint
		}
		rpcOnly = append(rpcOnly, devices[i])
	}
	if len(rpcOnly) > 0 {
		return rpcOnly, nil
	}
	if err == nil {
		return nil, nil
	}
	if isUnsupportedRPCDeviceProbe(err) {
		return configuredRPCDevices(endpoints), nil
	}
	return nil, err
}

func configuredRPCDevices(endpoints []string) []DeviceInfo {
	out := make([]DeviceInfo, 0, len(endpoints))
	for index, endpoint := range endpoints {
		out = append(out, DeviceInfo{
			Name:        fmt.Sprintf("RPC%d", index),
			Description: fmt.Sprintf("Configured RPC endpoint %s", endpoint),
			Backend:     "RPC",
			Remote:      true,
			Endpoint:    endpoint,
			Location:    endpoint,
		})
	}
	return out
}

func isUnsupportedRPCDeviceProbe(err error) bool {
	text := strings.ToLower(err.Error())
	return strings.Contains(text, "invalid argument: --rpc") ||
		strings.Contains(text, "unknown argument: --rpc") ||
		strings.Contains(text, "unrecognized option '--rpc'") ||
		strings.Contains(text, "unknown option: --rpc")
}

func mergeDeviceInfo(groups ...[]DeviceInfo) []DeviceInfo {
	var out []DeviceInfo
	seen := map[string]bool{}
	for _, group := range groups {
		for _, dev := range group {
			key := strings.ToUpper(strings.TrimSpace(dev.Name)) + "\x00" + strings.TrimSpace(dev.Endpoint) + "\x00" + strings.TrimSpace(dev.Location)
			if key == "\x00\x00" || seen[key] {
				continue
			}
			seen[key] = true
			out = append(out, dev)
		}
	}
	return out
}

type probeError struct {
	source string
	err    error
}

func combineProbeErrors(errors ...probeError) error {
	parts := make([]string, 0, len(errors))
	for _, item := range errors {
		if item.err == nil {
			continue
		}
		parts = append(parts, fmt.Sprintf("%s: %v", item.source, item.err))
	}
	if len(parts) == 0 {
		return nil
	}
	return fmt.Errorf("%s", strings.Join(parts, "; "))
}

func parseDevices(output string) []DeviceInfo {
	var devices []DeviceInfo
	re := regexp.MustCompile(`^\s*([^:]+):\s*(.*?)\s*\((\d+)\s+MiB,\s+(\d+)\s+MiB free\)`)
	for _, line := range strings.Split(output, "\n") {
		m := re.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		total, _ := strconv.ParseInt(m[3], 10, 64)
		free, _ := strconv.ParseInt(m[4], 10, 64)
		name := strings.TrimSpace(m[1])
		desc := strings.TrimSpace(m[2])
		dev := DeviceInfo{
			Name:        name,
			Description: desc,
			Backend:     backendFromDeviceName(name),
			TotalMiB:    total,
			FreeMiB:     free,
		}
		if strings.HasPrefix(strings.ToUpper(name), "RPC") {
			dev.Remote = true
			dev.Endpoint = desc
		}
		if !isUsableAcceleratorDevice(dev) {
			continue
		}
		devices = append(devices, dev)
	}
	return devices
}

func backendFromDeviceName(name string) string {
	for _, prefix := range []string{"CUDA", "Vulkan", "VK", "MTL", "Metal", "RPC", "SYCL", "HIP", "CANN", "OpenCL", "CPU", "BLAS"} {
		if strings.HasPrefix(strings.ToUpper(name), strings.ToUpper(prefix)) {
			return prefix
		}
	}
	return "unknown"
}

func isUsableAcceleratorDevice(dev DeviceInfo) bool {
	backend := strings.ToUpper(strings.TrimSpace(dev.Backend))
	name := strings.ToUpper(strings.TrimSpace(dev.Name))
	desc := strings.ToUpper(strings.TrimSpace(dev.Description))
	if dev.Remote {
		return true
	}
	if backend == "CPU" || backend == "BLAS" || strings.HasPrefix(name, "BLAS") {
		return false
	}
	if dev.TotalMiB <= 0 && (backend == "UNKNOWN" || strings.Contains(desc, "UNKNOWN")) {
		return false
	}
	return true
}

func enabledRPCEndpoints(cfg AppConfig) []string {
	var out []string
	for _, server := range cfg.RPCServers {
		endpoint := normalizeRPCEndpoint(server.Endpoint)
		if server.Enabled && endpoint != "" {
			out = append(out, endpoint)
		}
	}
	return out
}

func externalRPCEndpoints(endpoints []string) []string {
	out := make([]string, 0, len(endpoints))
	for _, endpoint := range endpoints {
		normalized := normalizeRPCEndpoint(endpoint)
		if normalized == "" || isVMRPCEndpoint(normalized) {
			continue
		}
		out = append(out, normalized)
	}
	return compactStrings(out)
}

func normalizeRPCServerConfigs(servers []RPCServerConfig) []RPCServerConfig {
	out := make([]RPCServerConfig, 0, len(servers))
	for _, server := range servers {
		endpoint := normalizeRPCEndpoint(server.Endpoint)
		if endpoint == "" {
			continue
		}
		out = append(out, RPCServerConfig{
			Endpoint: endpoint,
			Enabled:  server.Enabled,
		})
	}
	return out
}

func normalizeRPCEndpoint(endpoint string) string {
	endpoint = strings.TrimSpace(endpoint)
	if endpoint == "" {
		return ""
	}
	if strings.Contains(endpoint, "://") {
		if parsed, err := url.Parse(endpoint); err == nil && parsed.Host != "" {
			endpoint = parsed.Host
		}
	}
	endpoint = strings.TrimPrefix(endpoint, "//")
	endpoint = strings.TrimSpace(endpoint)
	if cut := strings.IndexAny(endpoint, "/?#"); cut >= 0 {
		endpoint = endpoint[:cut]
	}
	return strings.TrimRight(endpoint, "/")
}
