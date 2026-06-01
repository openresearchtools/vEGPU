package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"gopkg.in/yaml.v3"
)

type AppConfig struct {
	Server     ServerConfig           `yaml:"server" json:"server"`
	Runtime    RuntimeConfig          `yaml:"runtime" json:"runtime"`
	Discovery  DiscoveryConfig        `yaml:"discovery" json:"discovery"`
	RPCServers []RPCServerConfig      `yaml:"rpcServers" json:"rpcServers"`
	Models     map[string]ModelConfig `yaml:"models" json:"models"`
	StartPort  int                    `yaml:"startPort" json:"startPort"`
}

type ServerConfig struct {
	Host                string   `yaml:"host" json:"host"`
	Port                int      `yaml:"port" json:"port"`
	APIKeys             []string `yaml:"apiKeys" json:"apiKeys"`
	AllowInsecureRemote bool     `yaml:"allowInsecureRemote" json:"allowInsecureRemote"`
}

type RuntimeConfig struct {
	LlamaServerPath    string                 `yaml:"llamaServerPath" json:"llamaServerPath"`
	RPCServerPath      string                 `yaml:"rpcServerPath,omitempty" json:"rpcServerPath,omitempty"`
	ReleaseRepo        string                 `yaml:"releaseRepo" json:"releaseRepo"`
	ActiveVersion      string                 `yaml:"activeVersion" json:"activeVersion"`
	ActiveRuntimePair  string                 `yaml:"activeRuntimePair,omitempty" json:"activeRuntimePair,omitempty"`
	ActiveMacRuntime   string                 `yaml:"activeMacRuntime,omitempty" json:"activeMacRuntime,omitempty"`
	ActiveLinuxRuntime string                 `yaml:"activeLinuxRuntime,omitempty" json:"activeLinuxRuntime,omitempty"`
	UpdateChannel      string                 `yaml:"updateChannel" json:"updateChannel"`
	Residency          RuntimeResidencyConfig `yaml:"residency,omitempty" json:"residency,omitempty"`
}

type RuntimeResidencyConfig struct {
	ServerCommand      string   `yaml:"serverCommand,omitempty" json:"serverCommand,omitempty"`
	RPCCommand         string   `yaml:"rpcCommand,omitempty" json:"rpcCommand,omitempty"`
	RPCArgs            []string `yaml:"rpcArgs,omitempty" json:"rpcArgs,omitempty"`
	InternalServerPort int      `yaml:"internalServerPort,omitempty" json:"internalServerPort,omitempty"`
	RPCPort            int      `yaml:"rpcPort,omitempty" json:"rpcPort,omitempty"`
	MaxActiveServers   int      `yaml:"maxActiveServers,omitempty" json:"maxActiveServers,omitempty"`
	ResidencyMode      string   `yaml:"residencyMode,omitempty" json:"residencyMode,omitempty"`
	ExtraArgs          []string `yaml:"extraArgs,omitempty" json:"extraArgs,omitempty"`
	Env                []string `yaml:"env,omitempty" json:"env,omitempty"`
}

const vmRuntimeHomeRoot = "/home/vegpu/custom-llama-runtimes"

type DiscoveryConfig struct {
	Enabled      bool     `yaml:"enabled" json:"enabled"`
	Sources      []string `yaml:"sources" json:"sources"`
	ExtraFolders []string `yaml:"extraFolders" json:"extraFolders"`
	LastScan     string   `yaml:"lastScan,omitempty" json:"lastScan,omitempty"`
}

type RPCServerConfig struct {
	Endpoint string `yaml:"endpoint" json:"endpoint"`
	Enabled  bool   `yaml:"enabled" json:"enabled"`
}

type ModelConfig struct {
	ID            string            `yaml:"id,omitempty" json:"id"`
	Name          string            `yaml:"name,omitempty" json:"name,omitempty"`
	Description   string            `yaml:"description,omitempty" json:"description,omitempty"`
	Provider      string            `yaml:"provider,omitempty" json:"provider,omitempty"`
	Source        string            `yaml:"source,omitempty" json:"source,omitempty"`
	Location      string            `yaml:"location,omitempty" json:"location,omitempty"`
	ModelPath     string            `yaml:"modelPath" json:"modelPath"`
	MmprojPath    string            `yaml:"mmprojPath,omitempty" json:"mmprojPath,omitempty"`
	SizeBytes     int64             `yaml:"sizeBytes,omitempty" json:"sizeBytes,omitempty"`
	Available     bool              `yaml:"available" json:"available"`
	MissingReason string            `yaml:"missingReason,omitempty" json:"missingReason,omitempty"`
	DiscoveredAt  string            `yaml:"discoveredAt,omitempty" json:"discoveredAt,omitempty"`
	Metadata      map[string]string `yaml:"metadata,omitempty" json:"metadata,omitempty"`
	Generation    map[string]any    `yaml:"generation,omitempty" json:"generation,omitempty"`
	Launch        LaunchConfig      `yaml:"launch,omitempty" json:"launch"`
}

