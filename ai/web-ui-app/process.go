package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type ProcessState string

const (
	ProcessStopped  ProcessState = "stopped"
	ProcessStarting ProcessState = "loading"
	ProcessReady    ProcessState = "loaded"
	ProcessFailed   ProcessState = "failed"
	ProcessStopping ProcessState = "stopping"
)

const (
	runtimeBackendLocal  = "local"
	runtimeBackendBridge = "bridge"
	vmnetGuestHost       = "172.29.253.100"
	vmnetGatewayHost     = "172.29.253.1"
)

type RuntimeSidecar struct {
	kind     string
	id       string
	bridgeID string
	cmd      *exec.Cmd
	cancel   context.CancelFunc
	exitDone chan struct{}
}

type LaunchPlan struct {
	Backend       string
	Args          []string
	BridgeSpec    BridgeRuntimeSpec
	RuntimeID     string
	Fingerprint   string
	LocalSidecars []LocalRPCPlan
}

type LocalRPCPlan struct {
	ID       string
	Port     int
	Endpoint string
	Args     []string
}

type ModelProcess struct {
	mu          sync.Mutex
	id          string
	model       ModelConfig
	cmd         *exec.Cmd
	cancel      context.CancelFunc
	runtime     *RuntimeService
	done        chan struct{}
	doneClosed  bool
	exitDone    chan struct{}
	port        int
	baseURL     *url.URL
	proxy       *httputil.ReverseProxy
	state       ProcessState
	err         string
	backend     string
	runtimeID   string
	fingerprint string
	launchArgs  []string
	sidecars    []RuntimeSidecar
	started     time.Time
	lastUsed    time.Time
	inflight    sync.WaitGroup
}

type ProcessManager struct {
	mu       sync.Mutex
	store    *ConfigStore
	runtime  *RuntimeService
	appDir   string
	activeID string
	procs    map[string]*ModelProcess
}

func NewProcessManager(store *ConfigStore, runtimeSvc *RuntimeService, appDir string) *ProcessManager {
	return &ProcessManager{
		store:   store,
		runtime: runtimeSvc,
		appDir:  appDir,
		procs:   map[string]*ModelProcess{},
	}
}

func (pm *ProcessManager) Statuses() map[string]ProcessState {
	pm.mu.Lock()
	defer pm.mu.Unlock()
	out := map[string]ProcessState{}
	for id, p := range pm.procs {
		out[id] = p.CurrentState()
	}
	return out
}

func (pm *ProcessManager) ActiveProcess() *ModelProcess {
	pm.mu.Lock()
	defer pm.mu.Unlock()
	return pm.procs[pm.activeID]
}

func (pm *ProcessManager) Process(modelID string) *ModelProcess {
	pm.mu.Lock()
	defer pm.mu.Unlock()
	return pm.procs[modelID]
}

func (pm *ProcessManager) EnsureModel(ctx context.Context, modelID string) (*ModelProcess, error) {
	cfg := pm.store.Get()
	model, ok := cfg.Models[modelID]
	if !ok {
		return nil, fmt.Errorf("model %s not found", modelID)
	}
	if !model.Available {
		return nil, fmt.Errorf("model %s unavailable: %s", modelID, model.MissingReason)
	}

	targetBackend := plannedBackend(model)
	if targetBackend == runtimeBackendBridge {
		if err := validateBridgeModelDevices(ctx, model, pm.runtime); err != nil {
			return nil, err
		}
	}
	pm.mu.Lock()
	p := pm.procs[modelID]
	if p != nil && p.CurrentState() == ProcessReady {
		pm.activeID = modelID
		pm.mu.Unlock()
		if p.HealthOK(ctx, 2*time.Second) {
			p.Touch()
			return p, nil
		}
		p.Stop(true)
		pm.mu.Lock()
		p = pm.procs[modelID]
	}
	if pm.activeID == modelID {
		if p != nil && p.CurrentState() == ProcessReady {
			pm.mu.Unlock()
			return p, nil
		}
	}
	if p == nil || p.CurrentState() == ProcessStopped || p.CurrentState() == ProcessFailed {
		pm.evictConflictingProcessesLocked(modelID, model)
		if targetBackend == runtimeBackendBridge {
			pm.evictBridgeProcessesLocked(modelID, cfg.Runtime.Residency)
		}
		port, err := findFreePortFrom(cfg.StartPort)
		if err != nil {
			pm.mu.Unlock()
			return nil, err
		}
		p = NewModelProcess(modelID, model, port)
		pm.procs[modelID] = p
		pm.activeID = modelID
	}
	pm.mu.Unlock()

	if p.CurrentState() != ProcessReady {
		if err := p.Start(ctx, pm.runtime, cfg); err != nil {
			return nil, err
		}
	}
	return p, nil
}

