package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

func plannedBackend(model ModelConfig) string {
	if isVMModelLocation(model.Location) {
		return runtimeBackendBridge
	}
	devices := nonEmptyDeviceSelections(model.Launch.Devices)
	if len(devices) > 0 {
		primaryName := primaryDeviceName(model.Launch)
		if isLlamaVMDeviceName(primaryName) || strings.HasPrefix(strings.ToUpper(primaryName), "VM:") {
			return runtimeBackendBridge
		}
		return runtimeBackendLocal
	}
	switch strings.ToLower(strings.TrimSpace(model.Launch.RuntimeKind)) {
	case "vm", "cuda":
		return runtimeBackendBridge
	default:
		return runtimeBackendLocal
	}
}

func primaryDeviceName(launch LaunchConfig) string {
	devices := nonEmptyDeviceSelections(launch.Devices)
	if len(devices) == 0 {
		return ""
	}
	mainName := strings.TrimSpace(launch.MainGPUDevice)
	if mainName != "" {
		for _, dev := range devices {
			if strings.EqualFold(strings.TrimSpace(dev.Name), mainName) {
				return strings.TrimSpace(dev.Name)
			}
		}
	}
	return strings.TrimSpace(devices[0].Name)
}

func buildLaunchPlan(ctx context.Context, modelID string, model ModelConfig, port int, cfg AppConfig, runtimeSvc *RuntimeService) (LaunchPlan, error) {
	backend := plannedBackend(model)
	fingerprint := runtimeFingerprint(model, backend, cfg)
	if backend == runtimeBackendBridge {
		return buildBridgeLaunchPlan(ctx, modelID, model, port, cfg, runtimeSvc, fingerprint)
	}
	return buildLocalLaunchPlan(ctx, modelID, model, port, cfg, runtimeSvc, fingerprint)
}

func buildLocalLaunchPlan(ctx context.Context, modelID string, model ModelConfig, port int, cfg AppConfig, runtimeSvc *RuntimeService, fingerprint string) (LaunchPlan, error) {
	launch := model.Launch
	runtimeID := ""
	var err error
	launch, err = translateLocalLaunchDevices(ctx, launch, cfg, runtimeSvc)
	if err != nil {
		return LaunchPlan{}, err
	}
	model.Launch = launch
	if hasRPCDeviceSelection(launch.Devices) {
		var err error
		launch, runtimeID, err = ensureLocalRPCDevices(ctx, model, cfg, runtimeSvc)
		if err != nil {
			return LaunchPlan{}, err
		}
		model.Launch = launch
	}
	return LaunchPlan{
		Backend:     runtimeBackendLocal,
		Args:        buildLaunchArgsWithHost(model, port, cfg, "127.0.0.1"),
		RuntimeID:   runtimeID,
		Fingerprint: fingerprint,
	}, nil
}

func translateLocalLaunchDevices(ctx context.Context, launch LaunchConfig, cfg AppConfig, runtimeSvc *RuntimeService) (LaunchConfig, error) {
	devices := nonEmptyDeviceSelections(launch.Devices)
	if len(devices) == 0 || !hasLlamaVMDeviceSelection(devices) {
		return launch, nil
	}
	resolved, err := resolveBridgeDeviceSelections(ctx, devices, runtimeSvc)
	if err != nil {
		return launch, err
	}
	next := make([]DeviceSelection, 0, len(resolved))
	for _, dev := range resolved {
		item := dev
		if isLlamaVMDeviceName(dev.Name) || strings.HasPrefix(strings.ToUpper(strings.TrimSpace(dev.Name)), "VM:") {
			item.Name = rpcNameForVMDevice(dev)
			item.Backend = "RPC"
			item.Remote = true
			item.Endpoint = net.JoinHostPort(vmnetGuestHost, strconv.Itoa(cfg.Runtime.Residency.RPCPort))
			item.Location = "PEGPU VM RPC"
		}
		next = append(next, item)
	}
	launch.Devices = next
	return launch, nil
}

