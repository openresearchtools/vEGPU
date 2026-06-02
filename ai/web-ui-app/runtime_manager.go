package main

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
)

const runtimeMetadataFile = "runtime.json"

type RuntimeManager struct {
	appDir  string
	store   *ConfigStore
	runtime *RuntimeService
}

type ManagedRuntime struct {
	ID              string `json:"id"`
	Platform        string `json:"platform"`
	Name            string `json:"name"`
	ArchiveName     string `json:"archiveName"`
	InstallDir      string `json:"installDir"`
	RootDir         string `json:"rootDir"`
	ServerPath      string `json:"serverPath"`
	RPCPath         string `json:"rpcPath,omitempty"`
	ServerRel       string `json:"serverRel"`
	RPCRel          string `json:"rpcRel,omitempty"`
	LicensePath     string `json:"licensePath,omitempty"`
	InstalledAt     string `json:"installedAt"`
	Version         string `json:"version,omitempty"`
	Active          bool   `json:"active"`
	VMInstalled     bool   `json:"vmInstalled"`
	InstallError    string `json:"installError,omitempty"`
	Family          string `json:"family,omitempty"`
	ReleaseTag      string `json:"releaseTag,omitempty"`
	SourceRef       string `json:"sourceRef,omitempty"`
	LinuxBackend    string `json:"linuxBackend,omitempty"`
	PairID          string `json:"pairId,omitempty"`
	AssetName       string `json:"assetName,omitempty"`
	DownloadURL     string `json:"downloadUrl,omitempty"`
	SHA256          string `json:"sha256,omitempty"`
	VMDeletePending bool   `json:"vmDeletePending,omitempty"`
}

type RuntimeListPayload struct {
	Current  RuntimeCurrent   `json:"current"`
	Runtimes []ManagedRuntime `json:"runtimes"`
	MacOS    []ManagedRuntime `json:"macos"`
	Linux    []ManagedRuntime `json:"linux"`
	Pairs    []RuntimePair    `json:"pairs"`
}

type RuntimeCurrent struct {
	LlamaServerPath    string `json:"llamaServerPath"`
	RPCServerPath      string `json:"rpcServerPath"`
	VMServerCommand    string `json:"vmServerCommand"`
	VMRPCCommand       string `json:"vmRpcCommand"`
	ActiveVersion      string `json:"activeVersion"`
	ActiveRuntimePair  string `json:"activeRuntimePair"`
	ActiveMacRuntime   string `json:"activeMacRuntime"`
	ActiveLinuxRuntime string `json:"activeLinuxRuntime"`
	UpdateChannel      string `json:"updateChannel"`
}

type RuntimePair struct {
	ID              string          `json:"id"`
	Family          string          `json:"family,omitempty"`
	ReleaseTag      string          `json:"releaseTag,omitempty"`
	SourceRef       string          `json:"sourceRef,omitempty"`
	LinuxBackend    string          `json:"linuxBackend,omitempty"`
	InstalledAt     string          `json:"installedAt,omitempty"`
	Active          bool            `json:"active"`
	VMInstalled     bool            `json:"vmInstalled"`
	InstallError    string          `json:"installError,omitempty"`
	VMDeletePending bool            `json:"vmDeletePending,omitempty"`
	MacOS           *ManagedRuntime `json:"macos,omitempty"`
	Linux           *ManagedRuntime `json:"linux,omitempty"`
}

type RuntimeInstallMetadata struct {
	Family       string
	ReleaseTag   string
	SourceRef    string
	LinuxBackend string
	PairID       string
	AssetName    string
	DownloadURL  string
	SHA256       string
}

type BootstrapRuntimeManifest struct {
	SchemaVersion int                              `json:"schemaVersion"`
	Family        string                           `json:"family"`
	Tag           string                           `json:"tag"`
	Name          string                           `json:"name"`
	PublishedAt   string                           `json:"publishedAt"`
	Source        string                           `json:"source"`
	SourceRef     string                           `json:"sourceRef"`
	Assets        map[string]BootstrapRuntimeAsset `json:"assets"`
}

type BootstrapRuntimeAsset struct {
	Name        string `json:"name"`
	Path        string `json:"path"`
	Size        int64  `json:"size"`
	SHA256      string `json:"sha256"`
	DownloadURL string `json:"downloadURL"`
}

func NewRuntimeManager(appDir string, store *ConfigStore, runtimeSvc *RuntimeService) *RuntimeManager {
	return &RuntimeManager{appDir: appDir, store: store, runtime: runtimeSvc}
}