func (pm *ProcessManager) evictConflictingProcessesLocked(exceptID string, model ModelConfig) {
	claims := modelDeviceClaimSet(model)
	if len(claims) == 0 {
		return
	}
	victims := []*ModelProcess{}
	for id, p := range pm.procs {
		if id == exceptID {
			continue
		}
		state := p.CurrentState()
		if state == ProcessStopped || state == ProcessFailed || state == ProcessStopping {
			continue
		}
		if deviceClaimsOverlap(claims, modelDeviceClaimSet(p.model)) {
			victims = append(victims, p)
		}
	}
	for _, victim := range victims {
		pm.mu.Unlock()
		victim.Stop(false)
		pm.mu.Lock()
	}
}

func (pm *ProcessManager) evictBridgeProcessesLocked(exceptID string, residency RuntimeResidencyConfig) {
	mode := strings.ToLower(strings.TrimSpace(residency.ResidencyMode))
	if mode == "" {
		mode = "gpu-aware"
	}
	maxActive := residency.MaxActiveServers
	if mode == "single" && maxActive < 1 {
		maxActive = 1
	}
	var active []*ModelProcess
	for id, p := range pm.procs {
		if id == exceptID {
			continue
		}
		state := p.CurrentState()
		if p.backend == runtimeBackendBridge && state != ProcessStopped && state != ProcessFailed && state != ProcessStopping {
			active = append(active, p)
		}
	}
	if mode == "single" || maxActive > 0 {
		limit := maxActive
		if limit < 1 {
			limit = 1
		}
		for len(active) >= limit {
			active = pm.evictOldestBridgeProcessLocked(active)
		}
	}
}

func (pm *ProcessManager) evictOldestBridgeProcessLocked(active []*ModelProcess) []*ModelProcess {
	oldestIndex := 0
	for i := 1; i < len(active); i++ {
		if active[i].lastUsed.Before(active[oldestIndex].lastUsed) {
			oldestIndex = i
		}
	}
	victim := active[oldestIndex]
	next := append(active[:oldestIndex], active[oldestIndex+1:]...)
	pm.mu.Unlock()
	victim.Stop(false)
	pm.mu.Lock()
	return next
}

func (pm *ProcessManager) StopModel(modelID string, immediate bool) error {
	pm.mu.Lock()
	p := pm.procs[modelID]
	if pm.activeID == modelID {
		pm.activeID = ""
	}
	pm.mu.Unlock()
	if p == nil {
		return nil
	}
	p.Stop(immediate)
	return nil
}

func (pm *ProcessManager) StopAll(immediate bool) {
	pm.mu.Lock()
	procs := make([]*ModelProcess, 0, len(pm.procs))
	for _, p := range pm.procs {
		procs = append(procs, p)
	}
	pm.activeID = ""
	pm.mu.Unlock()
	var wg sync.WaitGroup
	for _, p := range procs {
		wg.Add(1)
		go func(proc *ModelProcess) {
			defer wg.Done()
			proc.Stop(immediate)
		}(p)
	}
	wg.Wait()
}

func NewModelProcess(id string, model ModelConfig, port int) *ModelProcess {
	baseURL, _ := url.Parse("http://127.0.0.1:" + strconv.Itoa(port))
	proxy := httputil.NewSingleHostReverseProxy(baseURL)
	proxy.ModifyResponse = func(resp *http.Response) error {
		if strings.Contains(strings.ToLower(resp.Header.Get("Content-Type")), "text/event-stream") {
			resp.Header.Set("X-Accel-Buffering", "no")
		}
		return nil
	}
	proc := &ModelProcess{
		id:       id,
		model:    model,
		port:     port,
		baseURL:  baseURL,
		proxy:    proxy,
		state:    ProcessStopped,
		done:     make(chan struct{}),
		exitDone: make(chan struct{}),
	}
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		proc.markProxyFailure(err)
		http.Error(w, err.Error(), http.StatusBadGateway)
	}
	return proc
}

func (p *ModelProcess) CurrentState() ProcessState {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.state
}

func (p *ModelProcess) Error() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.err
}