func ensureLocalRPCDevices(ctx context.Context, model ModelConfig, cfg AppConfig, runtimeSvc *RuntimeService) (LaunchConfig, string, error) {
	launch := model.Launch
	rpcServers := normalizedLaunchRPCEndpoints(launch)
	if len(rpcServers) == 0 {
		rpcServers = selectedRPCEndpoints(launch.Devices)
	}
	if len(rpcServers) == 0 {
		rpcServers = enabledRPCEndpoints(cfg)
	}
	if shouldEnsureVMRPC(rpcServers) {
		if runtimeSvc == nil {
			return launch, "", fmt.Errorf("PEGPU VM RPC selected but runtime service is unavailable")
		}
		if !allVMRPCEndpointsReady(ctx, rpcServers, 750*time.Millisecond) {
			result, err := runtimeSvc.StartBridgeRPC(ctx, BridgeRuntimeSpec{
				ID:         "shared-vm-rpc",
				Command:    cfg.Runtime.Residency.RPCCommand,
				Args:       append([]string{"--host", vmnetGuestHost, "--port", strconv.Itoa(cfg.Runtime.Residency.RPCPort)}, cfg.Runtime.Residency.RPCArgs...),
				Port:       cfg.Runtime.Residency.RPCPort,
				MountPaths: runtimeMountRoots(cfg, model),
				Env:        cfg.Runtime.Residency.Env,
			})
			if err != nil {
				return launch, "", err
			}
			if err := waitTCP(ctx, result.Endpoint, 30*time.Second); err != nil {
				return launch, result.ID, err
			}
			rpcServers = replaceVMRPCEndpoints(rpcServers, result.Endpoint)
			launch.RPCServers = rpcServers
			return launch, result.ID, nil
		}
	}
	launch.RPCServers = rpcServers
	return launch, "", nil
}

func normalizedLaunchRPCEndpoints(launch LaunchConfig) []string {
	out := make([]string, 0, len(launch.RPCServers))
	for _, endpoint := range launch.RPCServers {
		if normalized := normalizeRPCEndpoint(endpoint); normalized != "" {
			out = append(out, normalized)
		}
	}
	return compactStrings(out)
}

func selectedRPCEndpoints(devices []DeviceSelection) []string {
	out := []string{}
	for _, dev := range devices {
		if !isRPCDeviceName(dev.Name) {
			continue
		}
		if endpoint := normalizeRPCEndpoint(dev.Endpoint); endpoint != "" {
			out = append(out, endpoint)
		}
	}
	return compactStrings(out)
}

func shouldEnsureVMRPC(endpoints []string) bool {
	if len(endpoints) == 0 {
		return true
	}
	for _, endpoint := range endpoints {
		if isVMRPCEndpoint(endpoint) {
			return true
		}
	}
	return false
}

func allVMRPCEndpointsReady(ctx context.Context, endpoints []string, timeout time.Duration) bool {
	if len(endpoints) == 0 {
		return false
	}
	for _, endpoint := range endpoints {
		if !isVMRPCEndpoint(endpoint) {
			continue
		}
		probeCtx, cancel := context.WithTimeout(ctx, timeout)
		err := waitTCP(probeCtx, endpoint, timeout)
		cancel()
		if err != nil {
			return false
		}
	}
	return true
}

func replaceVMRPCEndpoints(endpoints []string, endpoint string) []string {
	endpoint = normalizeRPCEndpoint(endpoint)
	if endpoint == "" {
		return endpoints
	}
	if len(endpoints) == 0 {
		return []string{endpoint}
	}
	out := make([]string, 0, len(endpoints))
	replaced := false
	for _, current := range endpoints {
		if isVMRPCEndpoint(current) {
			out = append(out, endpoint)
			replaced = true
		} else {
			out = append(out, current)
		}
	}
	if !replaced {
		out = append(out, endpoint)
	}
	return compactStrings(out)
}

func isVMRPCEndpoint(endpoint string) bool {
	host, _, err := net.SplitHostPort(normalizeRPCEndpoint(endpoint))
	if err != nil {
		return false
	}
	return host == vmnetGuestHost
}