func (m *RuntimeManager) List(ctx context.Context) (RuntimeListPayload, error) {
	if err := m.ensureBootstrapRuntimes(ctx); err != nil {
		return RuntimeListPayload{}, err
	}
	cfg := m.store.Get()
	payload := RuntimeListPayload{
		Current: RuntimeCurrent{
			LlamaServerPath:    m.runtime.LlamaServerPath(cfg),
			RPCServerPath:      m.runtime.RPCServerPath(cfg),
			VMServerCommand:    cfg.Runtime.Residency.ServerCommand,
			VMRPCCommand:       cfg.Runtime.Residency.RPCCommand,
			ActiveVersion:      cfg.Runtime.ActiveVersion,
			ActiveRuntimePair:  cfg.Runtime.ActiveRuntimePair,
			ActiveMacRuntime:   cfg.Runtime.ActiveMacRuntime,
			ActiveLinuxRuntime: cfg.Runtime.ActiveLinuxRuntime,
			UpdateChannel:      cfg.Runtime.UpdateChannel,
		},
	}
	for _, platform := range []string{"macos", "linux"} {
		items, err := m.listPlatform(platform)
		if err != nil {
			return payload, err
		}
		for i := range items {
			if platform == "linux" && shouldRefreshLinuxInstallState(items[i], cfg) {
				m.refreshLinuxInstallState(ctx, &items[i])
			}
			if m.isRuntimeActive(items[i], cfg) {
				items[i].Active = true
			} else {
				items[i].Active = false
			}
		}
		payload.Runtimes = append(payload.Runtimes, items...)
		if platform == "macos" {
			payload.MacOS = items
		} else {
			payload.Linux = items
		}
	}
	sort.Slice(payload.Runtimes, func(i, j int) bool {
		return payload.Runtimes[i].InstalledAt > payload.Runtimes[j].InstalledAt
	})
	payload.Pairs = runtimePairs(payload.Runtimes, cfg)
	_ = ctx
	return payload, nil
}

func (m *RuntimeManager) ensureBootstrapRuntimes(ctx context.Context) error {
	manifest, root, err := m.readBootstrapRuntimeManifest()
	if err != nil || manifest == nil {
		return err
	}
	if normalizeReleaseFamily(manifest.Family) != "llama" {
		return nil
	}
	for _, backend := range []string{"cuda13", "vulkan"} {
		if err := m.ensureBootstrapRuntimePair(ctx, *manifest, root, backend); err != nil {
			return err
		}
	}
	cfg := m.store.Get()
	if strings.TrimSpace(cfg.Runtime.ActiveRuntimePair) == "" || cfg.Runtime.ActiveVersion == "" || cfg.Runtime.ActiveVersion == "none" {
		pairID := releasePairID(manifest.Family, manifest.Tag, "cuda13")
		mac, macErr := m.loadRuntimeDirect("macos", pairID+"-macos")
		linux, linuxErr := m.loadRuntimeDirect("linux", pairID+"-linux")
		if macErr == nil && linuxErr == nil {
			if err := m.selectRuntimePairLocal(mac, linux); err != nil {
				return err
			}
		}
	}
	return nil
}

func (m *RuntimeManager) readBootstrapRuntimeManifest() (*BootstrapRuntimeManifest, string, error) {
	root := filepath.Join(filepath.Dir(m.appDir), "bootstrap-runtimes", "llama")
	manifestPath := filepath.Join(root, "llama-runtime-manifest.json")
	raw, err := os.ReadFile(manifestPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil, root, nil
	}
	if err != nil {
		return nil, root, err
	}
	var manifest BootstrapRuntimeManifest
	if err := json.Unmarshal(raw, &manifest); err != nil {
		return nil, root, fmt.Errorf("read bundled llama runtime manifest: %w", err)
	}
	return &manifest, root, nil
}

func (m *RuntimeManager) bootstrapDeletedDir() string {
	return filepath.Join(m.runtime.WorkDir(), "runtimes", ".bootstrap-deleted")
}

func (m *RuntimeManager) bootstrapPairDeleted(pairID string) bool {
	_, err := os.Stat(filepath.Join(m.bootstrapDeletedDir(), sanitizeID(pairID)))
	return err == nil
}

func (m *RuntimeManager) markBootstrapPairDeleted(pairID string) error {
	dir := m.bootstrapDeletedDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, sanitizeID(pairID)), []byte(time.Now().UTC().Format(time.RFC3339)+"\n"), 0o644)
}

