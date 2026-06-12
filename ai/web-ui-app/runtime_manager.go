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
	"sync"
	"time"
)

const runtimeMetadataFile = "runtime.json"
const linuxInstallStateRefreshTimeout = 20 * time.Second

type RuntimeManager struct {
	appDir   string
	store    *ConfigStore
	runtime  *RuntimeService
	ensureMu sync.Mutex
}

type ManagedRuntime struct {
	ID              string `json:"id"`
	Platform        string `json:"platform"`
	Name            string `json:"name"`
	ArchiveName     string `json:"archiveName"`
	InstallDir      string `json:"installDir,omitempty"`
	RootDir         string `json:"rootDir,omitempty"`
	ServerPath      string `json:"serverPath,omitempty"`
	RPCPath         string `json:"rpcPath,omitempty"`
	InstallDirRel   string `json:"installDirRel,omitempty"`
	RootDirRel      string `json:"rootDirRel,omitempty"`
	ServerRel       string `json:"serverRel"`
	RPCRel          string `json:"rpcRel,omitempty"`
	LicensePath     string `json:"licensePath,omitempty"`
	LicensePathRel  string `json:"licensePathRel,omitempty"`
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

type runtimeMetadataDisk struct {
	Version         int    `json:"version"`
	ID              string `json:"id"`
	Platform        string `json:"platform"`
	Name            string `json:"name,omitempty"`
	ArchiveName     string `json:"archiveName,omitempty"`
	InstallDirRel   string `json:"installDirRel"`
	RootDirRel      string `json:"rootDirRel"`
	ServerRel       string `json:"serverRel"`
	RPCRel          string `json:"rpcRel,omitempty"`
	LicensePathRel  string `json:"licensePathRel,omitempty"`
	RuntimeVersion  string `json:"runtimeVersion,omitempty"`
	InstalledAt     string `json:"installedAt,omitempty"`
	Active          bool   `json:"active,omitempty"`
	VMInstalled     bool   `json:"vmInstalled,omitempty"`
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

	// Legacy absolute fields are accepted on read only.
	InstallDir  string `json:"installDir,omitempty"`
	RootDir     string `json:"rootDir,omitempty"`
	ServerPath  string `json:"serverPath,omitempty"`
	RPCPath     string `json:"rpcPath,omitempty"`
	LicensePath string `json:"licensePath,omitempty"`
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
	m.ensureMu.Lock()
	defer m.ensureMu.Unlock()
	manifest, root, err := m.readBootstrapRuntimeManifest()
	if err != nil || manifest == nil {
		return err
	}
	family := normalizeReleaseFamily(manifest.Family)
	if family != "llama" {
		return nil
	}
	macAsset, ok := manifest.Assets["macos"]
	if !ok || strings.TrimSpace(macAsset.Path) == "" {
		return fmt.Errorf("bundled llama runtime manifest is missing macOS asset")
	}
	if _, err := m.ensureBootstrapRuntimeAsset(ctx, "macos", managedRuntimeID(family, "macos", ""), *manifest, macAsset, root, "", ""); err != nil {
		return err
	}
	for _, backend := range []string{"cuda13", "vulkan"} {
		asset, ok := manifest.Assets[backend]
		if !ok || strings.TrimSpace(asset.Path) == "" {
			return fmt.Errorf("bundled llama runtime manifest is missing %s Linux asset", backendLabel(backend))
		}
		pairID := managedRuntimePairID(family, backend)
		if _, err := m.ensureBootstrapRuntimeAsset(ctx, "linux", managedRuntimeID(family, "linux", backend), *manifest, asset, root, backend, pairID); err != nil {
			return err
		}
	}
	cfg := m.store.Get()
	if backend, ok := shouldAutoSelectBundledStandardBackend(cfg); ok {
		mac, macErr := m.loadRuntimeDirect("macos", managedRuntimeID(family, "macos", ""))
		linux, linuxErr := m.loadRuntimeDirect("linux", managedRuntimeID(family, "linux", backend))
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

func (m *RuntimeManager) ensureBootstrapRuntimeAsset(ctx context.Context, platform, id string, manifest BootstrapRuntimeManifest, asset BootstrapRuntimeAsset, root, backend, pairID string) (ManagedRuntime, error) {
	if normalizeRuntimePlatform(platform) == "linux" {
		backend = normalizeLinuxBackend(backend)
	} else {
		backend = ""
	}
	id = sanitizeID(id)
	if runtimeInfo, err := m.loadRuntimeDirect(platform, id); err == nil && runtimeMatchesBundledAsset(runtimeInfo, manifest, asset, backend, pairID) {
		changed := false
		if platform == "linux" && legacyRuntimeInstallMessage(runtimeInfo.InstallError) {
			runtimeInfo.InstallError = ""
			changed = true
		}
		if changed {
			return runtimeInfo, writeRuntimeMetadata(runtimeInfo)
		}
		return runtimeInfo, nil
	}
	return m.installBootstrapArchive(ctx, platform, id, manifest, asset, root, backend, pairID)
}

func (m *RuntimeManager) installBootstrapArchive(ctx context.Context, platform, id string, manifest BootstrapRuntimeManifest, asset BootstrapRuntimeAsset, root, backend, pairID string) (ManagedRuntime, error) {
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
		PairID:       pairID,
		AssetName:    asset.Name,
		DownloadURL:  asset.DownloadURL,
		SHA256:       asset.SHA256,
	})
}

func runtimeMatchesBundledAsset(runtimeInfo ManagedRuntime, manifest BootstrapRuntimeManifest, asset BootstrapRuntimeAsset, backend, pairID string) bool {
	if !runtimeMetadataUsable(runtimeInfo) {
		return false
	}
	if runtimeInfo.Family != normalizeReleaseFamily(manifest.Family) {
		return false
	}
	if strings.TrimSpace(runtimeInfo.ReleaseTag) != strings.TrimSpace(manifest.Tag) {
		return false
	}
	if strings.TrimSpace(asset.SHA256) != "" && !strings.EqualFold(strings.TrimSpace(runtimeInfo.SHA256), strings.TrimSpace(asset.SHA256)) {
		return false
	}
	if strings.TrimSpace(asset.Name) != "" && strings.TrimSpace(runtimeInfo.AssetName) != strings.TrimSpace(asset.Name) {
		return false
	}
	if normalizeRuntimePlatform(runtimeInfo.Platform) == "linux" {
		if normalizeLinuxBackend(runtimeInfo.LinuxBackend) != normalizeLinuxBackend(backend) {
			return false
		}
		if sanitizeID(runtimeInfo.PairID) != sanitizeID(pairID) {
			return false
		}
	} else if strings.TrimSpace(runtimeInfo.PairID) != "" {
		return false
	}
	return true
}

func runtimeMetadataUsable(runtimeInfo ManagedRuntime) bool {
	if strings.TrimSpace(runtimeInfo.InstallDir) == "" || strings.TrimSpace(runtimeInfo.RootDir) == "" || strings.TrimSpace(runtimeInfo.ServerPath) == "" {
		return false
	}
	if _, err := os.Stat(runtimeInfo.RootDir); err != nil {
		return false
	}
	if info, err := os.Stat(runtimeInfo.ServerPath); err != nil || info.IsDir() {
		return false
	}
	return true
}

func legacyRuntimeInstallMessage(value string) bool {
	value = strings.ToLower(strings.TrimSpace(value))
	return strings.Contains(value, "first boot") ||
		strings.Contains(value, "bundled seed") ||
		strings.Contains(value, "vm runtime is missing from")
}

func shouldAutoSelectBundledStandardBackend(cfg AppConfig) (string, bool) {
	noActive := strings.TrimSpace(cfg.Runtime.ActiveRuntimePair) == "" &&
		strings.TrimSpace(cfg.Runtime.ActiveMacRuntime) == "" &&
		strings.TrimSpace(cfg.Runtime.ActiveLinuxRuntime) == "" &&
		(strings.TrimSpace(cfg.Runtime.ActiveVersion) == "" || strings.EqualFold(strings.TrimSpace(cfg.Runtime.ActiveVersion), "none"))
	if noActive {
		return "cuda13", true
	}
	if strings.TrimSpace(cfg.Runtime.ActiveRuntimePair) != "" ||
		strings.TrimSpace(cfg.Runtime.ActiveMacRuntime) != "" ||
		strings.TrimSpace(cfg.Runtime.ActiveLinuxRuntime) != "" {
		return "", false
	}
	values := []string{
		cfg.Runtime.ActiveRuntimePair,
		cfg.Runtime.ActiveVersion,
		cfg.Runtime.ActiveMacRuntime,
		cfg.Runtime.ActiveLinuxRuntime,
		cfg.Runtime.UpdateChannel,
	}
	for _, raw := range values {
		lower := strings.ToLower(strings.TrimSpace(raw))
		if lower == "" {
			continue
		}
		if strings.Contains(lower, "turbo") {
			return "", false
		}
		if strings.Contains(lower, "custom") && !strings.Contains(lower, "llama") {
			return "", false
		}
	}
	for _, raw := range values {
		lower := strings.ToLower(strings.TrimSpace(raw))
		if !strings.Contains(lower, "llama") {
			continue
		}
		switch {
		case strings.Contains(lower, "vulkan"):
			return "vulkan", true
		case strings.Contains(lower, "cuda13") || strings.Contains(lower, "cuda-13") || strings.Contains(lower, "cuda"):
			return "cuda13", true
		}
	}
	if normalizeReleaseFamily(cfg.Runtime.UpdateChannel) == "llama" {
		return "cuda13", true
	}
	return "", false
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
	if runtimeInfo.Platform == "linux" {
		runtimeInfo.LinuxBackend = normalizeLinuxBackend(metadata.LinuxBackend)
	}
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
		next.Runtime.LlamaServerPath = m.configRuntimePath(runtimeInfo.ServerPath)
		if runtimeInfo.RPCPath != "" {
			next.Runtime.RPCServerPath = m.configRuntimePath(runtimeInfo.RPCPath)
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
		ID:           runtimeInfo.ID,
		Platform:     runtimeInfo.Platform,
		SourceDir:    runtimeInfo.RootDir,
		ServerPath:   runtimeInfo.ServerPath,
		RPCPath:      runtimeInfo.RPCPath,
		Family:       runtimeInfo.Family,
		ReleaseTag:   runtimeInfo.ReleaseTag,
		SourceRef:    runtimeInfo.SourceRef,
		LinuxBackend: runtimeInfo.LinuxBackend,
		PairID:       runtimeInfo.PairID,
		AssetName:    runtimeInfo.AssetName,
		SHA256:       runtimeInfo.SHA256,
	})
	if err != nil {
		runtimeInfo.InstallError = err.Error()
		runtimeInfo.VMInstalled = false
		return err
	}
	installed := result.Active
	active := result.Active
	if isManagedRuntimeID(runtimeInfo.ID) {
		status, statusErr := m.runtime.BridgeRuntimeInstalled(installCtx, runtimeInfo.ID)
		if statusErr != nil {
			runtimeInfo.InstallError = statusErr.Error()
			runtimeInfo.VMInstalled = false
			return statusErr
		}
		if !status.Installed || !statusMatchesManagedRuntime(*runtimeInfo, status) {
			err := fmt.Errorf("VM runtime marker for %s does not match selected %s %s %s runtime", runtimeInfo.ID, runtimeInfo.Family, runtimeInfo.ReleaseTag, backendLabel(runtimeInfo.LinuxBackend))
			runtimeInfo.InstallError = err.Error()
			runtimeInfo.VMInstalled = false
			return err
		}
		installed = true
		active = status.Active
	}
	runtimeInfo.InstallError = ""
	runtimeInfo.VMInstalled = installed
	runtimeInfo.VMDeletePending = false
	runtimeInfo.Active = active
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
	probeCtx, cancel := context.WithTimeout(ctx, linuxInstallStateRefreshTimeout)
	defer cancel()
	status, err := m.runtime.BridgeRuntimeInstalled(probeCtx, runtimeInfo.ID)
	if err != nil {
		changed := false
		if legacyRuntimeInstallMessage(runtimeInfo.InstallError) {
			runtimeInfo.InstallError = ""
			changed = true
		}
		if changed {
			_ = writeRuntimeMetadata(*runtimeInfo)
		}
		return
	}
	installed := status.Installed
	active := status.Active
	if installed && isManagedRuntimeID(runtimeInfo.ID) && !statusMatchesManagedRuntime(*runtimeInfo, status) {
		installed = false
		active = false
	}
	changed := false
	if runtimeInfo.VMInstalled != installed {
		runtimeInfo.VMInstalled = installed
		changed = true
	}
	if runtimeInfo.Active != active {
		runtimeInfo.Active = active
		changed = true
	}
	if installed && runtimeInfo.InstallError != "" {
		runtimeInfo.InstallError = ""
		changed = true
	} else if !installed && legacyRuntimeInstallMessage(runtimeInfo.InstallError) {
		runtimeInfo.InstallError = ""
		changed = true
	}
	if !installed && runtimeInfo.VMDeletePending {
		runtimeInfo.VMDeletePending = false
		changed = true
	}
	if changed {
		_ = writeRuntimeMetadata(*runtimeInfo)
	}
	if installed {
		_ = m.reconcileActiveLinuxRuntimeConfig(*runtimeInfo)
	}
}