type LaunchConfig struct {
	TTL             int               `yaml:"ttl,omitempty" json:"ttl,omitempty"`
	ContextSize     *int              `yaml:"ctxSize,omitempty" json:"ctxSize,omitempty"`
	MaxTokens       *int              `yaml:"maxTokens,omitempty" json:"maxTokens,omitempty"`
	BatchSize       *int              `yaml:"batchSize,omitempty" json:"batchSize,omitempty"`
	UBatchSize      *int              `yaml:"ubatchSize,omitempty" json:"ubatchSize,omitempty"`
	Parallel        *int              `yaml:"parallel,omitempty" json:"parallel,omitempty"`
	GPULayers       *int              `yaml:"gpuLayers,omitempty" json:"gpuLayers,omitempty"`
	FlashAttn       string            `yaml:"flashAttn,omitempty" json:"flashAttn,omitempty"`
	KVUnified       *bool             `yaml:"kvUnified,omitempty" json:"kvUnified,omitempty"`
	KVOffload       *bool             `yaml:"kvOffload,omitempty" json:"kvOffload,omitempty"`
	CacheTypeK      string            `yaml:"cacheTypeK,omitempty" json:"cacheTypeK,omitempty"`
	CacheTypeV      string            `yaml:"cacheTypeV,omitempty" json:"cacheTypeV,omitempty"`
	SplitMode       string            `yaml:"splitMode,omitempty" json:"splitMode,omitempty"`
	TensorSplit     []float64         `yaml:"tensorSplit,omitempty" json:"tensorSplit,omitempty"`
	MainGPU         *int              `yaml:"mainGpu,omitempty" json:"mainGpu,omitempty"`
	MainGPUDevice   string            `yaml:"mainGpuDevice,omitempty" json:"mainGpuDevice,omitempty"`
	Devices         []DeviceSelection `yaml:"devices,omitempty" json:"devices,omitempty"`
	RPCServers      []string          `yaml:"rpcServers,omitempty" json:"rpcServers,omitempty"`
	ExtraArgs       []string          `yaml:"extraArgs,omitempty" json:"extraArgs,omitempty"`
	Env             []string          `yaml:"env,omitempty" json:"env,omitempty"`
	Embedding       *bool             `yaml:"embedding,omitempty" json:"embedding,omitempty"`
	Pooling         string            `yaml:"pooling,omitempty" json:"pooling,omitempty"`
	NoMmprojOffload *bool             `yaml:"noMmprojOffload,omitempty" json:"noMmprojOffload,omitempty"`
	RuntimeKind     string            `yaml:"runtimeKind,omitempty" json:"runtimeKind,omitempty"`
}

type DeviceSelection struct {
	Name        string   `yaml:"name" json:"name"`
	Label       string   `yaml:"label,omitempty" json:"label,omitempty"`
	Backend     string   `yaml:"backend,omitempty" json:"backend,omitempty"`
	TotalMiB    int64    `yaml:"totalMiB,omitempty" json:"totalMiB,omitempty"`
	MinTotalMiB int64    `yaml:"minTotalMiB,omitempty" json:"minTotalMiB,omitempty"`
	PCIAddress  string   `yaml:"pciAddress,omitempty" json:"pciAddress,omitempty"`
	UUID        string   `yaml:"uuid,omitempty" json:"uuid,omitempty"`
	Remote      bool     `yaml:"remote,omitempty" json:"remote,omitempty"`
	Endpoint    string   `yaml:"endpoint,omitempty" json:"endpoint,omitempty"`
	Location    string   `yaml:"location,omitempty" json:"location,omitempty"`
	Split       *float64 `yaml:"split,omitempty" json:"split,omitempty"`
	Layers      *int     `yaml:"layers,omitempty" json:"layers,omitempty"`
}

type ConfigStore struct {
	mu      sync.RWMutex
	path    string
	appDir  string
	config  AppConfig
	onSaved func()
}