func (m *RuntimeManager) clearBootstrapPairDeleted(pairID string) error {
	err := os.Remove(filepath.Join(m.bootstrapDeletedDir(), sanitizeID(pairID)))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func (m *RuntimeManager) isBootstrapRuntimePair(pair RuntimePair) bool {
	manifest, _, err := m.readBootstrapRuntimeManifest()
	if err != nil || manifest == nil {
		return false
	}
	for _, backend := range []string{"cuda13", "vulkan"} {
		if pair.ID == releasePairID(manifest.Family, manifest.Tag, backend) {
			return true
		}
	}
	return false
}

func (m *RuntimeManager) ensureBootstrapRuntimePair(ctx context.Context, manifest BootstrapRuntimeManifest, root, backend string) error {
	backend = normalizeLinuxBackend(backend)
	if backend == "" {
		return nil
	}
	pairID := releasePairID(manifest.Family, manifest.Tag, backend)
	if m.bootstrapPairDeleted(pairID) {
		return nil
	}
	macAsset, ok := manifest.Assets["macos"]
	if !ok || strings.TrimSpace(macAsset.Path) == "" {
		return fmt.Errorf("bundled llama runtime manifest is missing macOS asset")
	}
	linuxAsset, ok := manifest.Assets[backend]
	if !ok || strings.TrimSpace(linuxAsset.Path) == "" {
		return fmt.Errorf("bundled llama runtime manifest is missing %s Linux asset", backendLabel(backend))
	}
	if _, err := m.loadRuntimeDirect("macos", pairID+"-macos"); err != nil {
		if _, err := m.installBootstrapArchive(ctx, "macos", pairID+"-macos", manifest, macAsset, root, backend); err != nil {
			return err
		}
	}
	if linuxRuntime, err := m.loadRuntimeDirect("linux", pairID+"-linux"); err == nil {
		installed, active := mountedLinuxRuntimeState(linuxRuntime.ID)
		changed := false
		if linuxRuntime.VMInstalled != installed {
			linuxRuntime.VMInstalled = installed
			changed = true
		}
		if installed && strings.Contains(linuxRuntime.InstallError, "first boot") {
			linuxRuntime.InstallError = ""
			changed = true
		} else if !installed && linuxRuntime.InstallError == "" {
			linuxRuntime.InstallError = "VM runtime will install from the bundled seed on first boot; retry VM install after the VM is running."
			changed = true
		}
		if active != linuxRuntime.Active && active {
			linuxRuntime.Active = true
			changed = true
		}
		if changed {
			return writeRuntimeMetadata(linuxRuntime)
		}
		return nil
	}
	linuxRuntime, err := m.installBootstrapArchive(ctx, "linux", pairID+"-linux", manifest, linuxAsset, root, backend)
	if err != nil {
		return err
	}
	installed, active := mountedLinuxRuntimeState(linuxRuntime.ID)
	linuxRuntime.VMInstalled = installed
	linuxRuntime.Active = active
	if !installed {
		linuxRuntime.InstallError = "VM runtime will install from the bundled seed on first boot; retry VM install after the VM is running."
	}
	return writeRuntimeMetadata(linuxRuntime)
}

func (m *RuntimeManager) installBootstrapArchive(ctx context.Context, platform, id string, manifest BootstrapRuntimeManifest, asset BootstrapRuntimeAsset, root, backend string) (ManagedRuntime, error) {
	archivePath := filepath.Clean(filepath.Join(root, asset.Path))
	if !pathInside(root, archivePath) {
		return ManagedRuntime{}, fmt.Errorf("bundled runtime archive escapes bootstrap directory: %s", asset.Path)
	}
	if strings.TrimSpace(asset.SHA256) != "" {
		actual, err := fileSHA256Hex(archivePath)
		if err != nil {
			return ManagedRuntime{}, err
		}
		if !strings.EqualFold(actual, asset.SHA256) {
			return ManagedRuntime{}, fmt.Errorf("bundled runtime archive checksum mismatch: %s", asset.Name)
		}
	}
	file, err := os.Open(archivePath)
	if err != nil {
		return ManagedRuntime{}, err
	}
	defer file.Close()
	return m.installArchive(ctx, platform, id, asset.Name, file, RuntimeInstallMetadata{
		Family:       manifest.Family,
		ReleaseTag:   manifest.Tag,
		SourceRef:    manifest.SourceRef,
		LinuxBackend: backend,
		PairID:       releasePairID(manifest.Family, manifest.Tag, backend),
		AssetName:    asset.Name,
		DownloadURL:  asset.DownloadURL,
		SHA256:       asset.SHA256,
	})
}

func (m *RuntimeManager) Upload(ctx context.Context, platform, archiveName string, archive io.Reader) (ManagedRuntime, error) {
	runtimeInfo, err := m.installArchive(ctx, platform, "", archiveName, archive, RuntimeInstallMetadata{})
	if err != nil {
		return ManagedRuntime{}, err
	}
	if runtimeInfo.Platform == "macos" {
		if err := m.activateMacRuntime(&runtimeInfo); err != nil {
			return ManagedRuntime{}, err
		}
	} else {
		m.installLinuxRuntime(ctx, &runtimeInfo, true)
	}
	if err := writeRuntimeMetadata(runtimeInfo); err != nil {
		return ManagedRuntime{}, err
	}
	return runtimeInfo, nil
}

func (m *RuntimeManager) installArchive(ctx context.Context, platform, id, archiveName string, archive io.Reader, metadata RuntimeInstallMetadata) (ManagedRuntime, error) {
	platform = normalizeRuntimePlatform(platform)
	if platform == "" {
		return ManagedRuntime{}, fmt.Errorf("platform must be macos or linux")
	}
	if !strings.HasSuffix(strings.ToLower(archiveName), ".tar.gz") && !strings.HasSuffix(strings.ToLower(archiveName), ".tgz") {
		return ManagedRuntime{}, fmt.Errorf("runtime archive must be a .tar.gz or .tgz file")
	}
	baseName := strings.TrimSuffix(strings.TrimSuffix(filepath.Base(archiveName), ".tar.gz"), ".tgz")
	if strings.TrimSpace(id) == "" {
		id = sanitizeID(platform + "-" + baseName + "-" + time.Now().UTC().Format("20060102T150405.000000000Z"))
	} else {
		id = sanitizeID(id)
	}
	installDir := filepath.Join(m.platformDir(platform), id)
	if err := os.MkdirAll(filepath.Dir(installDir), 0o755); err != nil {
		return ManagedRuntime{}, err
	}
	if err := os.RemoveAll(installDir); err != nil {
		return ManagedRuntime{}, err
	}
	if err := os.MkdirAll(installDir, 0o755); err != nil {
		return ManagedRuntime{}, err
	}
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.RemoveAll(installDir)
		}
	}()
	if err := extractTarGz(archive, installDir); err != nil {
		return ManagedRuntime{}, err
	}
	runtimeInfo, err := m.describeExtractedRuntime(ctx, id, platform, archiveName, installDir)
	if err != nil {
		return ManagedRuntime{}, err
	}
	runtimeInfo.Family = normalizeReleaseFamily(metadata.Family)
	runtimeInfo.ReleaseTag = strings.TrimSpace(metadata.ReleaseTag)
	runtimeInfo.SourceRef = strings.TrimSpace(metadata.SourceRef)
	runtimeInfo.LinuxBackend = normalizeLinuxBackend(metadata.LinuxBackend)
	if strings.TrimSpace(metadata.PairID) != "" {
		runtimeInfo.PairID = sanitizeID(metadata.PairID)
	}
	runtimeInfo.AssetName = strings.TrimSpace(metadata.AssetName)
	runtimeInfo.DownloadURL = strings.TrimSpace(metadata.DownloadURL)
	runtimeInfo.SHA256 = strings.TrimSpace(metadata.SHA256)
	if err := writeRuntimeMetadata(runtimeInfo); err != nil {
		return ManagedRuntime{}, err
	}
	cleanup = false
	return runtimeInfo, nil
}

