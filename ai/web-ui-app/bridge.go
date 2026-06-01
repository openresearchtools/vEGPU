package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type BridgeRuntimeSpec struct {
	ID         string   `json:"id,omitempty"`
	Command    string   `json:"command,omitempty"`
	Args       []string `json:"args,omitempty"`
	Env        []string `json:"env,omitempty"`
	Port       int      `json:"port,omitempty"`
	ModelPaths []string `json:"modelPaths,omitempty"`
	MountPaths []string `json:"mountPaths,omitempty"`
}

type BridgeRuntimeResult struct {
	ID       string `json:"id"`
	Role     string `json:"role"`
	Host     string `json:"host,omitempty"`
	BaseURL  string `json:"baseUrl,omitempty"`
	Endpoint string `json:"endpoint,omitempty"`
	Port     int    `json:"port,omitempty"`
	PIDFile  string `json:"pidFile,omitempty"`
	LogFile  string `json:"logFile,omitempty"`
}

type BridgeRuntimeInstallSpec struct {
	ID         string `json:"id"`
	Platform   string `json:"platform"`
	SourceDir  string `json:"sourceDir"`
	ServerPath string `json:"serverPath"`
	RPCPath    string `json:"rpcPath,omitempty"`
}

type BridgeRuntimeInstallResult struct {
	ID     string `json:"id"`
	Root   string `json:"root"`
	Server string `json:"server"`
	RPC    string `json:"rpc,omitempty"`
	Active bool   `json:"active"`
}

type BridgeRuntimeInstalledResult struct {
	ID        string `json:"id"`
	Root      string `json:"root"`
	Installed bool   `json:"installed"`
	Active    bool   `json:"active"`
	Detail    string `json:"detail,omitempty"`
}

type BridgeHFDownloadSpec struct {
	Repo         string   `json:"repo"`
	Revision     string   `json:"revision"`
	Paths        []string `json:"paths"`
	Token        string   `json:"token,omitempty"`
	ProgressPath string   `json:"progressPath,omitempty"`
}

type BridgeModelCopySpec struct {
	Provider       string   `json:"provider"`
	SourceLocation string   `json:"sourceLocation"`
	Files          []string `json:"files"`
	MacRoot        string   `json:"macRoot"`
	VMRoot         string   `json:"vmRoot"`
	ProgressPath   string   `json:"progressPath,omitempty"`
}

type BridgeModelCopyResult struct {
	Copied []string `json:"copied"`
}

type nativeBridgeRequest struct {
	Args []string `json:"args"`
}

func (r *RuntimeService) RPCServerPath(cfg AppConfig) string {
	path := strings.TrimSpace(cfg.Runtime.RPCServerPath)
	if path == "" {
		path = "./rpc-server"
	}
	if !filepath.IsAbs(path) {
		path = filepath.Join(r.appDir, path)
	}
	return filepath.Clean(path)
}

func (r *RuntimeService) StartBridgeServer(ctx context.Context, spec BridgeRuntimeSpec) (BridgeRuntimeResult, error) {
	return r.runBridgeSpec(ctx, "start-server", spec)
}

func (r *RuntimeService) StartBridgeRPC(ctx context.Context, spec BridgeRuntimeSpec) (BridgeRuntimeResult, error) {
	return r.runBridgeSpec(ctx, "start-rpc", spec)
}

