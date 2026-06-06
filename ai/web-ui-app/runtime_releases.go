package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"
)

var arm64BuildsAPI = "https://api.github.com/repos/openresearchtools/llama-cpp-arm64-builds/releases?per_page=100"

type RuntimeReleaseAsset struct {
	Name        string `json:"name"`
	DownloadURL string `json:"downloadUrl"`
	Size        int64  `json:"size"`
	ContentType string `json:"contentType,omitempty"`
	SHA256      string `json:"sha256,omitempty"`
}

type RuntimeRelease struct {
	Family           string              `json:"family"`
	Tag              string              `json:"tag"`
	Name             string              `json:"name"`
	PublishedAt      string              `json:"publishedAt"`
	Source           string              `json:"source"`
	SourceRef        string              `json:"sourceRef"`
	MacOSAsset       RuntimeReleaseAsset `json:"macosAsset"`
	LinuxCUDAAsset   RuntimeReleaseAsset `json:"linuxCudaAsset"`
	LinuxVulkanAsset RuntimeReleaseAsset `json:"linuxVulkanAsset"`
}

type RuntimeFetchInstallResult struct {
	Pair     RuntimePair        `json:"pair"`
	MacOS    ManagedRuntime     `json:"macos"`
	Linux    ManagedRuntime     `json:"linux"`
	Runtimes RuntimeListPayload `json:"runtimes"`
}

type githubRelease struct {
	TagName    string        `json:"tag_name"`
	Name       string        `json:"name"`
	Published  string        `json:"published_at"`
	Draft      bool          `json:"draft"`
	Prerelease bool          `json:"prerelease"`
	Body       string        `json:"body"`
	Assets     []githubAsset `json:"assets"`
}

type githubAsset struct {
	Name        string `json:"name"`
	DownloadURL string `json:"browser_download_url"`
	Size        int64  `json:"size"`
	ContentType string `json:"content_type"`
}

func (m *RuntimeManager) ListReleases(ctx context.Context, family string) ([]RuntimeRelease, error) {
	family = normalizeReleaseFamily(family)
	if family == "" {
		return nil, fmt.Errorf("family must be llama or turbo")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, arm64BuildsAPI, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "PEGPU-web-ui-app")
	resp, err := m.runtime.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return nil, fmt.Errorf("GitHub releases HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	var payload []githubRelease
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}
	releases := make([]RuntimeRelease, 0, len(payload))
	for _, item := range payload {
		release, ok := parseRuntimeRelease(item)
		if !ok || release.Family != family {
			continue
		}
		releases = append(releases, release)
	}
	sort.SliceStable(releases, func(i, j int) bool {
		ti, _ := time.Parse(time.RFC3339, releases[i].PublishedAt)
		tj, _ := time.Parse(time.RFC3339, releases[j].PublishedAt)
		return ti.After(tj)
	})
	return releases, nil
}

func (m *RuntimeManager) FetchInstall(ctx context.Context, family, tag, linuxBackend string) (RuntimeFetchInstallResult, error) {
	var out RuntimeFetchInstallResult
	backend := normalizeLinuxBackend(linuxBackend)
	if backend == "" {
		backend = "cuda13"
	}
	release, err := m.resolveRelease(ctx, family, tag)
	if err != nil {
		return out, err
	}
	linuxAsset := release.LinuxCUDAAsset
	if backend == "vulkan" {
		linuxAsset = release.LinuxVulkanAsset
	}
	if release.MacOSAsset.Name == "" || linuxAsset.Name == "" {
		return out, fmt.Errorf("release %s does not have matched macOS and %s Linux assets", release.Tag, backendLabel(backend))
	}
	releaseFamily := normalizeReleaseFamily(release.Family)
	pairID := managedRuntimePairID(releaseFamily, backend)
	macRuntime, err := m.ensureDownloadedReleaseRuntime(ctx, "macos", managedRuntimeID(releaseFamily, "macos", ""), release, release.MacOSAsset, "", "")
	if err != nil {
		return out, err
	}
	linuxRuntime, err := m.ensureDownloadedReleaseRuntime(ctx, "linux", managedRuntimeID(releaseFamily, "linux", backend), release, linuxAsset, backend, pairID)
	if err != nil {
		return out, err
	}

	installErr := m.installLinuxRuntime(ctx, &linuxRuntime, false)
	if writeErr := writeRuntimeMetadata(linuxRuntime); writeErr != nil {
		return out, writeErr
	}
	if installErr == nil && linuxRuntime.VMInstalled {
		if err := m.selectRuntimePairLocal(macRuntime, linuxRuntime); err != nil {
			return out, err
		}
		macRuntime.Active = true
		linuxRuntime.Active = true
	}
	if err := writeRuntimeMetadata(macRuntime); err != nil {
		return out, err
	}
	pair, _ := m.loadRuntimePair(pairID)
	list, _ := m.List(ctx)
	out.Pair = pair
	out.MacOS = macRuntime
	out.Linux = linuxRuntime
	out.Runtimes = list
	return out, nil
}