func (m *RuntimeManager) Activate(ctx context.Context, id string) (ManagedRuntime, error) {
	runtimeInfo, err := m.loadRuntime(id)
	if err != nil {
		return runtimeInfo, err
	}
	switch runtimeInfo.Platform {
	case "macos":
		if runtimeInfo.PairID != "" {
			pair, err := m.ActivatePair(ctx, runtimeInfo.PairID)
			if err != nil {
				return runtimeInfo, err
			}
			if pair.MacOS != nil {
				return *pair.MacOS, nil
			}
			return runtimeInfo, nil
		}
		return m.ActivateMacOS(runtimeInfo.ID)
	case "linux":
		return m.InstallLinux(ctx, runtimeInfo.ID)
	default:
		return runtimeInfo, fmt.Errorf("runtime %s has unsupported platform %s", runtimeInfo.ID, runtimeInfo.Platform)
	}
}

func (m *RuntimeManager) ActivateMacOS(id string) (ManagedRuntime, error) {
	runtimeInfo, err := m.loadRuntime(id)
	if err != nil {
		return runtimeInfo, err
	}
	if runtimeInfo.Platform != "macos" {
		return runtimeInfo, fmt.Errorf("runtime %s is %s; only macOS runtimes can be activated locally", id, runtimeInfo.Platform)
	}
	if err := m.activateMacRuntime(&runtimeInfo); err != nil {
		return runtimeInfo, err
	}
	if err := writeRuntimeMetadata(runtimeInfo); err != nil {
		return runtimeInfo, err
	}
	return runtimeInfo, nil
}

func (m *RuntimeManager) InstallLinux(ctx context.Context, id string) (ManagedRuntime, error) {
	runtimeInfo, err := m.loadRuntime(id)
	if err != nil {
		return runtimeInfo, err
	}
	if runtimeInfo.Platform != "linux" {
		return runtimeInfo, fmt.Errorf("runtime %s is %s; only Linux runtimes install into the VM", id, runtimeInfo.Platform)
	}
	if runtimeInfo.PairID != "" {
		if pair, ok := m.loadRuntimePair(runtimeInfo.PairID); ok && pair.MacOS != nil && pair.Linux != nil && pair.Linux.ID == runtimeInfo.ID {
			_, err := m.ActivatePair(ctx, runtimeInfo.PairID)
			refreshed, loadErr := m.loadRuntime(runtimeInfo.ID)
			if loadErr == nil {
				runtimeInfo = refreshed
			}
			return runtimeInfo, err
		}
	}
	err = m.installLinuxRuntime(ctx, &runtimeInfo, true)
	if writeErr := writeRuntimeMetadata(runtimeInfo); writeErr != nil && err == nil {
		err = writeErr
	}
	return runtimeInfo, err
}