func (p *ModelProcess) RuntimeInfo(cfg AppConfig) map[string]any {
	p.mu.Lock()
	defer p.mu.Unlock()
	info := map[string]any{
		"backend":     p.backend,
		"runtimeId":   p.runtimeID,
		"fingerprint": p.fingerprint,
		"port":        p.port,
	}
	if len(p.launchArgs) > 0 {
		info["args"] = append([]string{}, p.launchArgs...)
	}
	if p.backend == runtimeBackendBridge && len(p.sidecars) > 0 {
		sidecars := make([]map[string]any, 0, len(p.sidecars))
		for _, sidecar := range p.sidecars {
			sidecars = append(sidecars, map[string]any{
				"kind":     sidecar.kind,
				"id":       sidecar.id,
				"bridgeId": sidecar.bridgeID,
			})
		}
		info["sidecars"] = sidecars
	}
	if _, ok := info["args"]; ok {
		return info
	}
	if p.backend == runtimeBackendBridge && len(p.runtimeID) > 0 {
		info["args"] = buildLaunchArgsWithHost(p.model, p.port, cfg, vmnetGuestHost)
	} else {
		info["args"] = buildLaunchArgsWithHost(p.model, p.port, cfg, "127.0.0.1")
	}
	return info
}

func (p *ModelProcess) Touch() {
	p.mu.Lock()
	p.lastUsed = time.Now()
	p.mu.Unlock()
}

func (p *ModelProcess) HealthOK(parent context.Context, timeout time.Duration) bool {
	p.mu.Lock()
	if p.state != ProcessReady || p.baseURL == nil {
		p.mu.Unlock()
		return false
	}
	healthURL := p.baseURL.String() + "/health"
	p.mu.Unlock()
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	client := &http.Client{Timeout: timeout}
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, healthURL, nil)
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

func (p *ModelProcess) markProxyFailure(err error) {
	if err == nil || errors.Is(err, context.Canceled) {
		return
	}
	p.mu.Lock()
	if p.state == ProcessReady {
		p.state = ProcessStopped
		p.err = err.Error()
	}
	p.mu.Unlock()
}