func NewConfigStore(appDir, configPath string) (*ConfigStore, error) {
	if configPath == "" {
		configPath = defaultConfigPath(appDir)
	}
	store := &ConfigStore{path: configPath, appDir: appDir}
	if err := store.loadOrCreate(); err != nil {
		return nil, err
	}
	return store, nil
}

func defaultConfigPath(appDir string) string {
	if v := strings.TrimSpace(os.Getenv("VEGPU_APP_DATA_DIR")); v != "" {
		return filepath.Join(expandPath(v), "ai", "llms", "app.yaml")
	}
	if home, err := os.UserHomeDir(); err == nil {
		return filepath.Join(home, "Library", "Application Support", "vEGPU", "Machine", "ai", "llms", "app.yaml")
	}
	return filepath.Join(appDir, "app.yaml")
}

func (s *ConfigStore) Path() string {
	return s.path
}

func (s *ConfigStore) SetOnSaved(fn func()) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.onSaved = fn
}

func (s *ConfigStore) Get() AppConfig {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return cloneConfig(s.config)
}

func (s *ConfigStore) Update(fn func(*AppConfig) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	next := cloneConfig(s.config)
	if err := fn(&next); err != nil {
		return err
	}
	normalizeConfig(&next, s.appDir)
	if err := writeYAMLAtomic(s.path, next); err != nil {
		return err
	}
	s.config = next
	if s.onSaved != nil {
		go s.onSaved()
	}
	return nil
}

func (s *ConfigStore) loadOrCreate() error {
	cfg := defaultConfig(s.appDir)
	if raw, err := os.ReadFile(s.path); err == nil && len(strings.TrimSpace(string(raw))) > 0 {
		if err := yaml.Unmarshal(raw, &cfg); err != nil {
			return fmt.Errorf("load config: %w", err)
		}
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	normalizeConfig(&cfg, s.appDir)
	if err := writeYAMLAtomic(s.path, cfg); err != nil {
		return err
	}
	s.config = cfg
	return nil
}

func defaultConfig(appDir string) AppConfig {
	return AppConfig{
		Server: ServerConfig{
			Host: "127.0.0.1",
			Port: 9292,
		},
		Runtime: RuntimeConfig{
			LlamaServerPath: "./llama-server",
			RPCServerPath:   "./rpc-server",
			ReleaseRepo:     "openresearchtools/llama-cpp-arm64-builds",
			ActiveVersion:   "none",
			UpdateChannel:   "custom",
			Residency: RuntimeResidencyConfig{
				ServerCommand:      "/usr/local/bin/llama-server",
				RPCCommand:         "/usr/local/bin/rpc-server",
				RPCArgs:            []string{"--cache"},
				InternalServerPort: 8080,
				RPCPort:            50052,
				MaxActiveServers:   0,
				ResidencyMode:      "gpu-aware",
			},
		},
		Discovery: DiscoveryConfig{
			Enabled: true,
			Sources: []string{"app", "huggingface", "lmstudio", "llamacpp"},
		},
		StartPort: 10001,
		Models:    map[string]ModelConfig{},
	}
}

func normalizeConfig(cfg *AppConfig, appDir string) {
	if cfg.Server.Host == "" {
		cfg.Server.Host = "127.0.0.1"
	}
	if cfg.Server.Port == 0 {
		cfg.Server.Port = 9292
	}
	if cfg.Runtime.LlamaServerPath == "" {
		cfg.Runtime.LlamaServerPath = "./llama-server"
	}
	if cfg.Runtime.RPCServerPath == "" {
		cfg.Runtime.RPCServerPath = "./rpc-server"
	}
	if cfg.Runtime.UpdateChannel == "" {
		cfg.Runtime.UpdateChannel = "custom"
	}
	if cfg.Runtime.ActiveVersion == "" {
		cfg.Runtime.ActiveVersion = "none"
	}
	normalizeRuntimeResidency(&cfg.Runtime.Residency)
	if cfg.StartPort == 0 {
		cfg.StartPort = 10001
	}
	if cfg.Models == nil {
		cfg.Models = map[string]ModelConfig{}
	}
	cfg.RPCServers = normalizeRPCServerConfigs(cfg.RPCServers)
	if cfg.Discovery.Sources == nil {
		cfg.Discovery.Sources = []string{"app", "huggingface", "lmstudio", "llamacpp"}
	} else {
		cfg.Discovery.Sources = filterDiscoverySources(cfg.Discovery.Sources)
	}
	if !cfg.Discovery.Enabled && cfg.Discovery.LastScan == "" {
		cfg.Discovery.Enabled = true
	}
	for id, model := range cfg.Models {
		if model.ID == "" {
			model.ID = id
		}
		if model.Metadata == nil {
			model.Metadata = map[string]string{}
		}
		model.Location = normalizeModelLocation(model.Location, model.ModelPath)
		if model.Metadata["format"] == "" && strings.EqualFold(filepath.Ext(model.ModelPath), ".gguf") {
			model.Metadata["format"] = "GGUF"
		}
		model.Available, model.MissingReason = modelAvailability(model)
		if model.Available {
			if reason := unsupportedLlamaServerArchitecture(model.Metadata); reason != "" {
				model.Available = false
				model.MissingReason = reason
			}
		}
		if model.Available {
			if split := parseGGUFSplitFile(model.ModelPath); split.Count > 1 && split.Index > 1 {
				model.Available = false
				model.MissingReason = "non-primary GGUF split shard; load the 00001 shard"
			}
		}
		cfg.Models[id] = model
	}
}

func unsupportedLlamaServerArchitecture(metadata map[string]string) string {
	arch := strings.ToLower(strings.TrimSpace(metadata["general.architecture"]))
	switch arch {
	case "wan", "flux", "sd", "stable-diffusion", "stable_diffusion", "diffusion",
		"sortformer", "voxtral_realtime", "clip", "wavtokenizer-dec", "paddleocr":
		return "unsupported GGUF architecture for llama-server chat APIs: " + arch
	default:
		return ""
	}
}

func filterDiscoverySources(sources []string) []string {
	out := make([]string, 0, len(sources))
	seen := map[string]bool{}
	for _, source := range sources {
		trimmed := strings.TrimSpace(source)
		if strings.EqualFold(trimmed, "ollama") {
			continue
		}
		key := strings.ToLower(trimmed)
		if trimmed == "" || seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, trimmed)
	}
	if len(out) == 0 {
		return []string{"app", "huggingface", "lmstudio", "llamacpp"}
	}
	return out
}