func buildBridgeLaunchPlan(ctx context.Context, modelID string, model ModelConfig, port int, cfg AppConfig, runtimeSvc *RuntimeService, fingerprint string) (LaunchPlan, error) {
	bridgeModel := model
	resolvedDevices, err := resolveBridgeDeviceSelections(ctx, model.Launch.Devices, runtimeSvc)
	if err != nil {
		return LaunchPlan{}, err
	}
	if len(resolvedDevices) == 0 && runtimeSvc != nil {
		if defaults, err := defaultBridgeDeviceSelections(ctx, runtimeSvc); err == nil {
			resolvedDevices = defaults
		}
	}
	bridgeModel.Launch.Devices = translateDevicesForBridge(resolvedDevices)
	bridgeModel.Launch.MainGPUDevice = translateDeviceNameForBridge(resolveMainGPUDevice(model.Launch.MainGPUDevice, model.Launch.Devices, resolvedDevices), resolvedDevices)
	bridgeModel.Launch.RPCServers = nil

	var sidecars []LocalRPCPlan
	if hasMacDeviceSelection(model.Launch.Devices) {
		rpcPort, err := findFreePortOnHost(vmnetGatewayHost, cfg.Runtime.Residency.RPCPort+100)
		if err != nil {
			return LaunchPlan{}, err
		}
		endpoint := net.JoinHostPort(vmnetGatewayHost, strconv.Itoa(rpcPort))
		bridgeModel.Launch.RPCServers = []string{endpoint}
		sidecars = append(sidecars, LocalRPCPlan{
			ID:       modelID + "-mac-rpc",
			Port:     rpcPort,
			Endpoint: endpoint,
			Args:     []string{"--host", vmnetGatewayHost, "--port", strconv.Itoa(rpcPort)},
		})
	}

	args := buildLaunchArgsWithHost(bridgeModel, port, cfg, vmnetGuestHost)
	args = append(args, cfg.Runtime.Residency.ExtraArgs...)
	spec := BridgeRuntimeSpec{
		ID:         "server-" + fingerprint[:16],
		Command:    cfg.Runtime.Residency.ServerCommand,
		Args:       args,
		Env:        append(append([]string{}, cfg.Runtime.Residency.Env...), model.Launch.Env...),
		Port:       port,
		ModelPaths: compactStrings([]string{model.ModelPath, model.MmprojPath}),
		MountPaths: runtimeMountRoots(cfg, model),
	}
	return LaunchPlan{
		Backend:       runtimeBackendBridge,
		BridgeSpec:    spec,
		RuntimeID:     spec.ID,
		Fingerprint:   fingerprint,
		LocalSidecars: sidecars,
	}, nil
}

func defaultBridgeDeviceSelections(ctx context.Context, runtimeSvc *RuntimeService) ([]DeviceSelection, error) {
	fresh, err := runtimeSvc.BridgeDevices(ctx)
	if err != nil {
		return nil, err
	}
	if len(fresh) == 0 {
		return nil, nil
	}
	dev := fresh[0]
	return []DeviceSelection{{
		Name:        dev.Name,
		Label:       dev.Description,
		Backend:     dev.Backend,
		TotalMiB:    dev.TotalMiB,
		MinTotalMiB: dev.TotalMiB,
		PCIAddress:  dev.PCIAddress,
		UUID:        dev.UUID,
		Location:    "PEGPU VM",
	}}, nil
}

func translateDevicesForBridge(devices []DeviceSelection) []DeviceSelection {
	input := nonEmptyDeviceSelections(devices)
	if len(input) == 0 {
		return nil
	}
	out := make([]DeviceSelection, 0, len(input))
	rpcIndex := 0
	for _, dev := range input {
		next := dev
		switch {
		case isMacDeviceName(dev.Name):
			next.Name = fmt.Sprintf("RPC%d", rpcIndex)
			rpcIndex++
		case isLlamaVMDeviceName(dev.Name), isRPCDeviceName(dev.Name):
			next.Name = strings.TrimSpace(dev.Name)
		default:
			continue
		}
		out = append(out, next)
	}
	return out
}

func translateDeviceNameForBridge(name string, devices []DeviceSelection) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return ""
	}
	input := nonEmptyDeviceSelections(devices)
	translated := translateDevicesForBridge(input)
	for i, dev := range input {
		if strings.EqualFold(strings.TrimSpace(dev.Name), name) && i < len(translated) {
			return translated[i].Name
		}
	}
	return name
}

func resolveMainGPUDevice(name string, original []DeviceSelection, resolved []DeviceSelection) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return ""
	}
	for i, dev := range original {
		if strings.EqualFold(strings.TrimSpace(dev.Name), name) && i < len(resolved) {
			return resolved[i].Name
		}
	}
	return name
}

func validateBridgeModelDevices(ctx context.Context, model ModelConfig, runtimeSvc *RuntimeService) error {
	_, err := resolveBridgeDeviceSelections(ctx, model.Launch.Devices, runtimeSvc)
	return err
}