func (p *ModelProcess) Start(ctx context.Context, runtimeSvc *RuntimeService, cfg AppConfig) error {
	p.mu.Lock()
	if p.state == ProcessReady {
		p.mu.Unlock()
		return nil
	}
	if p.state == ProcessStarting {
		done := p.done
		p.mu.Unlock()
		select {
		case <-done:
			if p.CurrentState() == ProcessReady {
				return nil
			}
			return errors.New(p.Error())
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	p.state = ProcessStarting
	p.err = ""
	p.done = make(chan struct{})
	p.doneClosed = false
	p.exitDone = make(chan struct{})
	p.started = time.Now()
	p.lastUsed = time.Now()
	p.runtime = runtimeSvc
	p.mu.Unlock()

	plan, err := buildLaunchPlan(ctx, p.id, p.model, p.port, cfg, runtimeSvc)
	if err != nil {
		p.failStart(func() {}, err)
		return err
	}

	startedSidecars, err := p.startLocalSidecars(ctx, runtimeSvc, cfg, plan.LocalSidecars)
	if err != nil {
		p.stopSidecars(startedSidecars)
		p.failStart(func() {}, err)
		return err
	}
	p.mu.Lock()
	p.backend = plan.Backend
	p.fingerprint = plan.Fingerprint
	p.runtimeID = plan.RuntimeID
	if plan.Backend == runtimeBackendBridge {
		p.launchArgs = append([]string{}, plan.BridgeSpec.Args...)
	} else {
		p.launchArgs = append([]string{}, plan.Args...)
	}
	p.sidecars = append(p.sidecars, startedSidecars...)
	p.mu.Unlock()

	if plan.Backend == runtimeBackendBridge {
		result, err := runtimeSvc.StartBridgeServer(ctx, plan.BridgeSpec)
		if err != nil {
			p.Stop(true)
			p.failStart(func() {}, err)
			return err
		}
		base := strings.TrimSpace(result.BaseURL)
		if base == "" {
			base = fmt.Sprintf("http://%s:%d", vmnetGuestHost, plan.BridgeSpec.Port)
		}
		p.setBaseURL(base)
		p.mu.Lock()
		p.runtimeID = result.ID
		p.mu.Unlock()
		if err := p.waitHealth(ctx, 15*time.Minute); err != nil {
			p.Stop(true)
			p.failStart(func() {}, err)
			return err
		}
		p.mu.Lock()
		p.state = ProcessReady
		p.closeStartDoneLocked()
		p.mu.Unlock()
		if p.model.Launch.TTL > 0 {
			go p.ttlLoop(time.Duration(p.model.Launch.TTL) * time.Second)
		}
		return nil
	}

	args := plan.Args
	cmdCtx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(cmdCtx, runtimeSvc.LlamaServerPath(cfg), args...)
	if workDir := runtimeSvc.WorkDir(); strings.TrimSpace(workDir) != "" {
		_ = os.MkdirAll(workDir, 0o755)
		cmd.Dir = workDir
	}
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = append(os.Environ(), p.model.Launch.Env...)
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return cmd.Process.Signal(syscall.SIGTERM)
	}
	cmd.WaitDelay = 10 * time.Second

	p.mu.Lock()
	p.cmd = cmd
	p.cancel = cancel
	p.setBaseURLLocked("http://127.0.0.1:" + strconv.Itoa(p.port))
	p.mu.Unlock()

	if err := cmd.Start(); err != nil {
		p.failStart(cancel, err)
		return err
	}
	go p.wait()

	if err := p.waitHealth(ctx, 15*time.Minute); err != nil {
		p.Stop(true)
		p.failStart(cancel, err)
		return err
	}

	p.mu.Lock()
	p.state = ProcessReady
	p.closeStartDoneLocked()
	p.mu.Unlock()

	if p.model.Launch.TTL > 0 {
		go p.ttlLoop(time.Duration(p.model.Launch.TTL) * time.Second)
	}
	return nil
}

func (p *ModelProcess) failStart(cancel context.CancelFunc, err error) {
	cancel()
	p.mu.Lock()
	if p.state == ProcessStarting {
		p.state = ProcessFailed
		p.err = err.Error()
		p.closeStartDoneLocked()
	}
	p.mu.Unlock()
}

func (p *ModelProcess) wait() {
	err := p.cmd.Wait()
	p.mu.Lock()
	defer p.mu.Unlock()
	defer close(p.exitDone)
	previous := p.state
	if p.state != ProcessStopping && p.state != ProcessFailed {
		p.state = ProcessStopped
		if err != nil {
			p.err = err.Error()
		}
	}
	if previous == ProcessStarting {
		p.closeStartDoneLocked()
	}
}

func (p *ModelProcess) waitHealth(ctx context.Context, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	client := &http.Client{Timeout: 3 * time.Second}
	healthURL := p.baseURL.String() + "/health"
	for {
		if time.Now().After(deadline) {
			return fmt.Errorf("health check timed out for %s", healthURL)
		}
		select {
		case <-p.exitDone:
			if err := p.Error(); err != "" {
				return errors.New(err)
			}
			return fmt.Errorf("llama-server exited before %s became ready", healthURL)
		default:
		}
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, healthURL, nil)
		resp, err := client.Do(req)
		if err == nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-p.exitDone:
			if err := p.Error(); err != "" {
				return errors.New(err)
			}
			return fmt.Errorf("llama-server exited before %s became ready", healthURL)
		case <-time.After(750 * time.Millisecond):
		}
	}
}

func (p *ModelProcess) Proxy(w http.ResponseWriter, r *http.Request) {
	p.inflight.Add(1)
	defer p.inflight.Done()
	p.mu.Lock()
	p.lastUsed = time.Now()
	p.mu.Unlock()
	p.proxy.ServeHTTP(w, r)
}

func (p *ModelProcess) Stop(immediate bool) {
	p.mu.Lock()
	if p.state == ProcessStopped || p.state == ProcessFailed {
		p.mu.Unlock()
		return
	}
	wasStarting := p.state == ProcessStarting
	p.state = ProcessStopping
	if wasStarting {
		if p.err == "" {
			p.err = "model start was stopped"
		}
		p.closeStartDoneLocked()
	}
	cancel := p.cancel
	cmd := p.cmd
	exitDone := p.exitDone
	runtimeSvc := p.runtime
	runtimeID := p.runtimeID
	sidecars := append([]RuntimeSidecar{}, p.sidecars...)
	p.sidecars = nil
	p.launchArgs = nil
	p.mu.Unlock()
	if !immediate {
		p.inflight.Wait()
	}
	if runtimeSvc != nil && runtimeID != "" {
		stopCtx, cancelStop := context.WithTimeout(context.Background(), 30*time.Second)
		_ = runtimeSvc.StopBridgeRuntime(stopCtx, runtimeID)
		cancelStop()
	}
	if cancel != nil {
		cancel()
	}
	if cmd != nil && cmd.Process != nil {
		select {
		case <-exitDone:
		case <-time.After(10 * time.Second):
			_ = cmd.Process.Kill()
			<-exitDone
		}
	}
	p.stopSidecars(sidecars)
	p.mu.Lock()
	p.state = ProcessStopped
	p.mu.Unlock()
}

