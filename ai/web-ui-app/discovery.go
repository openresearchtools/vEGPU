package main

import (
	"bufio"
	"context"
	"crypto/sha1"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"
)

var ggufSplitFileRE = regexp.MustCompile(`(?i)^(.+)-([0-9]{5})-of-([0-9]{5})\.gguf$`)

type ggufSplitFile struct {
	Prefix string
	Index  int
	Count  int
}

type DiscoveredModel struct {
	ID         string            `json:"id"`
	Name       string            `json:"name"`
	Provider   string            `json:"provider"`
	Source     string            `json:"source"`
	Location   string            `json:"location,omitempty"`
	Format     string            `json:"format"`
	ModelPath  string            `json:"modelPath"`
	MmprojPath string            `json:"mmprojPath,omitempty"`
	SizeBytes  int64             `json:"sizeBytes"`
	Metadata   map[string]string `json:"metadata,omitempty"`
}

type DiscoveryService struct {
	appDir  string
	runtime *RuntimeService
}

func NewDiscoveryService(appDir string, runtimeSvc ...*RuntimeService) *DiscoveryService {
	var runtime *RuntimeService
	if len(runtimeSvc) > 0 {
		runtime = runtimeSvc[0]
	}
	return &DiscoveryService{appDir: appDir, runtime: runtime}
}

func (d *DiscoveryService) KnownRoots(cfg AppConfig) []string {
	seen := map[string]bool{}
	add := func(paths *[]string, p string) {
		p = expandPath(strings.TrimSpace(p))
		if p == "" {
			return
		}
		p = filepath.Clean(p)
		if seen[p] {
			return
		}
		seen[p] = true
		*paths = append(*paths, p)
	}
	roots := []string{}
	for _, p := range cfg.Discovery.ExtraFolders {
		add(&roots, p)
	}
	for _, src := range cfg.Discovery.Sources {
		switch strings.ToLower(src) {
		case "app":
			add(&roots, filepath.Join(d.appDir, "models"))
		case "huggingface", "hf":
			for _, p := range huggingFaceCacheRoots() {
				add(&roots, p)
			}
		case "lmstudio":
			if home, err := os.UserHomeDir(); err == nil {
				add(&roots, filepath.Join(home, ".lmstudio", "models"))
			}
		case "llamacpp", "llama.cpp":
			for _, p := range llamaCppCacheRoots() {
				add(&roots, p)
			}
		}
	}
	return roots
}

func (d *DiscoveryService) Scan(cfg AppConfig) ([]DiscoveredModel, error) {
	roots := d.KnownRoots(cfg)
	seenReal := map[string]bool{}
	var models []DiscoveredModel
	for _, root := range roots {
		info, err := os.Stat(root)
		if err != nil || !info.IsDir() {
			continue
		}
		provider := providerForRoot(root, d.appDir)
		found, err := scanRootForGGUF(root, provider, modelLocationMac)
		if err != nil {
			continue
		}
		for _, model := range found {
			real := model.ModelPath
			if resolved, err := filepath.EvalSymlinks(model.ModelPath); err == nil {
				real = resolved
			}
			if seenReal[real] {
				continue
			}
			seenReal[real] = true
			models = append(models, model)
		}
	}
	models = append(models, d.scanVMModels()...)
	sort.Slice(models, func(i, j int) bool {
		if models[i].Provider == models[j].Provider {
			return strings.ToLower(models[i].Name) < strings.ToLower(models[j].Name)
		}
		return models[i].Provider < models[j].Provider
	})
	return models, nil
}

func (d *DiscoveryService) scanVMModels() []DiscoveredModel {
	if d.runtime == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	models, err := d.runtime.BridgeModelsIfRunning(ctx)
	if err != nil {
		return nil
	}
	for i := range models {
		models[i].Location = modelLocationVM
	}
	return models
}