func (m *RuntimeManager) reconcileActiveLinuxRuntimeConfig(runtimeInfo ManagedRuntime) error {
	if m.store == nil || runtimeInfo.Platform != "linux" || !runtimeInfo.VMInstalled {
		return nil
	}
	return m.store.Update(func(next *AppConfig) error {
		if runtimeInfo.ID != next.Runtime.ActiveLinuxRuntime && sanitizeID(runtimeInfo.PairID) != sanitizeID(next.Runtime.ActiveRuntimePair) {
			return nil
		}
		serverCommand := guestRuntimeExecutable(runtimeInfo, runtimeInfo.ServerRel, "/usr/local/bin/llama-server")
		rpcCommand := guestRuntimeExecutable(runtimeInfo, runtimeInfo.RPCRel, "/usr/local/bin/rpc-server")
		if strings.TrimSpace(next.Runtime.Residency.ServerCommand) == "" || next.Runtime.Residency.ServerCommand != serverCommand {
			next.Runtime.Residency.ServerCommand = serverCommand
		}
		if strings.TrimSpace(next.Runtime.Residency.RPCCommand) == "" || next.Runtime.Residency.RPCCommand != rpcCommand {
			next.Runtime.Residency.RPCCommand = rpcCommand
		}
		return nil
	})
}