func (p *ModelProcess) setBaseURL(raw string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.setBaseURLLocked(raw)
}

func (p *ModelProcess) setBaseURLLocked(raw string) {
	baseURL, _ := url.Parse(raw)
	proxy := httputil.NewSingleHostReverseProxy(baseURL)
	proxy.ModifyResponse = func(resp *http.Response) error {
		if strings.Contains(strings.ToLower(resp.Header.Get("Content-Type")), "text/event-stream") {
			resp.Header.Set("X-Accel-Buffering", "no")
		}
		return nil
	}
	p.baseURL = baseURL
	p.proxy = proxy
}

func (p *ModelProcess) startLocalSidecars(ctx context.Context, runtimeSvc *RuntimeService, cfg AppConfig, plans []LocalRPCPlan) ([]RuntimeSidecar, error) {
	var out []RuntimeSidecar
	for _, plan := range plans {
		cmdCtx, cancel := context.WithCancel(context.Background())
		cmd := exec.CommandContext(cmdCtx, runtimeSvc.RPCServerPath(cfg), plan.Args...)
		if workDir := runtimeSvc.WorkDir(); strings.TrimSpace(workDir) != "" {
			_ = os.MkdirAll(workDir, 0o755)
			cmd.Dir = workDir
		}
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		cmd.Env = append(os.Environ(), p.model.Launch.Env...)
		cmd.Cancel = func() error {
			if cmd.Process == nil {
				return nil
			}
			return cmd.Process.Signal(syscall.SIGTERM)
		}
		cmd.WaitDelay = 10 * time.Second
		if err := cmd.Start(); err != nil {
			cancel()
			return out, err
		}
		exitDone := make(chan struct{})
		go func() {
			_ = cmd.Wait()
			close(exitDone)
		}()
		out = append(out, RuntimeSidecar{kind: "local-rpc", id: plan.ID, cmd: cmd, cancel: cancel, exitDone: exitDone})
		if err := waitTCP(ctx, plan.Endpoint, 30*time.Second); err != nil {
			return out, err
		}
	}
	return out, nil
}

func (p *ModelProcess) stopSidecars(sidecars []RuntimeSidecar) {
	for _, sidecar := range sidecars {
		if sidecar.cancel != nil {
			sidecar.cancel()
		}
		if sidecar.cmd != nil && sidecar.cmd.Process != nil && sidecar.exitDone != nil {
			select {
			case <-sidecar.exitDone:
			case <-time.After(10 * time.Second):
				_ = sidecar.cmd.Process.Kill()
				<-sidecar.exitDone
			}
		}
	}
}

func (p *ModelProcess) closeStartDoneLocked() {
	if !p.doneClosed {
		close(p.done)
		p.doneClosed = true
	}
}

func (p *ModelProcess) ttlLoop(ttl time.Duration) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for range ticker.C {
		p.mu.Lock()
		state := p.state
		idle := time.Since(p.lastUsed)
		p.mu.Unlock()
		if state != ProcessReady {
			return
		}
		if idle > ttl {
			p.Stop(false)
			return
		}
	}
}

func buildLaunchArgs(model ModelConfig, port int, cfg AppConfig) []string {
	return buildLaunchArgsWithHost(model, port, cfg, "127.0.0.1")
}