func (d *DiscoveryService) MergeNew(store *ConfigStore) ([]string, error) {
	cfg := store.Get()
	models, err := d.Scan(cfg)
	if err != nil {
		return nil, err
	}
	added := []string{}
	err = store.Update(func(next *AppConfig) error {
		if next.Models == nil {
			next.Models = map[string]ModelConfig{}
		}
		existingByPath := map[string]string{}
		for id, m := range next.Models {
			existingByPath[modelComparableKey(m.Location, m.ModelPath)] = id
		}
		for _, dm := range models {
			location := normalizeModelLocation(dm.Location, dm.ModelPath)
			if existingID, ok := existingByPath[modelComparableKey(location, dm.ModelPath)]; ok {
				existing := next.Models[existingID]
				existing.Location = normalizeModelLocation(existing.Location, existing.ModelPath)
				existing.Available, existing.MissingReason = modelAvailability(existing)
				if existing.Metadata == nil {
					existing.Metadata = map[string]string{}
				}
				for key, value := range dm.Metadata {
					if strings.TrimSpace(value) != "" {
						existing.Metadata[key] = value
					}
				}
				next.Models[existingID] = existing
				continue
			}
			id := ensureUniqueModelID(dm.ID, next.Models)
			metadata := map[string]string{
				"format": strings.ToUpper(firstNonEmpty(dm.Format, "gguf")),
			}
			for key, value := range dm.Metadata {
				if strings.TrimSpace(value) != "" {
					metadata[key] = value
				}
			}
			next.Models[id] = ModelConfig{
				ID:           id,
				Name:         dm.Name,
				Provider:     dm.Provider,
				Source:       dm.Source,
				Location:     location,
				ModelPath:    dm.ModelPath,
				MmprojPath:   dm.MmprojPath,
				SizeBytes:    dm.SizeBytes,
				Available:    true,
				DiscoveredAt: nowRFC3339(),
				Metadata:     metadata,
			}
			added = append(added, id)
			existingByPath[modelComparableKey(location, dm.ModelPath)] = id
		}
		next.Discovery.LastScan = nowRFC3339()
		return nil
	})
	return added, err
}