func (m *RuntimeManager) activateMacRuntime(runtimeInfo *ManagedRuntime) error {
	if _, err := os.Stat(runtimeInfo.ServerPath); err != nil {
		return err
	}
	if err := m.store.Update(func(next *AppConfig) error {
		activeVersion := runtimeInfo.ID
		if runtimeInfo.PairID != "" {
			activeVersion = runtimeInfo.PairID
			next.Runtime.ActiveRuntimePair = runtimeInfo.PairID
		} else {
			next.Runtime.ActiveRuntimePair = ""
		}
		next.Runtime.LlamaServerPath = runtimeInfo.ServerPath
		if runtimeInfo.RPCPath != "" {
			next.Runtime.RPCServerPath = runtimeInfo.RPCPath
		}
		next.Runtime.ReleaseRepo = runtimeInfo.DownloadURL
		if next.Runtime.ReleaseRepo == "" {
			next.Runtime.ReleaseRepo = "custom"
		}
		next.Runtime.ActiveVersion = activeVersion
		next.Runtime.ActiveMacRuntime = runtimeInfo.ID
		next.Runtime.UpdateChannel = runtimeInfo.Family
		if next.Runtime.UpdateChannel == "" {
			next.Runtime.UpdateChannel = "custom"
		}
		return nil
	}); err != nil {
		return err
	}
	if err := m.markPlatformActive("macos", runtimeInfo.ID); err != nil {
		return err
	}
	runtimeInfo.Active = true
	return nil
}

func (m *RuntimeManager) installLinuxRuntime(ctx context.Context, runtimeInfo *ManagedRuntime, activate bool) error {
	if strings.TrimSpace(runtimeInfo.RootDir) == "" || strings.TrimSpace(runtimeInfo.ServerPath) == "" {
		runtimeInfo.InstallError = "runtime metadata is missing Linux install paths"
		runtimeInfo.VMInstalled = false
		return errors.New(runtimeInfo.InstallError)
	}
	installCtx, cancel := context.WithTimeout(ctx, 30*time.Minute)
	defer cancel()
	result, err := m.runtime.InstallBridgeRuntime(installCtx, BridgeRuntimeInstallSpec{
		ID:         runtimeInfo.ID,
		Platform:   runtimeInfo.Platform,
		SourceDir:  runtimeInfo.RootDir,
		ServerPath: runtimeInfo.ServerPath,
		RPCPath:    runtimeInfo.RPCPath,
	})
	if err != nil {
		runtimeInfo.InstallError = err.Error()
		runtimeInfo.VMInstalled = false
		return err
	}
	runtimeInfo.InstallError = ""
	runtimeInfo.VMInstalled = result.Active
	runtimeInfo.VMDeletePending = false
	runtimeInfo.Active = result.Active
	if !activate {
		return nil
	}
	if err := m.store.Update(func(next *AppConfig) error {
		activeVersion := runtimeInfo.ID
		if runtimeInfo.PairID != "" {
			activeVersion = runtimeInfo.PairID
			next.Runtime.ActiveRuntimePair = runtimeInfo.PairID
		} else {
			next.Runtime.ActiveRuntimePair = ""
		}
		next.Runtime.Residency.ServerCommand = guestRuntimeExecutable(*runtimeInfo, runtimeInfo.ServerRel, "/usr/local/bin/llama-server")
		next.Runtime.Residency.RPCCommand = guestRuntimeExecutable(*runtimeInfo, runtimeInfo.RPCRel, "/usr/local/bin/rpc-server")
		next.Runtime.ReleaseRepo = runtimeInfo.DownloadURL
		if next.Runtime.ReleaseRepo == "" {
			next.Runtime.ReleaseRepo = "custom"
		}
		next.Runtime.ActiveVersion = activeVersion
		next.Runtime.ActiveLinuxRuntime = runtimeInfo.ID
		next.Runtime.UpdateChannel = runtimeInfo.Family
		if next.Runtime.UpdateChannel == "" {
			next.Runtime.UpdateChannel = "custom"
		}
		return nil
	}); err != nil {
		runtimeInfo.InstallError = err.Error()
		return err
	}
	if err := m.markPlatformActive("linux", runtimeInfo.ID); err != nil {
		return err
	}
	return nil
}

func (m *RuntimeManager) refreshLinuxInstallState(ctx context.Context, runtimeInfo *ManagedRuntime) {
	if m.runtime == nil || runtimeInfo == nil || runtimeInfo.Platform != "linux" {
		return
	}
	probeCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	status, err := m.runtime.BridgeRuntimeInstalled(probeCtx, runtimeInfo.ID)
	if err != nil {
		installed, active := mountedLinuxRuntimeState(runtimeInfo.ID)
		status = BridgeRuntimeInstalledResult{
			ID:        runtimeInfo.ID,
			Root:      path.Join(vmRuntimeHomeRoot, sanitizeID(runtimeInfo.ID)),
			Installed: installed,
			Active:    active,
			Detail:    "checked mounted Linux home",
		}
	}
	changed := false
	if runtimeInfo.VMInstalled != status.Installed {
		runtimeInfo.VMInstalled = status.Installed
		changed = true
	}
	if !status.Installed {
		msg := "VM runtime is missing from " + vmRuntimeHomeRoot + "; retry VM install"
		if runtimeInfo.InstallError != msg {
			runtimeInfo.InstallError = msg
			changed = true
		}
	} else if strings.Contains(runtimeInfo.InstallError, "VM runtime is missing from ") {
		runtimeInfo.InstallError = ""
		changed = true
	}
	if !status.Installed && runtimeInfo.VMDeletePending {
		runtimeInfo.VMDeletePending = false
		changed = true
	}
	if changed {
		_ = writeRuntimeMetadata(*runtimeInfo)
	}
}