func buildLaunchArgsWithHost(model ModelConfig, port int, cfg AppConfig, host string) []string {
	launch := model.Launch
	args := []string{
		"--host", host,
		"--port", strconv.Itoa(port),
		"--model", model.ModelPath,
	}
	if model.MmprojPath != "" {
		args = append(args, "--mmproj", model.MmprojPath)
	}
	addInt := func(name string, v *int) {
		if v != nil {
			args = append(args, name, strconv.Itoa(*v))
		}
	}
	addInt("--ctx-size", launch.ContextSize)
	addInt("--predict", launch.MaxTokens)
	addInt("--batch-size", launch.BatchSize)
	addInt("--ubatch-size", launch.UBatchSize)
	addInt("--parallel", launch.Parallel)
	deviceSelections := nonEmptyDeviceSelections(launch.Devices)
	deviceNames := deviceSelectionNames(deviceSelections)
	splitMode := ""
	if len(deviceNames) > 1 {
		splitMode = "layer"
	}
	splitEnabled := len(deviceNames) > 1 && isSplitMode(splitMode)
	hasRPCDevice := hasRPCDeviceSelection(launch.Devices)
	if len(deviceNames) > 0 {
		args = append(args, "--gpu-layers", "999")
		args = append(args, "--fit", "off")
	}
	switch strings.ToLower(strings.TrimSpace(launch.FlashAttn)) {
	case "", "on", "true", "1", "yes":
		args = append(args, "--flash-attn", "on")
	case "off", "false", "0", "no":
		args = append(args, "--flash-attn", "off")
	case "auto":
		args = append(args, "--flash-attn", "auto")
	}
	if launch.KVUnified != nil {
		if *launch.KVUnified {
			args = append(args, "--kv-unified")
		} else {
			args = append(args, "--no-kv-unified")
		}
	} else if len(deviceNames) > 0 {
		if splitEnabled {
			args = append(args, "--no-kv-unified")
		} else {
			args = append(args, "--kv-unified")
		}
	}
	args = append(args, "--kv-offload")
	if launch.CacheTypeK != "" {
		args = append(args, "--cache-type-k", normalizeCacheType(launch.CacheTypeK))
	}
	if launch.CacheTypeV != "" {
		args = append(args, "--cache-type-v", normalizeCacheType(launch.CacheTypeV))
	}
	rpcServers := make([]string, 0, len(launch.RPCServers))
	for _, endpoint := range launch.RPCServers {
		if normalized := normalizeRPCEndpoint(endpoint); normalized != "" {
			rpcServers = append(rpcServers, normalized)
		}
	}
	rpcServers = compactStrings(rpcServers)
	if len(rpcServers) == 0 && hasRPCDevice {
		rpcServers = selectedRPCEndpoints(launch.Devices)
	}
	if len(rpcServers) == 0 && hasRPCDevice {
		rpcServers = enabledRPCEndpoints(cfg)
	}
	if len(rpcServers) > 0 {
		args = append(args, "--rpc", strings.Join(rpcServers, ","))
	}
	if len(deviceNames) > 0 {
		args = append(args, "--device", strings.Join(deviceNames, ","))
		if splitEnabled && len(launch.TensorSplit) == 0 {
			args = append(args, "--tensor-split", strings.Join(deviceSplitWeights(deviceSelections), ","))
		}
	}
	if splitEnabled {
		args = append(args, "--split-mode", splitMode)
	}
	if splitEnabled && len(launch.TensorSplit) > 0 {
		parts := make([]string, 0, len(launch.TensorSplit))
		for _, v := range launch.TensorSplit {
			parts = append(parts, strconv.FormatFloat(v, 'f', -1, 64))
		}
		args = append(args, "--tensor-split", strings.Join(parts, ","))
	}
	if splitEnabled {
		mainIndex := deviceIndex(deviceSelections, launch.MainGPUDevice)
		if mainIndex < 0 && launch.MainGPU != nil {
			mainIndex = *launch.MainGPU
		}
		if mainIndex < 0 {
			mainIndex = 0
		}
		args = append(args, "--main-gpu", strconv.Itoa(mainIndex))
	}
	if launch.Embedding != nil && *launch.Embedding {
		args = append(args, "--embedding")
	}
	if launch.Pooling != "" {
		args = append(args, "--pooling", launch.Pooling)
	}
	if model.MmprojPath != "" {
		args = append(args, "--mmproj-offload")
	}
	args = append(args, launch.ExtraArgs...)
	return args
}

func nonEmptyDeviceSelections(devices []DeviceSelection) []DeviceSelection {
	out := make([]DeviceSelection, 0, len(devices))
	for _, dev := range devices {
		if strings.TrimSpace(dev.Name) != "" {
			out = append(out, dev)
		}
	}
	return out
}

func deviceSelectionNames(devices []DeviceSelection) []string {
	out := make([]string, 0, len(devices))
	for _, dev := range devices {
		name := strings.TrimSpace(dev.Name)
		if name != "" {
			out = append(out, name)
		}
	}
	return out
}

func modelDeviceClaimSet(model ModelConfig) map[string]bool {
	return deviceClaimSetForBackend(model.Launch.Devices, plannedBackend(model))
}