func resolveBridgeDeviceSelections(ctx context.Context, devices []DeviceSelection, runtimeSvc *RuntimeService) ([]DeviceSelection, error) {
	input := nonEmptyDeviceSelections(devices)
	if len(input) == 0 || runtimeSvc == nil {
		return input, nil
	}
	fresh, err := runtimeSvc.BridgeDevices(ctx)
	if err != nil && len(fresh) == 0 {
		return nil, err
	}
	out := make([]DeviceSelection, 0, len(input))
	for _, dev := range input {
		if isMacDeviceName(dev.Name) || isRPCDeviceName(dev.Name) {
			out = append(out, dev)
			continue
		}
		match, err := resolveOneLlamaDevice(dev, fresh)
		if err != nil {
			return nil, err
		}
		next := dev
		next.Name = match.Name
		if next.Label == "" {
			next.Label = match.Description
		}
		if next.Backend == "" {
			next.Backend = match.Backend
		}
		if next.TotalMiB == 0 {
			next.TotalMiB = match.TotalMiB
		}
		if next.PCIAddress == "" {
			next.PCIAddress = match.PCIAddress
		}
		if next.UUID == "" {
			next.UUID = match.UUID
		}
		out = append(out, next)
	}
	return out, nil
}

func resolveOneLlamaDevice(saved DeviceSelection, fresh []DeviceInfo) (DeviceInfo, error) {
	name := strings.TrimSpace(saved.Name)
	if match, ok := resolveByStableDeviceIdentity(saved, fresh); ok {
		return match, nil
	}
	candidates := make([]DeviceInfo, 0, len(fresh))
	savedLabel := strings.ToLower(strings.TrimSpace(saved.Label))
	for _, dev := range fresh {
		if savedLabel != "" && strings.ToLower(strings.TrimSpace(dev.Description)) != savedLabel {
			continue
		}
		if saved.TotalMiB > 0 && dev.TotalMiB != saved.TotalMiB {
			continue
		}
		if saved.MinTotalMiB > 0 && dev.TotalMiB < saved.MinTotalMiB {
			continue
		}
		candidates = append(candidates, dev)
	}
	if len(candidates) == 1 {
		return candidates[0], nil
	}
	for _, dev := range fresh {
		if strings.EqualFold(strings.TrimSpace(dev.Name), name) && !strings.HasPrefix(strings.ToUpper(name), "VM:") {
			return dev, nil
		}
	}
	if len(candidates) > 1 {
		return DeviceInfo{}, fmt.Errorf("selected GPU profile is ambiguous for %s: %s", name, deviceCandidateList(candidates))
	}
	if len(fresh) == 1 {
		return fresh[0], nil
	}
	if strings.HasPrefix(strings.ToUpper(name), "VM:") {
		return DeviceInfo{}, fmt.Errorf("legacy GPU selection %s has no llama.cpp profile; reselect the GPU once so PEGPU can save label and VRAM", name)
	}
	return DeviceInfo{}, fmt.Errorf("selected GPU profile not present: %s", name)
}

func resolveByStableDeviceIdentity(saved DeviceSelection, fresh []DeviceInfo) (DeviceInfo, bool) {
	savedUUID := normalizeDeviceIdentity(saved.UUID)
	if savedUUID != "" {
		for _, dev := range fresh {
			if normalizeDeviceIdentity(dev.UUID) == savedUUID {
				return dev, true
			}
		}
	}
	savedPCI := normalizeDeviceIdentity(saved.PCIAddress)
	if savedPCI != "" {
		for _, dev := range fresh {
			if normalizeDeviceIdentity(dev.PCIAddress) == savedPCI {
				return dev, true
			}
		}
	}
	return DeviceInfo{}, false
}

func normalizeDeviceIdentity(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	value = strings.TrimPrefix(value, "pci:")
	value = strings.ReplaceAll(value, "00000000:", "0000:")
	return value
}

func deviceCandidateList(devices []DeviceInfo) string {
	parts := make([]string, 0, len(devices))
	for _, dev := range devices {
		id := firstNonEmpty(dev.UUID, dev.PCIAddress)
		if id != "" {
			parts = append(parts, fmt.Sprintf("%s %s %d MiB [%s]", dev.Name, dev.Description, dev.TotalMiB, id))
			continue
		}
		parts = append(parts, fmt.Sprintf("%s %s %d MiB", dev.Name, dev.Description, dev.TotalMiB))
	}
	return strings.Join(parts, ", ")
}

func hasMacDeviceSelection(devices []DeviceSelection) bool {
	for _, dev := range devices {
		if isMacDeviceName(dev.Name) {
			return true
		}
	}
	return false
}

func hasLlamaVMDeviceSelection(devices []DeviceSelection) bool {
	for _, dev := range devices {
		name := strings.TrimSpace(dev.Name)
		if isLlamaVMDeviceName(name) || strings.HasPrefix(strings.ToUpper(name), "VM:") {
			return true
		}
	}
	return false
}