func shouldRefreshLinuxInstallState(runtimeInfo ManagedRuntime, cfg AppConfig) bool {
	return runtimeInfo.ID == cfg.Runtime.ActiveLinuxRuntime ||
		runtimeInfo.Active ||
		runtimeInfo.VMDeletePending ||
		strings.Contains(runtimeInfo.InstallError, "VM runtime is missing from ")
}

func mountedLinuxRuntimeState(id string) (bool, bool) {
	mount := linuxHomeMountPath()
	if mount == "" {
		return false, false
	}
	root := filepath.Join(mount, "custom-llama-runtimes", sanitizeID(id))
	if _, err := findNamedFile(root, "llama-server"); err != nil {
		return false, false
	}
	current, err := filepath.EvalSymlinks(filepath.Join(mount, "custom-llama-runtimes", "current"))
	if err != nil {
		return true, false
	}
	resolved, err := filepath.EvalSymlinks(root)
	return true, err == nil && current == resolved
}

func linuxHomeMountPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "/Volumes/vEGPU/Home"
	}
	raw, err := os.ReadFile(filepath.Join(home, "Library", "Application Support", "vEGPU", "Machine", "machine.json"))
	if err != nil {
		return "/Volumes/vEGPU/Home"
	}
	var payload struct {
		LinuxHomeMountPath string `json:"linuxHomeMountPath"`
	}
	if json.Unmarshal(raw, &payload) == nil && strings.TrimSpace(payload.LinuxHomeMountPath) != "" {
		return payload.LinuxHomeMountPath
	}
	return "/Volumes/vEGPU/Home"
}

func (m *RuntimeManager) Delete(ctx context.Context, id string) error {
	runtimeInfo, err := m.loadRuntime(id)
	if err != nil {
		return err
	}
	cfg := m.store.Get()
	if m.isRuntimeActive(runtimeInfo, cfg) {
		return fmt.Errorf("runtime %s is active; choose another %s runtime before deleting it", runtimeInfo.ID, runtimeInfo.Platform)
	}
	if runtimeInfo.Platform == "linux" && runtimeInfo.VMInstalled {
		deleteCtx, cancel := context.WithTimeout(ctx, 5*time.Minute)
		defer cancel()
		if err := m.runtime.DeleteBridgeRuntime(deleteCtx, runtimeInfo.ID); err != nil {
			return err
		}
	}
	return os.RemoveAll(runtimeInfo.InstallDir)
}

func (m *RuntimeManager) describeExtractedRuntime(ctx context.Context, id, platform, archiveName, installDir string) (ManagedRuntime, error) {
	serverPath, err := findNamedFile(installDir, "llama-server")
	if err != nil {
		return ManagedRuntime{}, fmt.Errorf("runtime archive does not contain llama-server")
	}
	rpcPath, _ := findNamedFile(installDir, "rpc-server")
	rootDir := inferRuntimeRoot(installDir, serverPath, rpcPath)
	serverRel, err := filepath.Rel(rootDir, serverPath)
	if err != nil || strings.HasPrefix(serverRel, "..") {
		return ManagedRuntime{}, fmt.Errorf("failed to resolve llama-server path")
	}
	rpcRel := ""
	if rpcPath != "" {
		rpcRel, _ = filepath.Rel(rootDir, rpcPath)
	}
	_ = os.Chmod(serverPath, 0o755)
	if rpcPath != "" {
		_ = os.Chmod(rpcPath, 0o755)
	}
	licensePath, _ := findNamedFile(rootDir, "LICENSE")
	name := filepath.Base(rootDir)
	if name == "." || name == string(filepath.Separator) || name == "" {
		name = strings.TrimSuffix(strings.TrimSuffix(filepath.Base(archiveName), ".tar.gz"), ".tgz")
	}
	runtimeInfo := ManagedRuntime{
		ID:          id,
		Platform:    platform,
		Name:        name,
		ArchiveName: archiveName,
		InstallDir:  installDir,
		RootDir:     rootDir,
		ServerPath:  serverPath,
		RPCPath:     rpcPath,
		ServerRel:   filepath.ToSlash(serverRel),
		RPCRel:      filepath.ToSlash(rpcRel),
		LicensePath: licensePath,
		InstalledAt: time.Now().UTC().Format(time.RFC3339),
	}
	if platform == "macos" || runtime.GOOS == "linux" {
		runtimeInfo.Version = runtimeVersion(ctx, serverPath)
	}
	return runtimeInfo, nil
}