func deviceClaimSet(devices []DeviceSelection) map[string]bool {
	return deviceClaimSetForBackend(devices, "")
}

func deviceClaimSetForBackend(devices []DeviceSelection, runtimeBackend string) map[string]bool {
	claims := map[string]bool{}
	for _, dev := range nonEmptyDeviceSelections(devices) {
		for _, key := range deviceClaimKeys(dev, runtimeBackend) {
			claims[key] = true
		}
	}
	return claims
}

func deviceClaimKey(dev DeviceSelection) string {
	keys := deviceClaimKeys(dev, "")
	if len(keys) > 0 {
		return keys[0]
	}
	return ""
}

func deviceClaimKeys(dev DeviceSelection, runtimeBackend string) []string {
	name := strings.TrimSpace(dev.Name)
	switch {
	case isLlamaVMDeviceName(name) || strings.HasPrefix(strings.ToUpper(name), "VM:"):
		return physicalDeviceClaimKeys("vm", "gpu", dev, "CUDA", "VULKAN", "VK", "HIP", "SYCL", "OPENCL", "VM:CUDA", "VM:VULKAN", "VM:VK", "VM:HIP", "VM:SYCL", "VM:OPENCL")
	case isMacDeviceName(name):
		return physicalDeviceClaimKeys("mac", "mtl", dev, "MTL", "METAL")
	case isRPCDeviceName(name):
		if rpcSelectionTargetsVM(dev, runtimeBackend) {
			return physicalDeviceClaimKeys("vm", "gpu", dev, "RPC")
		}
		return rpcDeviceClaimKeys(dev)
	default:
		return legacyDeviceClaimKeys(dev)
	}
}

func physicalDeviceClaimKeys(owner string, indexKind string, dev DeviceSelection, prefixes ...string) []string {
	if profile := deviceProfileClaim(dev); profile != "" {
		return []string{fmt.Sprintf("%s-gpu:%s", owner, profile)}
	}
	keys := []string{}
	if index := deviceOrdinal(strings.TrimSpace(dev.Name), prefixes...); index != "" {
		keys = append(keys, fmt.Sprintf("%s-%s:%s", owner, indexKind, index))
	}
	return compactStrings(keys)
}

func rpcDeviceClaimKeys(dev DeviceSelection) []string {
	endpoint := normalizeRPCEndpoint(dev.Endpoint)
	if endpoint == "" {
		endpoint = normalizeRPCEndpoint(dev.Location)
	}
	keys := []string{}
	if profile := deviceProfileClaim(dev); profile != "" && endpoint != "" {
		keys = append(keys, fmt.Sprintf("rpc-gpu:%s:%s", endpoint, profile))
	}
	if index := deviceOrdinal(strings.TrimSpace(dev.Name), "RPC"); index != "" {
		if endpoint != "" {
			keys = append(keys, fmt.Sprintf("rpc:%s:%s", endpoint, index))
		} else {
			keys = append(keys, "rpc:"+index)
		}
	}
	return compactStrings(keys)
}

func legacyDeviceClaimKeys(dev DeviceSelection) []string {
	backend := strings.ToLower(strings.TrimSpace(dev.Backend))
	if backend == "" {
		backend = strings.ToLower(backendFromDeviceName(dev.Name))
	}
	label := normalizedClaimText(dev.Label)
	if label != "" && dev.TotalMiB > 0 {
		return []string{fmt.Sprintf("%s:%s:%d", backend, label, dev.TotalMiB)}
	}
	name := strings.ToLower(strings.TrimSpace(dev.Name))
	if name == "" {
		return nil
	}
	return []string{name}
}

func rpcSelectionTargetsVM(dev DeviceSelection, runtimeBackend string) bool {
	endpoint := normalizeRPCEndpoint(dev.Endpoint)
	location := strings.ToLower(strings.TrimSpace(dev.Location))
	if endpoint != "" {
		return isVMRPCEndpoint(endpoint)
	}
	if strings.Contains(location, "vegpu vm") || strings.Contains(location, "vm rpc") {
		return true
	}
	return runtimeBackend == runtimeBackendLocal && strings.EqualFold(strings.TrimSpace(dev.Backend), "RPC") && strings.Contains(location, "vm")
}