func rpcNameForVMDevice(dev DeviceSelection) string {
	if index := deviceOrdinal(dev.Name, "CUDA", "VULKAN", "VK", "HIP", "SYCL", "OPENCL", "VM:CUDA", "VM:VULKAN", "VM:VK", "VM:HIP", "VM:SYCL", "VM:OPENCL"); index != "" {
		return "RPC" + index
	}
	return "RPC0"
}

func isVMDeviceName(name string) bool {
	upper := strings.ToUpper(strings.TrimSpace(name))
	return strings.HasPrefix(upper, "RPC") ||
		isLlamaVMDeviceName(upper) ||
		strings.HasPrefix(upper, "VM:") ||
		strings.Contains(upper, "@VM")
}

func isLlamaVMDeviceName(name string) bool {
	upper := strings.ToUpper(strings.TrimSpace(name))
	return strings.HasPrefix(upper, "CUDA") ||
		strings.HasPrefix(upper, "VULKAN") ||
		strings.HasPrefix(upper, "VK") ||
		strings.HasPrefix(upper, "HIP") ||
		strings.HasPrefix(upper, "SYCL") ||
		strings.HasPrefix(upper, "OPENCL")
}

func isRPCDeviceName(name string) bool {
	return strings.HasPrefix(strings.ToUpper(strings.TrimSpace(name)), "RPC")
}

func isExplicitVMPrimaryDeviceName(name string) bool {
	upper := strings.ToUpper(strings.TrimSpace(name))
	return isLlamaVMDeviceName(upper) ||
		strings.HasPrefix(upper, "VM:") ||
		strings.Contains(upper, "@VM")
}

func isMacDeviceName(name string) bool {
	upper := strings.ToUpper(strings.TrimSpace(name))
	return strings.HasPrefix(upper, "MTL") || strings.HasPrefix(upper, "METAL") || strings.Contains(upper, "@MAC")
}

func runtimeFingerprint(model ModelConfig, backend string, cfg AppConfig) string {
	raw, _ := json.Marshal(map[string]any{
		"backend":    backend,
		"runtime":    cfg.Runtime.ActiveRuntimePair,
		"macRuntime": cfg.Runtime.ActiveMacRuntime,
		"vmRuntime":  cfg.Runtime.ActiveLinuxRuntime,
		"modelPath":  model.ModelPath,
		"mmprojPath": model.MmprojPath,
		"location":   normalizeModelLocation(model.Location, model.ModelPath),
		"launch":     model.Launch,
		"residency":  cfg.Runtime.Residency,
		"enabledRPC": enabledRPCEndpoints(cfg),
	})
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

func runtimeMountRoots(cfg AppConfig, model ModelConfig) []string {
	if isVMModelLocation(model.Location) {
		return nil
	}
	roots := map[string]bool{}
	add := func(value string) {
		value = expandPath(strings.TrimSpace(value))
		if value == "" {
			return
		}
		info, err := os.Stat(value)
		if err != nil {
			return
		}
		if !info.IsDir() {
			value = filepath.Dir(value)
		}
		roots[filepath.Clean(value)] = true
	}
	add(model.ModelPath)
	add(model.MmprojPath)
	for _, folder := range cfg.Discovery.ExtraFolders {
		add(folder)
	}
	if home, err := os.UserHomeDir(); err == nil {
		add(filepath.Join(home, ".lmstudio", "models"))
		add(filepath.Join(home, ".cache", "huggingface", "hub"))
			add(filepath.Join(home, "Library", "Application Support", "pegpu", "Machine", "ai", "llms", "models"))
	}
	out := make([]string, 0, len(roots))
	for root := range roots {
		out = append(out, root)
	}
	return compactStrings(out)
}

func findFreePortOnHost(host string, start int) (int, error) {
	if start < 1 {
		start = 10001
	}
	listenHost := host
	if os.Getenv("PEGPU_WEB_UI_TEST_LOCALHOST_FALLBACK") == "1" && host == vmnetGatewayHost {
		listenHost = "127.0.0.1"
	}
	for port := start; port < start+1000; port++ {
		address := net.JoinHostPort(listenHost, strconv.Itoa(port))
		ln, err := net.Listen("tcp", address)
		if err == nil {
			_ = ln.Close()
			return port, nil
		}
	}
	return 0, fmt.Errorf("no free port found on %s", host)
}

func waitTCP(ctx context.Context, endpoint string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		conn, err := (&net.Dialer{Timeout: time.Second}).DialContext(ctx, "tcp", endpoint)
		if err == nil {
			_ = conn.Close()
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("timed out waiting for %s", endpoint)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(250 * time.Millisecond):
		}
	}
}