func scanRootForGGUF(root, provider, location string) ([]DiscoveredModel, error) {
	mmprojByDir := map[string][]string{}
	modelPaths := []string{}
	err := filepath.WalkDir(root, func(path string, de os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if de.IsDir() {
			base := strings.ToLower(de.Name())
			if base == ".git" || base == "node_modules" || base == ".cache" {
				return filepath.SkipDir
			}
			return nil
		}
		name := strings.ToLower(de.Name())
		if !strings.HasSuffix(name, ".gguf") && !strings.HasSuffix(name, ".mmproj") {
			return nil
		}
		if isMmprojName(name) {
			mmprojByDir[filepath.Dir(path)] = append(mmprojByDir[filepath.Dir(path)], path)
			return nil
		}
		if split := parseGGUFSplitFile(path); split.Count > 1 && split.Index > 1 {
			return nil
		}
		if strings.HasSuffix(name, ".gguf") && looksLikeGGUF(path) {
			modelPaths = append(modelPaths, path)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	for dir := range mmprojByDir {
		sort.Strings(mmprojByDir[dir])
	}
	out := make([]DiscoveredModel, 0, len(modelPaths))
	for _, path := range modelPaths {
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		source := sourceForPath(path, provider)
		name := displayNameForPath(path, provider)
		id := deriveModelID(provider, source, filepath.Base(path))
		metadata := readGGUFMetadata(path)
		if metadata == nil {
			metadata = map[string]string{}
		}
		if reason := unsupportedLlamaServerArchitecture(metadata); reason != "" {
			continue
		}
		if split := parseGGUFSplitFile(path); split.Count > 1 {
			metadata["split.count"] = fmt.Sprintf("%d", split.Count)
			metadata["split.primary"] = "true"
			name = filepath.Base(split.Prefix)
			id = deriveModelID(provider, source, filepath.Base(split.Prefix)+".gguf")
		}
		if task := inferModelTask(id, name, source, path); task != "" {
			metadata["task"] = task
		} else if task := taskFromMetadata(metadata, name); task != "" {
			metadata["task"] = task
		}
		out = append(out, DiscoveredModel{
			ID:         id,
			Name:       name,
			Provider:   provider,
			Source:     source,
			Location:   normalizeModelLocation(location, path),
			Format:     "GGUF",
			ModelPath:  path,
			MmprojPath: pickMmproj(path, mmprojByDir),
			SizeBytes:  info.Size(),
			Metadata:   metadata,
		})
	}
	return out, nil
}

func parseGGUFSplitFile(path string) ggufSplitFile {
	base := filepath.Base(path)
	m := ggufSplitFileRE.FindStringSubmatch(base)
	if m == nil {
		return ggufSplitFile{}
	}
	index, _ := strconv.Atoi(m[2])
	count, _ := strconv.Atoi(m[3])
	if index <= 0 || count <= 1 || index > count {
		return ggufSplitFile{}
	}
	return ggufSplitFile{
		Prefix: filepath.Join(filepath.Dir(path), m[1]),
		Index:  index,
		Count:  count,
	}
}

func inferModelTask(parts ...string) string {
	haystack := strings.ToLower(strings.Join(parts, " "))
	if strings.Contains(haystack, "rerank") || strings.Contains(haystack, "reranker") {
		return "rerank"
	}
	if strings.Contains(haystack, "embed") || strings.Contains(haystack, "e5") || strings.Contains(haystack, "gte") {
		return "embedding"
	}
	return ""
}

func taskFromMetadata(metadata map[string]string, name string) string {
	arch := strings.ToLower(strings.TrimSpace(metadata["general.architecture"]))
	generalType := strings.ToLower(strings.TrimSpace(metadata["general.type"]))
	haystack := strings.ToLower(strings.Join([]string{
		name,
		metadata["general.name"],
		metadata["general.basename"],
		metadata["general.description"],
		arch,
		generalType,
	}, " "))
	switch {
	case strings.Contains(haystack, "rerank"):
		return "rerank"
	case strings.Contains(haystack, "embed") || strings.Contains(arch, "bert"):
		return "embedding"
	default:
		return ""
	}
}

func pickMmproj(modelPath string, byDir map[string][]string) string {
	modelDir := filepath.Dir(modelPath)
	modelBase := strings.TrimSuffix(strings.ToLower(filepath.Base(modelPath)), filepath.Ext(modelPath))
	candidates := append([]string{}, byDir[modelDir]...)
	parent := filepath.Dir(modelDir)
	candidates = append(candidates, byDir[parent]...)
	if len(candidates) == 0 {
		return ""
	}
	score := func(path string) int {
		base := strings.TrimSuffix(strings.ToLower(filepath.Base(path)), filepath.Ext(path))
		switch {
		case base == "mmproj-"+modelBase || base == modelBase:
			return 0
		case strings.Contains(base, modelBase) || strings.Contains(modelBase, strings.TrimPrefix(base, "mmproj-")):
			return 1
		case strings.HasPrefix(base, "mmproj"):
			return 2
		default:
			return 9
		}
	}
	sort.SliceStable(candidates, func(i, j int) bool {
		si, sj := score(candidates[i]), score(candidates[j])
		if si == sj {
			return len(candidates[i]) < len(candidates[j])
		}
		return si < sj
	})
	if score(candidates[0]) >= 9 {
		return ""
	}
	return candidates[0]
}

func isMmprojName(name string) bool {
	return strings.Contains(name, "mmproj") || strings.HasSuffix(name, ".mmproj")
}

func looksLikeGGUF(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	header := make([]byte, 4)
	if _, err := io.ReadFull(f, header); err != nil {
		return false
	}
	return string(header) == "GGUF"
}

func readGGUFMetadata(path string) map[string]string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	var magic [4]byte
	if _, err := io.ReadFull(f, magic[:]); err != nil || string(magic[:]) != "GGUF" {
		return nil
	}
	var version uint32
	var tensorCount uint64
	var metadataCount uint64
	if binary.Read(f, binary.LittleEndian, &version) != nil ||
		binary.Read(f, binary.LittleEndian, &tensorCount) != nil ||
		binary.Read(f, binary.LittleEndian, &metadataCount) != nil {
		return nil
	}
	out := map[string]string{}
	for i := uint64(0); i < metadataCount; i++ {
		key, err := readGGUFString(f)
		if err != nil {
			break
		}
		var valueType uint32
		if err := binary.Read(f, binary.LittleEndian, &valueType); err != nil {
			break
		}
		value, ok := readGGUFScalarValue(f, valueType)
		if ok && shouldKeepGGUFMetadataKey(key) {
			out[key] = value
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func shouldKeepGGUFMetadataKey(key string) bool {
	key = strings.ToLower(key)
	return key == "general.architecture" ||
		key == "general.type" ||
		key == "general.name" ||
		key == "general.basename" ||
		key == "general.finetune" ||
		key == "general.description" ||
		strings.HasSuffix(key, ".context_length") ||
		strings.HasSuffix(key, ".block_count") ||
		strings.HasSuffix(key, ".embedding_length") ||
		strings.HasSuffix(key, ".feed_forward_length")
}

func readGGUFString(r io.Reader) (string, error) {
	var n uint64
	if err := binary.Read(r, binary.LittleEndian, &n); err != nil {
		return "", err
	}
	if n > 1<<20 {
		return "", fmt.Errorf("gguf string too large")
	}
	buf := make([]byte, n)
	_, err := io.ReadFull(r, buf)
	return string(buf), err
}

func readGGUFScalarValue(r io.Reader, valueType uint32) (string, bool) {
	switch valueType {
	case 0:
		var v uint8
		if binary.Read(r, binary.LittleEndian, &v) != nil {
			return "", false
		}
		return fmt.Sprintf("%d", v), true
	case 1:
		var v int8
		if binary.Read(r, binary.LittleEndian, &v) != nil {
			return "", false
		}
		return fmt.Sprintf("%d", v), true
	case 2:
		var v uint16
		if binary.Read(r, binary.LittleEndian, &v) != nil {
			return "", false
		}
		return fmt.Sprintf("%d", v), true
	case 3:
		var v int16
		if binary.Read(r, binary.LittleEndian, &v) != nil {
			return "", false
		}
		return fmt.Sprintf("%d", v), true
	case 4:
		var v uint32
		if binary.Read(r, binary.LittleEndian, &v) != nil {
			return "", false
		}
		return fmt.Sprintf("%d", v), true
	case 5:
		var v int32
		if binary.Read(r, binary.LittleEndian, &v) != nil {
			return "", false
		}
		return fmt.Sprintf("%d", v), true
	case 6:
		var v float32
		if binary.Read(r, binary.LittleEndian, &v) != nil {
			return "", false
		}
		return fmt.Sprintf("%g", v), true
	case 7:
		var v uint8
		if binary.Read(r, binary.LittleEndian, &v) != nil {
			return "", false
		}
		return fmt.Sprintf("%t", v != 0), true
	case 8:
		v, err := readGGUFString(r)
		return v, err == nil
	case 9:
		if err := skipGGUFArray(r); err != nil {
			return "", false
		}
		return "", false
	case 10:
		var v uint64
		if binary.Read(r, binary.LittleEndian, &v) != nil {
			return "", false
		}
		return fmt.Sprintf("%d", v), true
	case 11:
		var v int64
		if binary.Read(r, binary.LittleEndian, &v) != nil {
			return "", false
		}
		return fmt.Sprintf("%d", v), true
	case 12:
		var v float64
		if binary.Read(r, binary.LittleEndian, &v) != nil {
			return "", false
		}
		return fmt.Sprintf("%g", v), true
	default:
		return "", false
	}
}

func skipGGUFArray(r io.Reader) error {
	var elemType uint32
	var count uint64
	if err := binary.Read(r, binary.LittleEndian, &elemType); err != nil {
		return err
	}
	if err := binary.Read(r, binary.LittleEndian, &count); err != nil {
		return err
	}
	if elemType == 8 && count > 10000 {
		return fmt.Errorf("skipping large gguf string array")
	}
	for i := uint64(0); i < count; i++ {
		if _, ok := readGGUFScalarValue(r, elemType); !ok {
			switch elemType {
			case 9:
				continue
			default:
				return fmt.Errorf("unsupported gguf array type %d", elemType)
			}
		}
	}
	return nil
}

func providerForRoot(root, appDir string) string {
	low := strings.ToLower(filepath.ToSlash(root))
	switch {
	case strings.Contains(low, "huggingface") || strings.Contains(low, "models--"):
		return "huggingface"
	case strings.Contains(low, ".lmstudio"):
		return "lmstudio"
	case strings.Contains(low, "llama.cpp"):
		return "llamacpp"
	case strings.HasPrefix(filepath.Clean(root), filepath.Clean(appDir)):
		return "app"
	default:
		return "folder"
	}
}

func sourceForPath(path, provider string) string {
	slash := filepath.ToSlash(path)
	if provider == "huggingface" {
		parts := strings.Split(slash, "/")
		for _, part := range parts {
			if strings.HasPrefix(part, "models--") {
				return strings.ReplaceAll(strings.TrimPrefix(part, "models--"), "--", "/")
			}
		}
	}
	if provider == "lmstudio" {
		return trimAfterMarker(slash, ".lmstudio/models/")
	}
	return filepath.Dir(path)
}

func trimAfterMarker(path, marker string) string {
	idx := strings.Index(path, marker)
	if idx < 0 {
		return filepath.Dir(path)
	}
	rest := strings.TrimPrefix(path[idx+len(marker):], "/")
	parts := strings.Split(rest, "/")
	if len(parts) >= 2 {
		return parts[0] + "/" + parts[1]
	}
	return rest
}

func displayNameForPath(path, provider string) string {
	if provider == "huggingface" {
		if src := sourceForPath(path, provider); strings.Contains(src, "/") {
			return src + ":" + strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
		}
	}
	return strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
}

func deriveModelID(provider, source, fileName string) string {
	base := strings.TrimSuffix(fileName, filepath.Ext(fileName))
	raw := provider + "-" + source + "-" + base
	return sanitizeID(raw)
}

func sanitizeID(raw string) string {
	raw = strings.ToLower(strings.TrimSpace(raw))
	var b strings.Builder
	lastDash := false
	for _, r := range raw {
		ok := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')
		if ok {
			b.WriteRune(r)
			lastDash = false
			continue
		}
		if !lastDash {
			b.WriteByte('-')
			lastDash = true
		}
	}
	id := strings.Trim(b.String(), "-")
	if id == "" {
		sum := sha1.Sum([]byte(raw))
		id = "model-" + hex.EncodeToString(sum[:])[:10]
	}
	if len(id) > 140 {
		sum := sha1.Sum([]byte(id))
		id = id[:100] + "-" + hex.EncodeToString(sum[:])[:10]
	}
	return id
}

func ensureUniqueModelID(base string, models map[string]ModelConfig) string {
	id := sanitizeID(base)
	if _, exists := models[id]; !exists {
		return id
	}
	for i := 2; ; i++ {
		candidate := fmt.Sprintf("%s-%d", id, i)
		if _, exists := models[candidate]; !exists {
			return candidate
		}
	}
}

func cleanComparablePath(path string) string {
	path = filepath.Clean(path)
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved
	}
	return path
}

func modelComparableKey(location, path string) string {
	return normalizeModelLocation(location, path) + "\x00" + cleanComparablePath(path)
}

func huggingFaceCacheRoots() []string {
	var roots []string
	if v := strings.TrimSpace(os.Getenv("HUGGINGFACE_HUB_CACHE")); v != "" {
		roots = append(roots, v)
	}
	if v := strings.TrimSpace(os.Getenv("HF_HOME")); v != "" {
		roots = append(roots, filepath.Join(v, "hub"))
	}
	if home, err := os.UserHomeDir(); err == nil {
		roots = append(roots, filepath.Join(home, ".cache", "huggingface", "hub"))
		if runtime.GOOS == "darwin" {
			roots = append(roots, filepath.Join(home, "Library", "Caches", "huggingface", "hub"))
		}
	}
	return roots
}

func llamaCppCacheRoots() []string {
	var roots []string
	if v := strings.TrimSpace(os.Getenv("LLAMA_CACHE")); v != "" {
		roots = append(roots, v)
	}
	if home, err := os.UserHomeDir(); err == nil {
		roots = append(roots, filepath.Join(home, ".cache", "llama.cpp"))
		if runtime.GOOS == "darwin" {
			roots = append(roots, filepath.Join(home, "Library", "Caches", "llama.cpp"))
		}
	}
	return roots
}

func expandPath(path string) string {
	if path == "~" {
		if home, err := os.UserHomeDir(); err == nil {
			return home
		}
	}
	if strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, path[2:])
		}
	}
	return os.ExpandEnv(path)
}

func fileContainsLine(path, contains string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if strings.Contains(sc.Text(), contains) {
			return true
		}
	}
	return false
}