func cloneConfig(in AppConfig) AppConfig {
	out := in
	out.Runtime.Residency.ExtraArgs = append([]string{}, in.Runtime.Residency.ExtraArgs...)
	out.Runtime.Residency.RPCArgs = append([]string{}, in.Runtime.Residency.RPCArgs...)
	out.Runtime.Residency.Env = append([]string{}, in.Runtime.Residency.Env...)
	out.Server.APIKeys = append([]string{}, in.Server.APIKeys...)
	out.Discovery.Sources = append([]string{}, in.Discovery.Sources...)
	out.Discovery.ExtraFolders = append([]string{}, in.Discovery.ExtraFolders...)
	out.RPCServers = append([]RPCServerConfig{}, in.RPCServers...)
	out.Models = make(map[string]ModelConfig, len(in.Models))
	for k, v := range in.Models {
		v.Launch.TensorSplit = append([]float64{}, v.Launch.TensorSplit...)
		v.Launch.Devices = append([]DeviceSelection{}, v.Launch.Devices...)
		v.Launch.RPCServers = append([]string{}, v.Launch.RPCServers...)
		v.Launch.ExtraArgs = append([]string{}, v.Launch.ExtraArgs...)
		v.Launch.Env = append([]string{}, v.Launch.Env...)
		if v.Metadata != nil {
			meta := make(map[string]string, len(v.Metadata))
			for mk, mv := range v.Metadata {
				meta[mk] = mv
			}
			v.Metadata = meta
		}
		v.Generation = cloneAnyMap(v.Generation)
		out.Models[k] = v
	}
	return out
}

func normalizeRuntimeResidency(residency *RuntimeResidencyConfig) {
	residency.ServerCommand = rewriteDeprecatedVMRuntimeCommand(residency.ServerCommand)
	residency.RPCCommand = rewriteDeprecatedVMRuntimeCommand(residency.RPCCommand)
	if strings.TrimSpace(residency.ServerCommand) == "" {
		residency.ServerCommand = "/usr/local/bin/llama-server"
	}
	if strings.TrimSpace(residency.RPCCommand) == "" {
		residency.RPCCommand = "/usr/local/bin/rpc-server"
	}
	if residency.InternalServerPort == 0 {
		residency.InternalServerPort = 8080
	}
	if residency.RPCPort == 0 {
		residency.RPCPort = 50052
	}
	switch strings.ToLower(strings.TrimSpace(residency.ResidencyMode)) {
	case "gpu-aware", "cap-only", "single":
		residency.ResidencyMode = strings.ToLower(strings.TrimSpace(residency.ResidencyMode))
	default:
		residency.ResidencyMode = "gpu-aware"
	}
	if residency.MaxActiveServers == 0 && residency.ResidencyMode == "single" {
		residency.MaxActiveServers = 1
	}
	residency.ExtraArgs = compactStrings(residency.ExtraArgs)
	residency.RPCArgs = compactStrings(residency.RPCArgs)
	residency.Env = removeDeprecatedRuntimeEnv(compactStrings(residency.Env))
	if len(residency.RPCArgs) == 0 {
		residency.RPCArgs = []string{"--cache"}
	}
	if len(residency.Env) == 0 {
		residency.Env = nil
	}
}