func (m *RuntimeManager) loadRuntime(id string) (ManagedRuntime, error) {
	id = sanitizeID(id)
	if id == "" {
		return ManagedRuntime{}, fmt.Errorf("runtime id is required")
	}
	for _, platform := range []string{"macos", "linux"} {
		path := filepath.Join(m.platformDir(platform), id, runtimeMetadataFile)
		runtimeInfo, err := readRuntimeMetadata(path)
		if err == nil {
			return runtimeInfo, nil
		}
	}
	return ManagedRuntime{}, fmt.Errorf("runtime %s not found", id)
}

func (m *RuntimeManager) loadRuntimeDirect(platform, id string) (ManagedRuntime, error) {
	platform = normalizeRuntimePlatform(platform)
	id = sanitizeID(id)
	if platform == "" || id == "" {
		return ManagedRuntime{}, os.ErrNotExist
	}
	return readRuntimeMetadata(filepath.Join(m.platformDir(platform), id, runtimeMetadataFile))
}

func (m *RuntimeManager) listPlatform(platform string) ([]ManagedRuntime, error) {
	root := m.platformDir(platform)
	entries, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return []ManagedRuntime{}, nil
	}
	if err != nil {
		return nil, err
	}
	items := make([]ManagedRuntime, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		runtimeInfo, err := readRuntimeMetadata(filepath.Join(root, entry.Name(), runtimeMetadataFile))
		if err == nil {
			items = append(items, runtimeInfo)
		}
	}
	sort.Slice(items, func(i, j int) bool {
		return items[i].InstalledAt > items[j].InstalledAt
	})
	return items, nil
}

func (m *RuntimeManager) markPlatformActive(platform, id string) error {
	items, err := m.listPlatform(platform)
	if err != nil {
		return err
	}
	for _, item := range items {
		item.Active = item.ID == id
		if err := writeRuntimeMetadata(item); err != nil {
			return err
		}
	}
	return nil
}

func (m *RuntimeManager) isRuntimeActive(runtimeInfo ManagedRuntime, cfg AppConfig) bool {
	switch runtimeInfo.Platform {
	case "macos":
		return runtimeInfo.ID == cfg.Runtime.ActiveMacRuntime || samePath(runtimeInfo.ServerPath, m.runtime.LlamaServerPath(cfg))
	case "linux":
		return runtimeInfo.ID == cfg.Runtime.ActiveLinuxRuntime
	default:
		return false
	}
}

func (m *RuntimeManager) selectRuntimePairLocal(mac, linux ManagedRuntime) error {
	if mac.PairID == "" || mac.PairID != linux.PairID {
		return nil
	}
	if err := m.store.Update(func(next *AppConfig) error {
		next.Runtime.LlamaServerPath = mac.ServerPath
		if mac.RPCPath != "" {
			next.Runtime.RPCServerPath = mac.RPCPath
		}
		next.Runtime.ReleaseRepo = firstNonEmpty(mac.DownloadURL, linux.DownloadURL, "custom")
		next.Runtime.ActiveVersion = mac.PairID
		next.Runtime.ActiveRuntimePair = mac.PairID
		next.Runtime.ActiveMacRuntime = mac.ID
		next.Runtime.ActiveLinuxRuntime = linux.ID
		next.Runtime.UpdateChannel = firstNonEmpty(mac.Family, linux.Family, "custom")
		if linux.VMInstalled {
			next.Runtime.Residency.ServerCommand = guestRuntimeExecutable(linux, linux.ServerRel, "/usr/local/bin/llama-server")
			next.Runtime.Residency.RPCCommand = guestRuntimeExecutable(linux, linux.RPCRel, "/usr/local/bin/rpc-server")
		}
		return nil
	}); err != nil {
		return err
	}
	if err := m.markPlatformActive("macos", mac.ID); err != nil {
		return err
	}
	return m.markPlatformActive("linux", linux.ID)
}

func guestRuntimeExecutable(runtimeInfo ManagedRuntime, rel string, fallback string) string {
	rel = strings.TrimSpace(filepath.ToSlash(rel))
	if rel == "" || rel == "." || rel == ".." || strings.HasPrefix(rel, "/") || strings.HasPrefix(rel, "../") {
		return fallback
	}
	return path.Join(vmRuntimeHomeRoot, sanitizeID(runtimeInfo.ID), rel)
}

func (m *RuntimeManager) platformDir(platform string) string {
	return filepath.Join(m.runtime.WorkDir(), "runtimes", platform)
}

func normalizeRuntimePlatform(platform string) string {
	switch strings.ToLower(strings.TrimSpace(platform)) {
	case "mac", "darwin", "macos":
		return "macos"
	case "linux", "ubuntu", "debian":
		return "linux"
	default:
		return ""
	}
}

func writeRuntimeMetadata(runtimeInfo ManagedRuntime) error {
	return writeJSONAtomic(filepath.Join(runtimeInfo.InstallDir, runtimeMetadataFile), runtimeInfo)
}