func (r *RuntimeService) InstallBridgeRuntime(ctx context.Context, spec BridgeRuntimeInstallSpec) (BridgeRuntimeInstallResult, error) {
	var result BridgeRuntimeInstallResult
	raw, err := json.Marshal(spec)
	if err != nil {
		return result, err
	}
	specID := sanitizeID(spec.ID)
	if specID == "" {
		specID = "runtime"
	}
	specPath := filepath.Join(r.WorkDir(), ".runtime", specID+"-install-runtime.json")
	if err := os.MkdirAll(filepath.Dir(specPath), 0o755); err != nil {
		return result, err
	}
	if err := os.WriteFile(specPath, raw, 0o600); err != nil {
		return result, err
	}
	defer os.Remove(specPath)

	out, err := r.runBridge(ctx, "install-runtime", specPath)
	if err != nil {
		return result, fmt.Errorf("VM LLMS runtime install failed: %w: %s", err, strings.TrimSpace(string(out)))
	}
	if err := json.Unmarshal(out, &result); err != nil {
		return result, fmt.Errorf("parse VM LLMS runtime install response: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return result, nil
}

func (r *RuntimeService) DeleteBridgeRuntime(ctx context.Context, id string) error {
	id = strings.TrimSpace(id)
	if id == "" {
		return fmt.Errorf("runtime id is required")
	}
	out, err := r.runBridge(ctx, "delete-runtime", id)
	if err != nil {
		return fmt.Errorf("VM LLMS runtime delete failed: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (r *RuntimeService) BridgeRuntimeInstalled(ctx context.Context, id string) (BridgeRuntimeInstalledResult, error) {
	var result BridgeRuntimeInstalledResult
	id = strings.TrimSpace(id)
	if id == "" {
		return result, fmt.Errorf("runtime id is required")
	}
	out, err := r.runBridge(ctx, "runtime-installed", id)
	if err != nil {
		return result, fmt.Errorf("VM LLMS runtime status failed: %w: %s", err, strings.TrimSpace(string(out)))
	}
	if err := json.Unmarshal(out, &result); err != nil {
		return result, fmt.Errorf("parse VM LLMS runtime status response: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return result, nil
}

func (r *RuntimeService) StopBridgeRuntime(ctx context.Context, id string) error {
	if strings.TrimSpace(id) == "" {
		return nil
	}
	out, err := r.runBridge(ctx, "stop", strings.TrimSpace(id))
	if err != nil {
		return fmt.Errorf("stop VM LLMS runtime %s: %w: %s", id, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (r *RuntimeService) StopBridgeServers(ctx context.Context) error {
	out, err := r.runBridge(ctx, "stop-servers")
	if err != nil {
		return fmt.Errorf("stop VM LLMS server children: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (r *RuntimeService) BridgeDevices(ctx context.Context) ([]DeviceInfo, error) {
	out, err := r.runBridgeDeviceProbe(ctx, "list-devices")
	if err != nil {
		return nil, fmt.Errorf("VM LLMS device discovery failed: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return parseBridgeDevices(out)
}

func (r *RuntimeService) BridgeDevicesIfRunning(ctx context.Context) ([]DeviceInfo, error) {
	out, err := r.runBridgeDeviceProbe(ctx, "list-devices-if-running")
	if err != nil {
		return nil, fmt.Errorf("VM LLMS device discovery failed: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return parseBridgeDevices(out)
}

func (r *RuntimeService) BridgeModelsIfRunning(ctx context.Context) ([]DiscoveredModel, error) {
	out, err := r.runBridge(ctx, "list-models-if-running")
	if err != nil {
		return nil, fmt.Errorf("VM model discovery failed: %w: %s", err, strings.TrimSpace(string(out)))
	}
	var payload struct {
		Models []DiscoveredModel `json:"models"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return nil, fmt.Errorf("parse VM model discovery response: %w: %s", err, strings.TrimSpace(string(out)))
	}
	for i := range payload.Models {
		payload.Models[i].Location = modelLocationVM
	}
	return payload.Models, nil
}

func (r *RuntimeService) DownloadHFToBridge(ctx context.Context, spec BridgeHFDownloadSpec) error {
	specPath, cleanup, err := r.writeBridgePayload(spec, "download-hf")
	if err != nil {
		return err
	}
	defer cleanup()
	out, err := r.runBridge(ctx, "download-hf", specPath)
	if err != nil {
		return fmt.Errorf("VM Hugging Face download failed: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (r *RuntimeService) CopyModelAcrossBridge(ctx context.Context, spec BridgeModelCopySpec) (BridgeModelCopyResult, error) {
	var result BridgeModelCopyResult
	specPath, cleanup, err := r.writeBridgePayload(spec, "copy-model")
	if err != nil {
		return result, err
	}
	defer cleanup()
	out, err := r.runBridge(ctx, "copy-model", specPath)
	if err != nil {
		return result, fmt.Errorf("model copy failed: %w: %s", err, strings.TrimSpace(string(out)))
	}
	if err := json.Unmarshal(out, &result); err != nil {
		return result, fmt.Errorf("parse model copy response: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return result, nil
}

func parseBridgeDevices(out []byte) ([]DeviceInfo, error) {
	var payload struct {
		Devices []DeviceInfo `json:"devices"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return nil, fmt.Errorf("parse VM LLMS device discovery response: %w: %s", err, strings.TrimSpace(string(out)))
	}
	for i := range payload.Devices {
		payload.Devices[i].Remote = false
		if payload.Devices[i].Backend == "" {
			payload.Devices[i].Backend = backendFromDeviceName(payload.Devices[i].Name)
		}
	}
	return payload.Devices, nil
}

func (r *RuntimeService) runBridgeDeviceProbe(ctx context.Context, subcommand string) ([]byte, error) {
	if r.store == nil {
		return r.runBridge(ctx, subcommand)
	}
	cfg := r.store.Get()
	spec := BridgeRuntimeSpec{
		ID:      "device-probe",
		Command: cfg.Runtime.Residency.ServerCommand,
		Env:     cfg.Runtime.Residency.Env,
	}
	if strings.TrimSpace(spec.Command) == "" && len(spec.Env) == 0 {
		return r.runBridge(ctx, subcommand)
	}
	specPath, cleanup, err := r.writeBridgeSpecFile(spec, subcommand)
	if err != nil {
		return nil, err
	}
	defer cleanup()
	return r.runBridge(ctx, subcommand, specPath)
}

func (r *RuntimeService) runBridgeSpec(ctx context.Context, subcommand string, spec BridgeRuntimeSpec) (BridgeRuntimeResult, error) {
	var result BridgeRuntimeResult
	specPath, cleanup, err := r.writeBridgeSpecFile(spec, subcommand)
	if err != nil {
		return result, err
	}
	defer cleanup()

	out, err := r.runBridge(ctx, subcommand, specPath)
	if err != nil {
		return result, fmt.Errorf("VM LLMS runtime %s failed: %w: %s", subcommand, err, strings.TrimSpace(string(out)))
	}
	if err := json.Unmarshal(out, &result); err != nil {
		return result, fmt.Errorf("parse VM LLMS runtime response: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return result, nil
}

func (r *RuntimeService) writeBridgeSpecFile(spec BridgeRuntimeSpec, subcommand string) (string, func(), error) {
	return r.writeBridgePayload(spec, subcommand)
}

func (r *RuntimeService) writeBridgePayload(payload any, subcommand string) (string, func(), error) {
	raw, err := json.Marshal(payload)
	if err != nil {
		return "", func() {}, err
	}
	specID := fmt.Sprintf("%s-%d", sanitizeID(subcommand), time.Now().UnixNano())
	specPath := filepath.Join(r.WorkDir(), ".runtime", specID+"-"+subcommand+".json")
	if err := os.MkdirAll(filepath.Dir(specPath), 0o755); err != nil {
		return "", func() {}, err
	}
	if err := os.WriteFile(specPath, raw, 0o600); err != nil {
		return "", func() {}, err
	}
	return specPath, func() { _ = os.Remove(specPath) }, nil
}

func (r *RuntimeService) runBridge(ctx context.Context, args ...string) ([]byte, error) {
	if nativeURL := strings.TrimSpace(os.Getenv("VEGPU_NATIVE_BRIDGE_URL")); nativeURL != "" {
		if validNativeBridgeURL(nativeURL) {
			return r.runNativeBridge(ctx, nativeURL, args...)
		}
	}
	cliPath := strings.TrimSpace(os.Getenv("VEGPU_CLI_PATH"))
	nodePath := strings.TrimSpace(os.Getenv("VEGPU_NODE_PATH"))
	var cmd *exec.Cmd
	baseArgs := append([]string{"machine", "llms-runtime"}, args...)
	switch {
	case cliPath != "" && nodePath != "":
		cmd = exec.CommandContext(ctx, nodePath, append([]string{cliPath}, baseArgs...)...)
		cmd.Env = append(os.Environ(), "ELECTRON_RUN_AS_NODE=1")
	case cliPath != "":
		cmd = exec.CommandContext(ctx, cliPath, baseArgs...)
	default:
		cmd = exec.CommandContext(ctx, "vegpu", baseArgs...)
	}
	if cmd.Env == nil {
		cmd.Env = os.Environ()
	}
	if workDir := r.WorkDir(); workDir != "" {
		cmd.Dir = workDir
	}
	return cmd.CombinedOutput()
}

func validNativeBridgeURL(raw string) bool {
	parsed, err := url.Parse(raw)
	if err != nil {
		return false
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return false
	}
	return parsed.Port() != "" && parsed.Port() != "0"
}

func (r *RuntimeService) runNativeBridge(ctx context.Context, nativeURL string, args ...string) ([]byte, error) {
	raw, err := json.Marshal(nativeBridgeRequest{Args: args})
	if err != nil {
		return nil, err
	}
	endpoint := strings.TrimRight(nativeURL, "/") + "/api/native/llms-runtime"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if token := strings.TrimSpace(os.Getenv("VEGPU_NATIVE_BRIDGE_TOKEN")); token != "" {
		req.Header.Set("X-vEGPU-Bridge-Token", token)
		req.Header.Set("Authorization", "Bearer "+token)
	}
	client := &http.Client{Timeout: 30 * time.Minute}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	out, readErr := io.ReadAll(resp.Body)
	if readErr != nil {
		return out, readErr
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return out, fmt.Errorf("native bridge HTTP %d", resp.StatusCode)
	}
	return out, nil
}