func deviceProfileClaim(dev DeviceSelection) string {
	if id := normalizeDeviceIdentity(dev.UUID); id != "" {
		return "uuid:" + id
	}
	if id := normalizeDeviceIdentity(dev.PCIAddress); id != "" {
		return "pci:" + id
	}
	label := normalizedClaimText(dev.Label)
	if label == "" || dev.TotalMiB <= 0 {
		return ""
	}
	return fmt.Sprintf("%s:%d", label, dev.TotalMiB)
}

func normalizedClaimText(value string) string {
	return strings.ToLower(strings.Join(strings.Fields(strings.TrimSpace(value)), " "))
}

func deviceOrdinal(name string, prefixes ...string) string {
	upper := strings.ToUpper(strings.TrimSpace(name))
	for _, prefix := range prefixes {
		prefix = strings.ToUpper(prefix)
		index := strings.Index(upper, prefix)
		if index < 0 {
			continue
		}
		rest := upper[index+len(prefix):]
		digits := strings.Builder{}
		for _, r := range rest {
			if r < '0' || r > '9' {
				break
			}
			digits.WriteRune(r)
		}
		if digits.Len() > 0 {
			return digits.String()
		}
	}
	return ""
}

func deviceClaimsOverlap(a, b map[string]bool) bool {
	if len(a) == 0 || len(b) == 0 {
		return false
	}
	for key := range a {
		if b[key] {
			return true
		}
	}
	return false
}

func summedDeviceLayers(devices []DeviceSelection) int {
	total := 0
	for _, dev := range devices {
		if dev.Layers != nil && *dev.Layers > 0 {
			total += *dev.Layers
		}
	}
	return total
}

func normalizedSplitMode(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "layer", "row", "tensor":
		return strings.ToLower(strings.TrimSpace(value))
	case "none":
		return "none"
	default:
		return ""
	}
}

func isSplitMode(value string) bool {
	return value == "layer" || value == "row" || value == "tensor"
}

func deviceSplitWeights(devices []DeviceSelection) []string {
	if weights, ok := splitWeightsFromRatios(devices); ok {
		return weights
	}
	if weights, ok := splitWeightsFromLayers(devices); ok {
		return weights
	}
	weights := make([]string, 0, len(devices))
	for range devices {
		weights = append(weights, "1")
	}
	return weights
}

func splitWeightsFromRatios(devices []DeviceSelection) ([]string, bool) {
	hasRatio := false
	weights := make([]string, 0, len(devices))
	for _, dev := range devices {
		value := 1.0
		if dev.Split != nil && *dev.Split > 0 {
			hasRatio = true
			value = *dev.Split
		}
		weights = append(weights, strconv.FormatFloat(value, 'f', -1, 64))
	}
	return weights, hasRatio
}

func splitWeightsFromLayers(devices []DeviceSelection) ([]string, bool) {
	weights := make([]string, 0, len(devices))
	if len(devices) == 0 {
		return weights, false
	}
	for _, dev := range devices {
		if dev.Layers == nil || *dev.Layers <= 0 {
			return weights, false
		}
		weights = append(weights, strconv.Itoa(*dev.Layers))
	}
	return weights, true
}

func hasRPCDeviceSelection(devices []DeviceSelection) bool {
	for _, dev := range devices {
		if strings.HasPrefix(strings.ToUpper(strings.TrimSpace(dev.Name)), "RPC") {
			return true
		}
	}
	return false
}

func normalizeCacheType(value string) string {
	switch strings.ToUpper(strings.TrimSpace(value)) {
	case "TURBO2_0", "TURBO2":
		return "turbo2"
	case "TURBO3_0", "TURBO3":
		return "turbo3"
	case "TURBO4_0", "TURBO4":
		return "turbo4"
	default:
		return strings.TrimSpace(value)
	}
}

func deviceIndex(devices []DeviceSelection, name string) int {
	name = strings.TrimSpace(name)
	if name == "" {
		return -1
	}
	index := 0
	for _, dev := range devices {
		if strings.TrimSpace(dev.Name) == "" {
			continue
		}
		if strings.TrimSpace(dev.Name) == name {
			return index
		}
		index++
	}
	return -1
}

func findFreePortFrom(start int) (int, error) {
	if start < 1 {
		start = 10001
	}
	for port := start; port < start+1000; port++ {
		ln, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(port))
		if err == nil {
			_ = ln.Close()
			if !tcpPortAccepts(vmnetGuestHost, port, 150*time.Millisecond) {
				return port, nil
			}
		}
	}
	return 0, errors.New("no free port found")
}

func tcpPortAccepts(host string, port int, timeout time.Duration) bool {
	conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(port)), timeout)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}