func rewriteDeprecatedVMRuntimeCommand(value string) string {
	value = strings.TrimSpace(value)
	oldRoot := filepath.Join(string(filepath.Separator), "opt", "vegpu", "custom-llama-runtimes")
	if value == oldRoot {
		return vmRuntimeHomeRoot
	}
	if strings.HasPrefix(value, oldRoot+"/") {
		return vmRuntimeHomeRoot + strings.TrimPrefix(value, oldRoot)
	}
	return value
}

func removeDeprecatedRuntimeEnv(values []string) []string {
	out := make([]string, 0, len(values))
	for _, value := range values {
		trimmed := strings.TrimSpace(value)
		if strings.HasPrefix(trimmed, "XDG_CACHE_HOME=") && strings.Contains(trimmed, "vegpu-llms-cache") {
			continue
		}
		out = append(out, trimmed)
	}
	return out
}

func writeYAMLAtomic(path string, cfg AppConfig) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	raw, err := yaml.Marshal(cfg)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func sortedModels(cfg AppConfig) []ModelConfig {
	ids := make([]string, 0, len(cfg.Models))
	for id := range cfg.Models {
		if modelVisibleInRouter(cfg.Models[id]) {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	models := make([]ModelConfig, 0, len(ids))
	for _, id := range ids {
		models = append(models, cfg.Models[id])
	}
	sort.SliceStable(models, func(i, j int) bool {
		if models[i].Available != models[j].Available {
			return models[i].Available
		}
		return strings.ToLower(models[i].Name) < strings.ToLower(models[j].Name)
	})
	return models
}

func modelVisibleInRouter(model ModelConfig) bool {
	if reason := unsupportedLlamaServerArchitecture(model.Metadata); reason != "" {
		return false
	}
	if split := parseGGUFSplitFile(model.ModelPath); split.Count > 1 && split.Index > 1 {
		return false
	}
	return true
}

func modelAvailability(model ModelConfig) (bool, string) {
	if strings.TrimSpace(model.ModelPath) == "" {
		return false, "modelPath is empty"
	}
	if isVMModelLocation(model.Location) {
		if isKnownVMModelPath(model.ModelPath) {
			return true, ""
		}
		return false, "VM model path is outside supported model roots"
	}
	if _, err := os.Stat(model.ModelPath); err != nil {
		return false, err.Error()
	}
	return true, ""
}

func fileAvailability(path string) (bool, string) {
	return modelAvailability(ModelConfig{ModelPath: path, Location: modelLocationMac})
}

const (
	modelLocationMac = "mac"
	modelLocationVM  = "vm"
)

func normalizeModelLocation(location, modelPath string) string {
	switch strings.ToLower(strings.TrimSpace(location)) {
	case modelLocationVM:
		return modelLocationVM
	case modelLocationMac:
		return modelLocationMac
	}
	if strings.HasPrefix(filepath.ToSlash(modelPath), "/home/vegpu/") {
		return modelLocationVM
	}
	return modelLocationMac
}

func isVMModelLocation(location string) bool {
	return strings.EqualFold(normalizeModelLocation(location, ""), modelLocationVM)
}

func isKnownVMModelPath(path string) bool {
	clean := filepath.Clean(path)
	for _, root := range vmModelRoots() {
		rel, err := filepath.Rel(root, clean)
		if err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

func vmModelRoots() []string {
	return []string{
		"/home/vegpu/.cache/huggingface/hub",
		"/home/vegpu/.lmstudio/models",
	}
}

func nowRFC3339() string {
	return time.Now().UTC().Format(time.RFC3339)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func cloneAnyMap(in map[string]any) map[string]any {
	if in == nil {
		return nil
	}
	raw, err := json.Marshal(in)
	if err != nil {
		out := make(map[string]any, len(in))
		for key, value := range in {
			out[key] = value
		}
		return out
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		return map[string]any{}
	}
	return out
}