func (m *RuntimeManager) ActivatePair(ctx context.Context, pairID string) (RuntimePair, error) {
	pairID = sanitizeID(pairID)
	pair, ok := m.loadRuntimePair(pairID)
	if !ok || pair.MacOS == nil || pair.Linux == nil {
		return pair, fmt.Errorf("runtime pair %s is incomplete or not found", pairID)
	}
	mac := *pair.MacOS
	linux := *pair.Linux
	installErr := m.installLinuxRuntime(ctx, &linux, false)
	if writeErr := writeRuntimeMetadata(linux); writeErr != nil {
		return pair, writeErr
	}
	if installErr == nil && linux.VMInstalled {
		if err := m.selectRuntimePairLocal(mac, linux); err != nil {
			return pair, err
		}
	}
	pair, _ = m.loadRuntimePair(pairID)
	return pair, nil
}

func (m *RuntimeManager) DeletePair(ctx context.Context, pairID string) error {
	pairID = sanitizeID(pairID)
	pair, ok := m.loadRuntimePair(pairID)
	if !ok {
		return fmt.Errorf("runtime pair %s not found", pairID)
	}
	if pair.Active {
		return fmt.Errorf("runtime pair %s is active; choose another runtime before deleting it", pairID)
	}
	if pair.MacOS != nil && !isManagedSharedMacRuntime(*pair.MacOS) {
		if err := m.Delete(ctx, pair.MacOS.ID); err != nil {
			return err
		}
	}
	if pair.Linux == nil {
		return nil
	}
	linux := *pair.Linux
	if linux.VMInstalled && !linux.VMDeletePending {
		deleteCtx, cancel := context.WithTimeout(ctx, 5*time.Minute)
		err := m.runtime.DeleteBridgeRuntime(deleteCtx, linux.ID)
		cancel()
		if err != nil {
			linux.InstallError = err.Error()
			linux.VMDeletePending = true
			_ = writeRuntimeMetadata(linux)
		}
	}
	cfg := m.store.Get()
	if m.isRuntimeActive(linux, cfg) {
		return fmt.Errorf("runtime %s is active; choose another runtime before deleting it", linux.ID)
	}
	if err := os.RemoveAll(linux.InstallDir); err != nil {
		return err
	}
	return nil
}

func (m *RuntimeManager) ensureDownloadedReleaseRuntime(ctx context.Context, platform, id string, release RuntimeRelease, asset RuntimeReleaseAsset, backend, pairID string) (ManagedRuntime, error) {
	if runtimeInfo, err := m.loadRuntimeDirect(platform, id); err == nil && runtimeMatchesReleaseAsset(runtimeInfo, release, asset, backend, pairID) {
		return runtimeInfo, nil
	}
	return m.downloadAndInstallArchive(ctx, platform, id, release, asset, backend, pairID)
}