func readRuntimeMetadata(path string) (ManagedRuntime, error) {
	var runtimeInfo ManagedRuntime
	err := readJSONFile(path, &runtimeInfo)
	return runtimeInfo, err
}

func writeJSONAtomic(path string, value any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func readJSONFile(path string, out any) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(raw, out)
}

func fileSHA256Hex(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hasher := sha256.New()
	if _, err := io.Copy(hasher, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hasher.Sum(nil)), nil
}

func extractTarGz(reader io.Reader, dest string) error {
	gz, err := gzip.NewReader(reader)
	if err != nil {
		return fmt.Errorf("open gzip archive: %w", err)
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	cleanDest, err := filepath.Abs(dest)
	if err != nil {
		return err
	}
	for {
		header, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		name := filepath.Clean(header.Name)
		if name == "." || strings.HasPrefix(name, ".."+string(filepath.Separator)) || filepath.IsAbs(name) {
			return fmt.Errorf("unsafe archive path: %s", header.Name)
		}
		target := filepath.Join(cleanDest, name)
		if !pathInside(cleanDest, target) {
			return fmt.Errorf("unsafe archive path: %s", header.Name)
		}
		mode := header.FileInfo().Mode().Perm()
		if mode == 0 {
			mode = 0o644
		}
		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, mode); err != nil {
				return err
			}
		case tar.TypeReg, tar.TypeRegA:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
			if err != nil {
				return err
			}
			if _, err := io.Copy(out, tr); err != nil {
				_ = out.Close()
				return err
			}
			if err := out.Close(); err != nil {
				return err
			}
			_ = os.Chmod(target, mode)
		case tar.TypeSymlink:
			if err := safeSymlink(cleanDest, target, header.Linkname); err != nil {
				return err
			}
		case tar.TypeLink:
			if err := safeHardlink(cleanDest, target, header.Linkname); err != nil {
				return err
			}
		case tar.TypeXGlobalHeader, tar.TypeXHeader:
			continue
		default:
			continue
		}
	}
}

func safeSymlink(root, target, linkName string) error {
	if strings.TrimSpace(linkName) == "" || filepath.IsAbs(linkName) {
		return fmt.Errorf("unsafe symlink target: %s", linkName)
	}
	resolved := filepath.Clean(filepath.Join(filepath.Dir(target), linkName))
	if !pathInside(root, resolved) {
		return fmt.Errorf("unsafe symlink target: %s", linkName)
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	_ = os.Remove(target)
	return os.Symlink(linkName, target)
}

func safeHardlink(root, target, linkName string) error {
	name := filepath.Clean(linkName)
	if name == "." || strings.HasPrefix(name, ".."+string(filepath.Separator)) || filepath.IsAbs(name) {
		return fmt.Errorf("unsafe hardlink target: %s", linkName)
	}
	source := filepath.Join(root, name)
	if !pathInside(root, source) {
		return fmt.Errorf("unsafe hardlink target: %s", linkName)
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	_ = os.Remove(target)
	return os.Link(source, target)
}

func pathInside(root, path string) bool {
	root = filepath.Clean(root)
	path = filepath.Clean(path)
	return path == root || strings.HasPrefix(path, root+string(filepath.Separator))
}

func findNamedFile(root, name string) (string, error) {
	var found string
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil || found != "" {
			return err
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return nil
		}
		if !entry.IsDir() && entry.Name() == name {
			found = path
			return filepath.SkipAll
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	if found == "" {
		return "", os.ErrNotExist
	}
	return found, nil
}

func inferRuntimeRoot(installDir, serverPath, rpcPath string) string {
	common := filepath.Dir(serverPath)
	if rpcPath != "" {
		common = commonPath(common, filepath.Dir(rpcPath))
	}
	if pathInside(installDir, common) {
		return common
	}
	return installDir
}

func commonPath(a, b string) string {
	aParts := strings.Split(filepath.Clean(a), string(filepath.Separator))
	bParts := strings.Split(filepath.Clean(b), string(filepath.Separator))
	limit := len(aParts)
	if len(bParts) < limit {
		limit = len(bParts)
	}
	common := []string{}
	for i := 0; i < limit; i++ {
		if aParts[i] != bParts[i] {
			break
		}
		common = append(common, aParts[i])
	}
	if len(common) == 0 {
		return string(filepath.Separator)
	}
	out := filepath.Join(common...)
	if strings.HasPrefix(a, string(filepath.Separator)) && !strings.HasPrefix(out, string(filepath.Separator)) {
		out = string(filepath.Separator) + out
	}
	return out
}

func samePath(a, b string) bool {
	absA, errA := filepath.Abs(a)
	absB, errB := filepath.Abs(b)
	if errA == nil {
		a = absA
	}
	if errB == nil {
		b = absB
	}
	return filepath.Clean(a) == filepath.Clean(b)
}

func runtimeVersion(ctx context.Context, serverPath string) string {
	versionCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(versionCtx, serverPath, "--version")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return ""
	}
	return cleanRuntimeVersion(strings.TrimSpace(string(out)))
}