func shouldRefreshLinuxInstallState(runtimeInfo ManagedRuntime, cfg AppConfig) bool {
	return isManagedRuntimeID(runtimeInfo.ID) ||
		runtimeInfo.ID == cfg.Runtime.ActiveLinuxRuntime ||
		runtimeInfo.Active ||
		runtimeInfo.VMDeletePending ||
		strings.TrimSpace(runtimeInfo.InstallError) != ""
}

func statusMatchesManagedRuntime(runtimeInfo ManagedRuntime, status BridgeRuntimeInstalledResult) bool {
	if normalizeReleaseFamily(status.Family) != normalizeReleaseFamily(runtimeInfo.Family) {
		return false
	}
	if strings.TrimSpace(status.ReleaseTag) != strings.TrimSpace(runtimeInfo.ReleaseTag) {
		return false
	}
	if normalizeLinuxBackend(status.LinuxBackend) != normalizeLinuxBackend(runtimeInfo.LinuxBackend) {
		return false
	}
	if strings.TrimSpace(runtimeInfo.SHA256) != "" && strings.TrimSpace(status.SHA256) != "" && !strings.EqualFold(strings.TrimSpace(runtimeInfo.SHA256), strings.TrimSpace(status.SHA256)) {
		return false
	}
	if strings.TrimSpace(status.ArchiveName) != "" && strings.TrimSpace(runtimeInfo.AssetName) != "" && strings.TrimSpace(status.ArchiveName) != strings.TrimSpace(runtimeInfo.AssetName) {
		return false
	}
	return true
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
			rewriteRuntimeMetadataIfPortable(runtimeInfo)
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
	runtimeInfo, err := readRuntimeMetadata(filepath.Join(m.platformDir(platform), id, runtimeMetadataFile))
	if err == nil {
		rewriteRuntimeMetadataIfPortable(runtimeInfo)
	}
	return runtimeInfo, err
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
			rewriteRuntimeMetadataIfPortable(runtimeInfo)
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
	pairID := sanitizeID(linux.PairID)
	if pairID == "" {
		pairID = sanitizeID(mac.PairID)
	}
	if pairID == "" {
		return nil
	}
	if mac.PairID != "" && sanitizeID(mac.PairID) != pairID && !isManagedSharedMacRuntime(mac) {
		return nil
	}
	if err := m.store.Update(func(next *AppConfig) error {
		next.Runtime.LlamaServerPath = m.configRuntimePath(mac.ServerPath)
		if mac.RPCPath != "" {
			next.Runtime.RPCServerPath = m.configRuntimePath(mac.RPCPath)
		}
		next.Runtime.ReleaseRepo = firstNonEmpty(mac.DownloadURL, linux.DownloadURL, "custom")
		next.Runtime.ActiveVersion = pairID
		next.Runtime.ActiveRuntimePair = pairID
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
	if runtimeInfo.VMInstalled && strings.HasPrefix(sanitizeID(runtimeInfo.ID), "managed-llama-") {
		return fallback
	}
	rel = strings.TrimSpace(filepath.ToSlash(rel))
	if rel == "" || rel == "." || rel == ".." || strings.HasPrefix(rel, "/") || strings.HasPrefix(rel, "../") {
		return fallback
	}
	return path.Join(vmRuntimeHomeRoot, sanitizeID(runtimeInfo.ID), rel)
}

func (m *RuntimeManager) platformDir(platform string) string {
	return filepath.Join(m.runtime.WorkDir(), "runtimes", platform)
}

func (m *RuntimeManager) profileRoot() string {
	if m.runtime != nil {
		return m.runtime.ProfileRoot()
	}
	return profileRootFromWorkDir(filepath.Join(m.appDir, "ai", "llms"))
}

func (m *RuntimeManager) configRuntimePath(value string) string {
	if rel, ok := profileRelativePath(m.profileRoot(), value); ok {
		return rel
	}
	return value
}

func profileRootFromRuntimePath(value string) string {
	clean := filepath.Clean(expandPath(strings.TrimSpace(value)))
	if clean == "" || clean == "." {
		return ""
	}
	sep := string(filepath.Separator)
	marker := sep + filepath.Join("ai", "llms", "runtimes") + sep
	if idx := strings.Index(clean, marker); idx >= 0 {
		root := clean[:idx]
		if root == "" {
			return sep
		}
		return root
	}
	if strings.HasSuffix(clean, sep+filepath.Join("ai", "llms", "runtimes")) {
		return strings.TrimSuffix(clean, sep+filepath.Join("ai", "llms", "runtimes"))
	}
	if strings.HasSuffix(clean, sep+filepath.Join("ai", "llms")) {
		return strings.TrimSuffix(clean, sep+filepath.Join("ai", "llms"))
	}
	return profileRootFromEnv()
}

func profileRelativePath(profileRoot, value string) (string, bool) {
	profileRoot = filepath.Clean(expandPath(strings.TrimSpace(profileRoot)))
	value = filepath.Clean(expandPath(strings.TrimSpace(value)))
	if profileRoot == "" || value == "" || !filepath.IsAbs(value) || !pathInside(profileRoot, value) {
		return "", false
	}
	rel, err := filepath.Rel(profileRoot, value)
	if err != nil || rel == "." || strings.HasPrefix(rel, "..") {
		return "", false
	}
	return filepath.ToSlash(rel), true
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
	profileRoot := profileRootFromRuntimePath(runtimeInfo.InstallDir)
	if profileRoot == "" {
		return fmt.Errorf("runtime install directory is outside the machine profile: %s", runtimeInfo.InstallDir)
	}
	installDirRel, ok := profileRelativePath(profileRoot, runtimeInfo.InstallDir)
	if !ok {
		return fmt.Errorf("runtime install directory is outside the machine profile: %s", runtimeInfo.InstallDir)
	}
	rootDirRel, ok := profileRelativePath(profileRoot, runtimeInfo.RootDir)
	if !ok {
		return fmt.Errorf("runtime root directory is outside the machine profile: %s", runtimeInfo.RootDir)
	}
	licensePathRel := ""
	if strings.TrimSpace(runtimeInfo.LicensePath) != "" {
		if rel, ok := profileRelativePath(profileRoot, runtimeInfo.LicensePath); ok {
			licensePathRel = rel
		}
	}
	disk := runtimeMetadataDisk{
		Version:         2,
		ID:              runtimeInfo.ID,
		Platform:        runtimeInfo.Platform,
		Name:            runtimeInfo.Name,
		ArchiveName:     runtimeInfo.ArchiveName,
		InstallDirRel:   installDirRel,
		RootDirRel:      rootDirRel,
		ServerRel:       filepath.ToSlash(runtimeInfo.ServerRel),
		RPCRel:          filepath.ToSlash(runtimeInfo.RPCRel),
		LicensePathRel:  licensePathRel,
		RuntimeVersion:  runtimeInfo.Version,
		InstalledAt:     runtimeInfo.InstalledAt,
		Active:          runtimeInfo.Active,
		VMInstalled:     runtimeInfo.VMInstalled,
		InstallError:    runtimeInfo.InstallError,
		Family:          runtimeInfo.Family,
		ReleaseTag:      runtimeInfo.ReleaseTag,
		SourceRef:       runtimeInfo.SourceRef,
		LinuxBackend:    runtimeInfo.LinuxBackend,
		PairID:          runtimeInfo.PairID,
		AssetName:       runtimeInfo.AssetName,
		DownloadURL:     runtimeInfo.DownloadURL,
		SHA256:          runtimeInfo.SHA256,
		VMDeletePending: runtimeInfo.VMDeletePending,
	}
	return writeJSONAtomic(filepath.Join(runtimeInfo.InstallDir, runtimeMetadataFile), disk)
}

func rewriteRuntimeMetadataIfPortable(runtimeInfo ManagedRuntime) {
	if strings.TrimSpace(runtimeInfo.InstallError) != "" ||
		strings.TrimSpace(runtimeInfo.InstallDir) == "" ||
		strings.TrimSpace(runtimeInfo.RootDir) == "" ||
		strings.TrimSpace(runtimeInfo.ServerPath) == "" {
		return
	}
	_ = writeRuntimeMetadata(runtimeInfo)
}

func readRuntimeMetadata(path string) (ManagedRuntime, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return ManagedRuntime{}, err
	}
	var disk runtimeMetadataDisk
	if err := json.Unmarshal(raw, &disk); err != nil {
		return ManagedRuntime{}, err
	}
	if disk.RuntimeVersion == "" {
		var legacy struct {
			Version string `json:"version"`
		}
		if err := json.Unmarshal(raw, &legacy); err == nil && strings.TrimSpace(legacy.Version) != "" {
			disk.RuntimeVersion = legacy.Version
		}
	}
	profileRoot := profileRootFromRuntimePath(path)
	runtimeInfo := ManagedRuntime{
		ID:              disk.ID,
		Platform:        normalizeRuntimePlatform(disk.Platform),
		Name:            disk.Name,
		ArchiveName:     disk.ArchiveName,
		InstallDirRel:   filepath.ToSlash(disk.InstallDirRel),
		RootDirRel:      filepath.ToSlash(disk.RootDirRel),
		ServerRel:       filepath.ToSlash(disk.ServerRel),
		RPCRel:          filepath.ToSlash(disk.RPCRel),
		LicensePathRel:  filepath.ToSlash(disk.LicensePathRel),
		InstalledAt:     disk.InstalledAt,
		Version:         disk.RuntimeVersion,
		Active:          disk.Active,
		VMInstalled:     disk.VMInstalled,
		InstallError:    disk.InstallError,
		Family:          disk.Family,
		ReleaseTag:      disk.ReleaseTag,
		SourceRef:       disk.SourceRef,
		LinuxBackend:    disk.LinuxBackend,
		PairID:          disk.PairID,
		AssetName:       disk.AssetName,
		DownloadURL:     disk.DownloadURL,
		SHA256:          disk.SHA256,
		VMDeletePending: disk.VMDeletePending,
	}
	if runtimeInfo.Platform == "" {
		runtimeInfo.Platform = normalizeRuntimePlatform(filepath.Base(filepath.Dir(filepath.Dir(path))))
	}
	resolve := func(rel, legacyAbs, label string) (string, string) {
		if strings.TrimSpace(rel) != "" {
			if profileRoot == "" {
				return "", fmt.Sprintf("%s cannot resolve without a machine profile root", label)
			}
			return filepath.Clean(filepath.Join(profileRoot, filepath.FromSlash(rel))), ""
		}
		legacyAbs = filepath.Clean(expandPath(strings.TrimSpace(legacyAbs)))
		if legacyAbs == "." || legacyAbs == "" {
			return "", ""
		}
		if !filepath.IsAbs(legacyAbs) {
			return filepath.Clean(filepath.Join(filepath.Dir(path), legacyAbs)), ""
		}
		if profileRoot != "" && pathInside(profileRoot, legacyAbs) {
			if rel, ok := profileRelativePath(profileRoot, legacyAbs); ok {
				switch label {
				case "installDir":
					runtimeInfo.InstallDirRel = rel
				case "rootDir":
					runtimeInfo.RootDirRel = rel
				case "licensePath":
					runtimeInfo.LicensePathRel = rel
				}
			}
			return legacyAbs, ""
		}
		return "", fmt.Sprintf("%s points outside this machine profile: %s", label, legacyAbs)
	}
	var invalid []string
	var detail string
	if runtimeInfo.InstallDir, detail = resolve(disk.InstallDirRel, disk.InstallDir, "installDir"); detail != "" {
		invalid = append(invalid, detail)
	}
	if runtimeInfo.RootDir, detail = resolve(disk.RootDirRel, disk.RootDir, "rootDir"); detail != "" {
		invalid = append(invalid, detail)
	}
	if strings.TrimSpace(disk.ServerRel) != "" && runtimeInfo.RootDir != "" {
		runtimeInfo.ServerPath = filepath.Clean(filepath.Join(runtimeInfo.RootDir, filepath.FromSlash(disk.ServerRel)))
	} else if strings.TrimSpace(disk.ServerPath) != "" {
		if profileRoot != "" && pathInside(profileRoot, filepath.Clean(expandPath(disk.ServerPath))) {
			runtimeInfo.ServerPath = filepath.Clean(expandPath(disk.ServerPath))
			if rel, relErr := filepath.Rel(runtimeInfo.RootDir, runtimeInfo.ServerPath); relErr == nil && rel != "." && !strings.HasPrefix(rel, "..") {
				runtimeInfo.ServerRel = filepath.ToSlash(rel)
			}
		} else {
			invalid = append(invalid, "serverPath points outside this machine profile")
		}
	}
	if strings.TrimSpace(disk.RPCRel) != "" && runtimeInfo.RootDir != "" {
		runtimeInfo.RPCPath = filepath.Clean(filepath.Join(runtimeInfo.RootDir, filepath.FromSlash(disk.RPCRel)))
	} else if strings.TrimSpace(disk.RPCPath) != "" {
		if profileRoot != "" && pathInside(profileRoot, filepath.Clean(expandPath(disk.RPCPath))) {
			runtimeInfo.RPCPath = filepath.Clean(expandPath(disk.RPCPath))
			if rel, relErr := filepath.Rel(runtimeInfo.RootDir, runtimeInfo.RPCPath); relErr == nil && rel != "." && !strings.HasPrefix(rel, "..") {
				runtimeInfo.RPCRel = filepath.ToSlash(rel)
			}
		} else {
			invalid = append(invalid, "rpcPath points outside this machine profile")
		}
	}
	if runtimeInfo.LicensePath, detail = resolve(disk.LicensePathRel, disk.LicensePath, "licensePath"); detail != "" {
		invalid = append(invalid, detail)
	}
	if runtimeInfo.InstallDir == "" {
		runtimeInfo.InstallDir = filepath.Dir(path)
	}
	if len(invalid) > 0 && runtimeInfo.InstallError == "" {
		runtimeInfo.InstallError = strings.Join(invalid, "; ")
	}
	return runtimeInfo, nil
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