func (m *RuntimeManager) downloadAndInstallArchive(ctx context.Context, platform, id string, release RuntimeRelease, asset RuntimeReleaseAsset, backend, pairID string) (ManagedRuntime, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, asset.DownloadURL, nil)
	if err != nil {
		return ManagedRuntime{}, err
	}
	req.Header.Set("User-Agent", "PEGPU-web-ui-app")
	resp, err := m.runtime.client.Do(req)
	if err != nil {
		return ManagedRuntime{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return ManagedRuntime{}, fmt.Errorf("download %s HTTP %d: %s", asset.Name, resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	return m.installArchive(ctx, platform, id, asset.Name, resp.Body, RuntimeInstallMetadata{
		Family:       release.Family,
		ReleaseTag:   release.Tag,
		SourceRef:    release.SourceRef,
		LinuxBackend: backend,
		PairID:       pairID,
		AssetName:    asset.Name,
		DownloadURL:  asset.DownloadURL,
		SHA256:       asset.SHA256,
	})
}

func runtimeMatchesReleaseAsset(runtimeInfo ManagedRuntime, release RuntimeRelease, asset RuntimeReleaseAsset, backend, pairID string) bool {
	if !runtimeMetadataUsable(runtimeInfo) {
		return false
	}
	if runtimeInfo.Family != normalizeReleaseFamily(release.Family) {
		return false
	}
	if strings.TrimSpace(runtimeInfo.ReleaseTag) != strings.TrimSpace(release.Tag) {
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

func (m *RuntimeManager) resolveRelease(ctx context.Context, family, tag string) (RuntimeRelease, error) {
	releases, err := m.ListReleases(ctx, family)
	if err != nil {
		return RuntimeRelease{}, err
	}
	if len(releases) == 0 {
		return RuntimeRelease{}, fmt.Errorf("no %s releases found", normalizeReleaseFamily(family))
	}
	tag = strings.TrimSpace(tag)
	if tag == "" || strings.EqualFold(tag, "latest") {
		return releases[0], nil
	}
	for _, release := range releases {
		if release.Tag == tag {
			return release, nil
		}
	}
	return RuntimeRelease{}, fmt.Errorf("release %s not found for %s", tag, normalizeReleaseFamily(family))
}

func parseRuntimeRelease(item githubRelease) (RuntimeRelease, bool) {
	if item.Draft || item.Prerelease {
		return RuntimeRelease{}, false
	}
	source := parseBacktickField(item.Body, `(?m)^Source:\s*`+"`([^`]+)`")
	sourceRef := parseBacktickField(item.Body, `(?m)^Source ref:\s*`+"`([^`]+)`")
	family := familyFromSource(source, item.TagName)
	if family == "" {
		return RuntimeRelease{}, false
	}
	release := RuntimeRelease{
		Family:      family,
		Tag:         strings.TrimSpace(item.TagName),
		Name:        strings.TrimSpace(item.Name),
		PublishedAt: strings.TrimSpace(item.Published),
		Source:      strings.TrimSpace(source),
		SourceRef:   strings.TrimSpace(sourceRef),
	}
	for _, asset := range item.Assets {
		next := RuntimeReleaseAsset{
			Name:        asset.Name,
			DownloadURL: asset.DownloadURL,
			Size:        asset.Size,
			ContentType: asset.ContentType,
			SHA256:      parseAssetSHA256(item.Body, asset.Name),
		}
		lower := strings.ToLower(asset.Name)
		switch {
		case strings.HasSuffix(lower, "-bin-macos-arm64.tar.gz"):
			release.MacOSAsset = next
		case strings.HasSuffix(lower, "-bin-debian-trixie-cuda13-arm64.tar.gz"):
			release.LinuxCUDAAsset = next
		case strings.HasSuffix(lower, "-bin-debian-trixie-vulkan-arm64.tar.gz"):
			release.LinuxVulkanAsset = next
		}
	}
	return release, release.MacOSAsset.Name != "" && (release.LinuxCUDAAsset.Name != "" || release.LinuxVulkanAsset.Name != "")
}

func runtimePairs(runtimes []ManagedRuntime, cfg AppConfig) []RuntimePair {
	byID := map[string]*RuntimePair{}
	managedMacByFamily := map[string]ManagedRuntime{}
	for _, runtimeInfo := range runtimes {
		if isManagedSharedMacRuntime(runtimeInfo) {
			managedMacByFamily[runtimeInfo.Family] = runtimeInfo
			continue
		}
		pairID := sanitizeID(runtimeInfo.PairID)
		if pairID == "" && isManagedLinuxRuntime(runtimeInfo) {
			pairID = managedRuntimePairID(runtimeInfo.Family, runtimeInfo.LinuxBackend)
		}
		if pairID == "" {
			continue
		}
		pair := byID[pairID]
		if pair == nil {
			pair = &RuntimePair{ID: pairID}
			byID[pairID] = pair
		}
		pair.Family = firstNonEmpty(pair.Family, runtimeInfo.Family)
		pair.ReleaseTag = firstNonEmpty(pair.ReleaseTag, runtimeInfo.ReleaseTag)
		pair.SourceRef = firstNonEmpty(pair.SourceRef, runtimeInfo.SourceRef)
		pair.LinuxBackend = firstNonEmpty(pair.LinuxBackend, runtimeInfo.LinuxBackend)
		pair.InstalledAt = maxText(pair.InstalledAt, runtimeInfo.InstalledAt)
		item := runtimeInfo
		switch runtimeInfo.Platform {
		case "macos":
			pair.MacOS = &item
		case "linux":
			pair.VMInstalled = runtimeInfo.VMInstalled
			pair.VMDeletePending = runtimeInfo.VMDeletePending
			pair.InstallError = runtimeInfo.InstallError
			pair.Linux = &item
		}
	}
	for _, pair := range byID {
		if pair.MacOS != nil {
			continue
		}
		if pair.Linux == nil || !isManagedLinuxRuntime(*pair.Linux) {
			continue
		}
		if mac, ok := managedMacByFamily[pair.Linux.Family]; ok {
			item := mac
			pair.MacOS = &item
			pair.Family = firstNonEmpty(pair.Family, item.Family)
			pair.ReleaseTag = firstNonEmpty(pair.ReleaseTag, item.ReleaseTag)
			pair.SourceRef = firstNonEmpty(pair.SourceRef, item.SourceRef)
			pair.InstalledAt = maxText(pair.InstalledAt, item.InstalledAt)
		}
	}
	out := make([]RuntimePair, 0, len(byID))
	for _, pair := range byID {
		pair.Active = runtimePairActive(*pair, cfg)
		out = append(out, *pair)
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].InstalledAt > out[j].InstalledAt
	})
	return out
}

func runtimePairActive(pair RuntimePair, cfg AppConfig) bool {
	return cfg.Runtime.ActiveRuntimePair != "" &&
		pair.ID == cfg.Runtime.ActiveRuntimePair &&
		pair.MacOS != nil &&
		pair.Linux != nil &&
		pair.MacOS.ID == cfg.Runtime.ActiveMacRuntime &&
		pair.Linux.ID == cfg.Runtime.ActiveLinuxRuntime
}

func (m *RuntimeManager) loadRuntimePair(pairID string) (RuntimePair, bool) {
	list, err := m.List(context.Background())
	if err != nil {
		return RuntimePair{}, false
	}
	for _, pair := range list.Pairs {
		if pair.ID == sanitizeID(pairID) {
			return pair, true
		}
	}
	return RuntimePair{}, false
}

func managedRuntimeID(family, platform, backend string) string {
	family = normalizeReleaseFamily(family)
	platform = normalizeRuntimePlatform(platform)
	switch platform {
	case "macos":
		return sanitizeID("managed-" + family + "-macos")
	case "linux":
		return sanitizeID("managed-" + family + "-" + normalizeLinuxBackend(backend) + "-linux")
	default:
		return ""
	}
}

func managedRuntimePairID(family, backend string) string {
	return sanitizeID("managed-" + normalizeReleaseFamily(family) + "-" + normalizeLinuxBackend(backend))
}

func isManagedRuntimeID(id string) bool {
	return strings.HasPrefix(sanitizeID(id), "managed-")
}

func isManagedSharedMacRuntime(runtimeInfo ManagedRuntime) bool {
	return normalizeRuntimePlatform(runtimeInfo.Platform) == "macos" &&
		runtimeInfo.ID == managedRuntimeID(runtimeInfo.Family, "macos", "")
}

func isManagedLinuxRuntime(runtimeInfo ManagedRuntime) bool {
	return normalizeRuntimePlatform(runtimeInfo.Platform) == "linux" &&
		runtimeInfo.ID == managedRuntimeID(runtimeInfo.Family, "linux", runtimeInfo.LinuxBackend)
}

func normalizeReleaseFamily(family string) string {
	switch strings.ToLower(strings.TrimSpace(family)) {
	case "llama", "llamacpp", "llama.cpp":
		return "llama"
	case "turbo", "turboquant", "tq":
		return "turbo"
	default:
		return ""
	}
}

func normalizeLinuxBackend(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "cuda", "cuda13", "cuda-13":
		return "cuda13"
	case "vulkan", "vk":
		return "vulkan"
	default:
		return ""
	}
}

func backendLabel(backend string) string {
	if normalizeLinuxBackend(backend) == "vulkan" {
		return "Vulkan"
	}
	return "CUDA 13"
}

func familyFromSource(source, tag string) string {
	source = strings.ToLower(strings.TrimSpace(source))
	tag = strings.ToLower(strings.TrimSpace(tag))
	switch {
	case strings.Contains(source, "llama-cpp-turboquant") || strings.HasPrefix(tag, "turbo-"):
		return "turbo"
	case strings.Contains(source, "ggml-org/llama.cpp"):
		return "llama"
	default:
		return ""
	}
}

func parseBacktickField(body, pattern string) string {
	match := regexp.MustCompile(pattern).FindStringSubmatch(body)
	if len(match) < 2 {
		return ""
	}
	return strings.TrimSpace(match[1])
}

func parseAssetSHA256(body, assetName string) string {
	if strings.TrimSpace(body) == "" || strings.TrimSpace(assetName) == "" {
		return ""
	}
	lines := strings.Split(body, "\n")
	for index, line := range lines {
		if !strings.Contains(line, assetName) {
			continue
		}
		for _, near := range lines[index:minInt(len(lines), index+4)] {
			if match := regexp.MustCompile(`(?i)sha256[:=\s]+([a-f0-9]{64})`).FindStringSubmatch(near); len(match) == 2 {
				return strings.ToLower(match[1])
			}
		}
	}
	return ""
}

func maxText(a, b string) string {
	if b > a {
		return b
	}
	return a
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
