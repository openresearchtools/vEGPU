package main

import (
	"bytes"
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

//go:embed static/llama/* static/core/*
var embeddedFiles embed.FS

type App struct {
	appDir       string
	store        *ConfigStore
	discovery    *DiscoveryService
	runtime      *RuntimeService
	runtimes     *RuntimeManager
	processes    *ProcessManager
	hf           *HFService
	copies       *ModelCopyService
	llamaFS      fs.FS
	llamaHandler http.Handler
}

var generationPresetKeys = map[string]struct{}{
	"temperature":        {},
	"max_tokens":         {},
	"dynatemp_range":     {},
	"dynatemp_exponent":  {},
	"top_k":              {},
	"top_p":              {},
	"min_p":              {},
	"xtc_probability":    {},
	"xtc_threshold":      {},
	"typ_p":              {},
	"repeat_last_n":      {},
	"repeat_penalty":     {},
	"presence_penalty":   {},
	"frequency_penalty":  {},
	"dry_multiplier":     {},
	"dry_base":           {},
	"dry_allowed_length": {},
	"dry_penalty_last_n": {},
	"samplers":           {},
	"backend_sampling":   {},
	"custom":             {},
}

func main() {
	_ = mime.AddExtensionType(".js", "text/javascript; charset=utf-8")
	_ = mime.AddExtensionType(".css", "text/css; charset=utf-8")

	appDir := resolveAppDir()
	configPath := strings.TrimSpace(os.Getenv("WEB_UI_APP_CONFIG"))
	store, err := NewConfigStore(appDir, configPath)
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	runtimeSvc := NewRuntimeService(appDir, store)
	discovery := NewDiscoveryService(appDir, runtimeSvc)
	runtimeManager := NewRuntimeManager(appDir, store, runtimeSvc)
	processes := NewProcessManager(store, runtimeSvc, appDir)
	hfSvc := NewHFService(appDir, store, discovery, runtimeSvc)
	copySvc := NewModelCopyService(store, discovery, runtimeSvc)
	go func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := runtimeSvc.StopBridgeServers(cleanupCtx); err != nil {
			log.Printf("startup VM LLMS child cleanup skipped: %v", err)
		}
	}()

	llamaStatic, err := fs.Sub(embeddedFiles, "static/llama")
	if err != nil {
		log.Fatalf("static llama ui: %v", err)
	}
	app := &App{
		appDir:       appDir,
		store:        store,
		discovery:    discovery,
		runtime:      runtimeSvc,
		runtimes:     runtimeManager,
		processes:    processes,
		hf:           hfSvc,
		copies:       copySvc,
		llamaFS:      llamaStatic,
		llamaHandler: http.FileServer(http.FS(llamaStatic)),
	}

	if store.Get().Discovery.Enabled {
		go func() {
			if added, err := discovery.MergeNew(store); err != nil {
				log.Printf("startup discovery failed: %v", err)
			} else if len(added) > 0 {
				log.Printf("startup discovery registered %d model(s)", len(added))
			}
		}()
	}

	mux := http.NewServeMux()
	app.registerRoutes(mux)

	cfg := store.Get()
	if err := validateBindSafety(cfg); err != nil {
		log.Fatalf("%v", err)
	}
	addr := net.JoinHostPort(cfg.Server.Host, strconv.Itoa(cfg.Server.Port))
	server := &http.Server{
		Addr:              addr,
		Handler:           logMiddleware(mux),
		ReadHeaderTimeout: 10 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		processes.StopAll(false)
		_ = server.Shutdown(shutdownCtx)
	}()

	log.Printf("web-ui-app listening on http://%s", addr)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("server: %v", err)
	}
}

func resolveAppDir() string {
	if v := strings.TrimSpace(os.Getenv("WEB_UI_APP_DIR")); v != "" {
		if abs, err := filepath.Abs(expandPath(v)); err == nil {
			return abs
		}
		return expandPath(v)
	}
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		slash := filepath.ToSlash(dir)
		if !strings.Contains(slash, "/go-build") && !strings.Contains(slash, "/Temp/") {
			return dir
		}
	}
	if cwd, err := os.Getwd(); err == nil {
		return cwd
	}
	return "."
}

func validateBindSafety(cfg AppConfig) error {
	if len(cfg.Server.APIKeys) > 0 || cfg.Server.AllowInsecureRemote {
		return nil
	}
	host := strings.TrimSpace(cfg.Server.Host)
	if host == "" || host == "localhost" {
		return nil
	}
	ip := net.ParseIP(host)
	if ip == nil {
		ips, err := net.LookupIP(host)
		if err != nil {
			return nil
		}
		for _, candidate := range ips {
			if candidate.IsLoopback() {
				return nil
			}
		}
		return fmt.Errorf("refusing to bind %s without server.apiKeys or server.allowInsecureRemote", host)
	}
	if ip.IsLoopback() {
		return nil
	}
	return fmt.Errorf("refusing to bind %s without server.apiKeys or server.allowInsecureRemote", host)
}

func (a *App) registerRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/health", a.handleHealth)

	mux.HandleFunc("/api/config", a.handleConfig)
	mux.HandleFunc("/api/models/refresh", a.handleModelsRefresh)
	mux.HandleFunc("/api/model-copies", a.handleModelCopies)
	mux.HandleFunc("/api/models/", a.handleModelByID)
	mux.HandleFunc("/api/runtime/status", a.handleRuntimeStatus)
	mux.HandleFunc("/api/runtime/download", a.handleRuntimeDownload)
	mux.HandleFunc("/api/runtime/flags", a.handleRuntimeFlags)
	mux.HandleFunc("/api/runtimes", a.handleRuntimes)
	mux.HandleFunc("/api/runtimes/releases", a.handleRuntimeReleases)
	mux.HandleFunc("/api/runtimes/fetch-install", a.handleRuntimeFetchInstall)
	mux.HandleFunc("/api/runtimes/pair/activate", a.handleRuntimePairActivate)
	mux.HandleFunc("/api/runtimes/pair/delete", a.handleRuntimePairDelete)
	mux.HandleFunc("/api/runtimes/install", a.handleRuntimeInstall)
	mux.HandleFunc("/api/runtimes/activate", a.handleRuntimeActivate)
	mux.HandleFunc("/api/runtimes/delete", a.handleRuntimeDelete)
	mux.HandleFunc("/api/devices", a.handleDevices)
	mux.HandleFunc("/api/rpc", a.handleRPCServers)
	mux.HandleFunc("/api/hf/tree", a.handleHFTree)
	mux.HandleFunc("/api/hf/download", a.handleHFDownload)
	mux.HandleFunc("/api/hf/downloads", a.handleHFDownloads)

	mux.HandleFunc("/core", a.serveCoreUI)
	mux.HandleFunc("/core/", a.serveCoreUI)

	mux.HandleFunc("/v1/models", a.handleV1Models)
	mux.HandleFunc("/v1/", a.handleProxyByBodyOrActive)
	mux.HandleFunc("/models/load", a.handleModelsLoad)
	mux.HandleFunc("/models/unload", a.handleModelsUnload)
	mux.HandleFunc("/models", a.handleModels)
	mux.HandleFunc("/props", a.handleProps)
	mux.HandleFunc("/slots", a.handleSlots)
	mux.HandleFunc("/tools", a.handleTools)

	for _, route := range []string{"/completion", "/completions", "/infill", "/embedding", "/embeddings", "/rerank", "/reranking", "/tokenize", "/detokenize", "/apply-template"} {
		mux.HandleFunc(route, a.handleProxyByBodyOrActive)
	}

	mux.HandleFunc("/", a.serveLlamaUI)
}

func (a *App) handleHealth(w http.ResponseWriter, r *http.Request) {
	respondJSON(w, http.StatusOK, map[string]any{"status": "ok"})
}

func (a *App) serveCoreUI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-cache")
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.NotFound(w, r)
		return
	}
	clean := path.Clean(r.URL.Path)
	if clean == "/core" || clean == "/core/" || clean == "." {
		http.ServeFileFS(w, r, embeddedFiles, "static/core/index.html")
		return
	}
	name := strings.TrimPrefix(clean, "/core/")
	if name == "" || strings.Contains(name, "..") {
		http.NotFound(w, r)
		return
	}
	if _, err := fs.Stat(embeddedFiles, "static/core/"+name); err == nil {
		http.ServeFileFS(w, r, embeddedFiles, "static/core/"+name)
		return
	}
	http.NotFound(w, r)
}

func (a *App) serveLlamaUI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-cache")
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.NotFound(w, r)
		return
	}
	clean := path.Clean(r.URL.Path)
	if clean == "/admin" || strings.HasPrefix(clean, "/admin/") {
		http.NotFound(w, r)
		return
	}
	if clean == "/" || clean == "." {
		http.ServeFileFS(w, r, embeddedFiles, "static/llama/index.html")
		return
	}
	name := strings.TrimPrefix(clean, "/")
	if _, err := fs.Stat(a.llamaFS, name); err == nil {
		a.llamaHandler.ServeHTTP(w, r)
		return
	}
	http.ServeFileFS(w, r, embeddedFiles, "static/llama/index.html")
}

func (a *App) handleConfig(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	switch r.Method {
	case http.MethodGet:
		cfg := a.store.Get()
		respondJSON(w, http.StatusOK, map[string]any{
			"appDir":     a.appDir,
			"configPath": a.store.Path(),
			"config":     cfg,
			"models":     a.sortedModelsForClient(r.Context(), cfg),
		})
	case http.MethodPatch:
		var envelope struct {
			Config *AppConfig `json:"config"`
		}
		raw, err := io.ReadAll(r.Body)
		if err != nil {
			respondError(w, http.StatusBadRequest, err)
			return
		}
		var incoming AppConfig
		if err := json.Unmarshal(raw, &envelope); err == nil && envelope.Config != nil {
			incoming = *envelope.Config
		} else if err := json.Unmarshal(raw, &incoming); err != nil {
			respondError(w, http.StatusBadRequest, err)
			return
		}
		if err := a.store.Update(func(next *AppConfig) error {
			if incoming.Models == nil {
				incoming.Models = next.Models
			}
			*next = incoming
			return nil
		}); err != nil {
			respondError(w, http.StatusInternalServerError, err)
			return
		}
		respondJSON(w, http.StatusOK, map[string]any{"config": a.store.Get()})
	default:
		methodNotAllowed(w)
	}
}

func (a *App) handleModelsRefresh(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	added, err := a.discovery.MergeNew(a.store)
	if err != nil {
		respondError(w, http.StatusInternalServerError, err)
		return
	}
	cfg := a.store.Get()
	respondJSON(w, http.StatusOK, map[string]any{
		"added":  added,
		"models": a.sortedModelsForClient(r.Context(), cfg),
	})
}

func (a *App) sortedModelsForClient(ctx context.Context, cfg AppConfig) []ModelConfig {
	models := sortedModels(cfg)
	hasVM := false
	for _, model := range models {
		if isVMModelLocation(model.Location) {
			hasVM = true
			break
		}
	}
	if !hasVM || a.runtime == nil {
		return models
	}
	probeCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	vmModels, err := a.runtime.BridgeModelsIfRunning(probeCtx)
	if err != nil || len(vmModels) == 0 {
		return filterModelsByLocation(models, modelLocationMac)
	}
	live := map[string]DiscoveredModel{}
	for _, model := range vmModels {
		live[modelComparableKey(modelLocationVM, model.ModelPath)] = model
	}
	out := make([]ModelConfig, 0, len(models))
	for _, model := range models {
		if !isVMModelLocation(model.Location) {
			out = append(out, model)
			continue
		}
		if discovered, ok := live[modelComparableKey(modelLocationVM, model.ModelPath)]; ok {
			out = append(out, mergeLiveModelMetadata(model, discovered))
		}
	}
	return out
}

func mergeLiveModelMetadata(model ModelConfig, discovered DiscoveredModel) ModelConfig {
	model.Available = true
	model.MissingReason = ""
	if discovered.Name != "" && model.Name == "" {
		model.Name = discovered.Name
	}
	if discovered.Provider != "" {
		model.Provider = discovered.Provider
	}
	if discovered.Source != "" {
		model.Source = discovered.Source
	}
	if discovered.MmprojPath != "" {
		model.MmprojPath = discovered.MmprojPath
	}
	if discovered.SizeBytes > 0 {
		model.SizeBytes = discovered.SizeBytes
	}
	if model.Metadata == nil {
		model.Metadata = map[string]string{}
	}
	if discovered.Format != "" {
		model.Metadata["format"] = strings.ToUpper(discovered.Format)
	}
	for key, value := range discovered.Metadata {
		if strings.TrimSpace(value) != "" {
			model.Metadata[key] = value
		}
	}
	return model
}

func filterModelsByLocation(models []ModelConfig, location string) []ModelConfig {
	out := make([]ModelConfig, 0, len(models))
	for _, model := range models {
		if normalizeModelLocation(model.Location, model.ModelPath) == location {
			out = append(out, model)
		}
	}
	return out
}

func (a *App) handleModelByID(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	rest := strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/models/"), "/")
	parts := strings.Split(rest, "/")
	id, err := url.PathUnescape(parts[0])
	if err != nil || id == "" {
		respondError(w, http.StatusBadRequest, fmt.Errorf("model id is required"))
		return
	}
	if len(parts) > 1 {
		if len(parts) == 2 && parts[1] == "generation" {
			a.handleModelGeneration(w, r, id)
			return
		}
		if len(parts) == 2 && parts[1] == "copy" {
			a.handleModelCopy(w, r, id)
			return
		}
		respondError(w, http.StatusNotFound, fmt.Errorf("unknown model endpoint"))
		return
	}
	switch r.Method {
	case http.MethodGet:
		cfg := a.store.Get()
		model, ok := cfg.Models[id]
		if !ok {
			respondError(w, http.StatusNotFound, fmt.Errorf("model %s not found", id))
			return
		}
		respondJSON(w, http.StatusOK, model)
	case http.MethodPatch:
		var incoming ModelConfig
		if err := json.NewDecoder(r.Body).Decode(&incoming); err != nil {
			respondError(w, http.StatusBadRequest, err)
			return
		}
		if err := a.store.Update(func(next *AppConfig) error {
			current, ok := next.Models[id]
			if !ok {
				return fmt.Errorf("model %s not found", id)
			}
			incoming.ID = id
			if incoming.ModelPath == "" {
				incoming.ModelPath = current.ModelPath
			}
			if incoming.Name == "" {
				incoming.Name = current.Name
			}
			if incoming.Provider == "" {
				incoming.Provider = current.Provider
			}
			if incoming.Source == "" {
				incoming.Source = current.Source
			}
			if incoming.Location == "" {
				incoming.Location = current.Location
			}
			if incoming.DiscoveredAt == "" {
				incoming.DiscoveredAt = current.DiscoveredAt
			}
			if incoming.Metadata == nil {
				incoming.Metadata = current.Metadata
			}
			incoming.Location = normalizeModelLocation(incoming.Location, incoming.ModelPath)
			incoming.Available, incoming.MissingReason = modelAvailability(incoming)
			next.Models[id] = incoming
			return nil
		}); err != nil {
			respondError(w, http.StatusBadRequest, err)
			return
		}
		_ = a.processes.StopModel(id, false)
		respondJSON(w, http.StatusOK, a.store.Get().Models[id])
	case http.MethodDelete:
		cfg := a.store.Get()
		model, ok := cfg.Models[id]
		if !ok {
			respondError(w, http.StatusNotFound, fmt.Errorf("model %s not found", id))
			return
		}
		_ = a.processes.StopModel(id, true)
		result := DeleteResult{ModelID: id, ConfigOnly: r.URL.Query().Get("files") == "false"}
		if !result.ConfigOnly {
			result = DeleteModelFiles(a.appDir, cfg, model)
		}
		if err := a.store.Update(func(next *AppConfig) error {
			delete(next.Models, id)
			return nil
		}); err != nil {
			respondError(w, http.StatusInternalServerError, err)
			return
		}
		respondJSON(w, http.StatusOK, result)
	default:
		methodNotAllowed(w)
	}
}

func (a *App) handleModelCopy(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	task, err := a.copies.StartCopy(id)
	if err != nil {
		status := http.StatusBadRequest
		if strings.Contains(err.Error(), "not found") {
			status = http.StatusNotFound
		}
		respondError(w, status, err)
		return
	}
	respondJSON(w, http.StatusAccepted, task)
}

func (a *App) handleModelCopies(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	respondJSON(w, http.StatusOK, map[string]any{"copies": a.copies.Tasks()})
}

func modelCopyRoots(model ModelConfig) (string, string, error) {
	provider := strings.ToLower(strings.TrimSpace(model.Provider))
	location := normalizeModelLocation(model.Location, model.ModelPath)
	switch provider {
	case "huggingface":
		macRoot := hfPrimaryCacheRoot()
		if location == modelLocationMac {
			root, ok := containingRoot(model.ModelPath, huggingFaceCacheRoots())
			if !ok {
				return "", "", fmt.Errorf("Mac Hugging Face model is outside known Hugging Face cache roots")
			}
			macRoot = root
		}
		return macRoot, "/home/vegpu/.cache/huggingface/hub", nil
	case "lmstudio":
		macRoot := macLMStudioRoot()
		if location == modelLocationMac {
			root, ok := containingRoot(model.ModelPath, []string{macRoot})
			if !ok {
				return "", "", fmt.Errorf("Mac LM Studio model is outside the LM Studio models folder")
			}
			macRoot = root
		}
		return macRoot, "/home/vegpu/.lmstudio/models", nil
	default:
		return "", "", fmt.Errorf("copy is only supported for Hugging Face and LM Studio models")
	}
}

func containingRoot(path string, roots []string) (string, bool) {
	clean := filepath.Clean(expandPath(path))
	for _, root := range roots {
		root = filepath.Clean(expandPath(root))
		rel, err := filepath.Rel(root, clean)
		if err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return root, true
		}
	}
	return "", false
}

func macLMStudioRoot() string {
	if home, err := os.UserHomeDir(); err == nil {
		return filepath.Join(home, ".lmstudio", "models")
	}
	return filepath.Join(".", ".lmstudio", "models")
}

func (a *App) handleModelGeneration(w http.ResponseWriter, r *http.Request, id string) {
	switch r.Method {
	case http.MethodGet:
		cfg := a.store.Get()
		model, ok := cfg.Models[id]
		if !ok {
			respondError(w, http.StatusNotFound, fmt.Errorf("model %s not found", id))
			return
		}
		respondJSON(w, http.StatusOK, map[string]any{
			"model":      id,
			"generation": generationMapOrEmpty(model.Generation),
		})
	case http.MethodPatch:
		var incoming map[string]any
		if err := json.NewDecoder(r.Body).Decode(&incoming); err != nil {
			respondError(w, http.StatusBadRequest, err)
			return
		}
		if nested, ok := incoming["generation"]; ok {
			nestedMap, ok := nested.(map[string]any)
			if !ok {
				respondError(w, http.StatusBadRequest, fmt.Errorf("generation must be an object"))
				return
			}
			incoming = nestedMap
		}
		preset, err := sanitizeGenerationPreset(incoming)
		if err != nil {
			respondError(w, http.StatusBadRequest, err)
			return
		}
		if err := a.store.Update(func(next *AppConfig) error {
			current, ok := next.Models[id]
			if !ok {
				return fmt.Errorf("model %s not found", id)
			}
			if current.Generation == nil {
				current.Generation = map[string]any{}
			}
			for key, value := range preset {
				if isClearedGenerationValue(value) {
					delete(current.Generation, key)
				} else {
					current.Generation[key] = value
				}
			}
			next.Models[id] = current
			return nil
		}); err != nil {
			respondError(w, http.StatusBadRequest, err)
			return
		}
		model := a.store.Get().Models[id]
		respondJSON(w, http.StatusOK, map[string]any{
			"model":      id,
			"generation": generationMapOrEmpty(model.Generation),
		})
	default:
		methodNotAllowed(w)
	}
}

func (a *App) handleRuntimeStatus(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	status := a.runtime.Status(r.Context())
	respondJSON(w, http.StatusOK, status)
}

func (a *App) handleRuntimeDownload(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	status := a.runtime.Status(r.Context())
	respondJSON(w, http.StatusGone, map[string]any{
		"status": status,
		"error":  "runtime downloads moved to /api/runtimes/fetch-install with matched macOS and Linux releases",
	})
}

func (a *App) handleRuntimes(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	payload, err := a.runtimes.List(r.Context())
	if err != nil {
		respondError(w, http.StatusInternalServerError, err)
		return
	}
	respondJSON(w, http.StatusOK, payload)
}

func (a *App) handleRuntimeReleases(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	family := r.URL.Query().Get("family")
	if strings.TrimSpace(family) == "" {
		family = "llama"
	}
	releases, err := a.runtimes.ListReleases(r.Context(), family)
	if err != nil {
		respondError(w, http.StatusBadGateway, err)
		return
	}
	respondJSON(w, http.StatusOK, map[string]any{"family": normalizeReleaseFamily(family), "releases": releases})
}

func (a *App) handleRuntimeFetchInstall(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var payload struct {
		Family       string `json:"family"`
		Tag          string `json:"tag"`
		LinuxBackend string `json:"linuxBackend"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	result, err := a.runtimes.FetchInstall(r.Context(), payload.Family, payload.Tag, payload.LinuxBackend)
	if err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	respondJSON(w, http.StatusOK, result)
}

func (a *App) handleRuntimePairActivate(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var payload struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	pair, err := a.runtimes.ActivatePair(r.Context(), payload.ID)
	if err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	list, _ := a.runtimes.List(r.Context())
	respondJSON(w, http.StatusOK, map[string]any{"pair": pair, "runtimes": list})
}

func (a *App) handleRuntimePairDelete(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost && r.Method != http.MethodDelete {
		methodNotAllowed(w)
		return
	}
	var payload struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	if err := a.runtimes.DeletePair(r.Context(), payload.ID); err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	list, _ := a.runtimes.List(r.Context())
	respondJSON(w, http.StatusOK, map[string]any{"ok": true, "runtimes": list})
}

func (a *App) handleRuntimeInstall(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var payload struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	runtime, err := a.runtimes.InstallLinux(r.Context(), payload.ID)
	if err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	list, _ := a.runtimes.List(r.Context())
	respondJSON(w, http.StatusOK, map[string]any{"runtime": runtime, "runtimes": list})
}

func (a *App) handleRuntimeActivate(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var payload struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	runtime, err := a.runtimes.Activate(r.Context(), payload.ID)
	if err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	list, _ := a.runtimes.List(r.Context())
	respondJSON(w, http.StatusOK, map[string]any{"runtime": runtime, "runtimes": list})
}

func (a *App) handleRuntimeDelete(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost && r.Method != http.MethodDelete {
		methodNotAllowed(w)
		return
	}
	var payload struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	if err := a.runtimes.Delete(r.Context(), payload.ID); err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	list, _ := a.runtimes.List(r.Context())
	respondJSON(w, http.StatusOK, map[string]any{"ok": true, "runtimes": list})
}

func (a *App) handleRuntimeFlags(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	respondJSON(w, http.StatusOK, map[string]any{
		"flags":           a.runtime.Flags(r.Context()),
		"turboCacheTypes": []string{"TURBO2_0", "TURBO3_0", "TURBO4_0", "TQ3_1S", "TQ4_1S"},
	})
}

func (a *App) handleDevices(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	devices, err := a.runtime.Devices(r.Context())
	if devices == nil {
		devices = []DeviceInfo{}
	}
	payload := map[string]any{"devices": devices}
	if err != nil {
		payload["error"] = err.Error()
	}
	respondJSON(w, http.StatusOK, payload)
}

func (a *App) handleRPCServers(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	switch r.Method {
	case http.MethodGet:
		respondJSON(w, http.StatusOK, map[string]any{"rpcServers": a.store.Get().RPCServers})
	case http.MethodPut, http.MethodPatch:
		var envelope struct {
			RPCServers []RPCServerConfig `json:"rpcServers"`
		}
		if err := json.NewDecoder(r.Body).Decode(&envelope); err != nil {
			respondError(w, http.StatusBadRequest, err)
			return
		}
		if err := a.store.Update(func(next *AppConfig) error {
			next.RPCServers = normalizeRPCServerConfigs(envelope.RPCServers)
			return nil
		}); err != nil {
			respondError(w, http.StatusInternalServerError, err)
			return
		}
		respondJSON(w, http.StatusOK, map[string]any{"rpcServers": a.store.Get().RPCServers})
	default:
		methodNotAllowed(w)
	}
}

func (a *App) handleHFTree(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	recursive := r.URL.Query().Get("recursive") == "1" || r.URL.Query().Get("recursive") == "true"
	entries, err := a.hf.ListTree(r.Context(), r.URL.Query().Get("repo"), r.URL.Query().Get("revision"), r.URL.Query().Get("path"), recursive)
	if err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	respondJSON(w, http.StatusOK, map[string]any{"entries": entries})
}

func (a *App) handleHFDownload(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var req struct {
		Repo     string   `json:"repo"`
		Revision string   `json:"revision"`
		Paths    []string `json:"paths"`
		Location string   `json:"location"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	if len(req.Paths) == 0 {
		respondError(w, http.StatusBadRequest, fmt.Errorf("at least one path is required"))
		return
	}
	task := a.hf.StartDownload(req.Repo, req.Revision, req.Paths, req.Location)
	respondJSON(w, http.StatusAccepted, task)
}

func (a *App) handleHFDownloads(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	respondJSON(w, http.StatusOK, map[string]any{"downloads": a.hf.Downloads()})
}

func (a *App) handleV1Models(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	cfg := a.store.Get()
	now := time.Now().Unix()
	data := make([]map[string]any, 0, len(cfg.Models))
	for _, model := range sortedModels(cfg) {
		if !model.Available {
			continue
		}
		data = append(data, map[string]any{
			"id":       model.ID,
			"object":   "model",
			"created":  now,
			"owned_by": "model-router",
			"name":     model.Name,
			"path":     model.ModelPath,
			"location": model.Location,
			"meta": map[string]any{
				"provider": model.Provider,
				"source":   model.Source,
				"location": model.Location,
				"mmproj":   model.MmprojPath,
				"format":   model.Metadata["format"],
			},
		})
	}
	respondJSON(w, http.StatusOK, map[string]any{"object": "list", "data": data})
}

func (a *App) handleModels(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if r.URL.Query().Get("reload") != "" {
		_, _ = a.discovery.MergeNew(a.store)
	}
	cfg := a.store.Get()
	statuses := a.processes.Statuses()
	now := time.Now().Unix()
	data := make([]map[string]any, 0, len(cfg.Models))
	for _, model := range sortedModels(cfg) {
		state := statuses[model.ID]
		statusValue := routerStatusValue(state, model.Available)
		status := map[string]any{
			"value": statusValue,
			"args":  []string{},
		}
		if !model.Available {
			status["failed"] = true
			status["error"] = model.MissingReason
		} else if proc := a.processes.Process(model.ID); proc != nil {
			runtime := proc.RuntimeInfo(cfg)
			status["runtime"] = runtime
			if args, ok := runtime["args"].([]string); ok {
				status["args"] = args
			}
			if proc.Error() != "" {
				status["error"] = proc.Error()
			}
		}
		modalities := []string{"text"}
		if model.MmprojPath != "" {
			modalities = append(modalities, "image")
		}
		data = append(data, map[string]any{
			"id":       model.ID,
			"name":     model.Name,
			"object":   "model",
			"owned_by": "model-router",
			"created":  now,
			"in_cache": model.Provider == "huggingface",
			"path":     model.ModelPath,
			"location": model.Location,
			"aliases":  []string{model.Name},
			"tags":     compactStrings([]string{model.Provider, model.Source, model.Metadata["format"], model.Metadata["task"]}),
			"status":   status,
			"architecture": map[string]any{
				"input_modalities":  modalities,
				"output_modalities": []string{"text"},
			},
			"meta": map[string]any{
				"provider":  model.Provider,
				"source":    model.Source,
				"location":  model.Location,
				"mmproj":    model.MmprojPath,
				"format":    model.Metadata["format"],
				"task":      model.Metadata["task"],
				"available": model.Available,
			},
		})
	}
	respondJSON(w, http.StatusOK, map[string]any{"object": "list", "data": data})
}

func (a *App) handleModelsLoad(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var req struct {
		Model string   `json:"model"`
		Extra []string `json:"extra_args"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	if req.Model == "" {
		respondError(w, http.StatusBadRequest, fmt.Errorf("model is required"))
		return
	}
	if len(req.Extra) > 0 {
		_ = a.store.Update(func(next *AppConfig) error {
			model, ok := next.Models[req.Model]
			if !ok {
				return fmt.Errorf("model %s not found", req.Model)
			}
			model.Launch.ExtraArgs = append(model.Launch.ExtraArgs, req.Extra...)
			next.Models[req.Model] = model
			return nil
		})
	}
	if _, err := a.processes.EnsureModel(r.Context(), req.Model); err != nil {
		respondError(w, http.StatusBadGateway, err)
		return
	}
	respondJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (a *App) handleModelsUnload(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var req struct {
		Model string `json:"model"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	if req.Model == "" {
		a.processes.StopAll(false)
	} else {
		_ = a.processes.StopModel(req.Model, false)
	}
	respondJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (a *App) handleProps(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	modelID := r.URL.Query().Get("model")
	if modelID == "" {
		respondJSON(w, http.StatusOK, routerProps())
		return
	}
	if proc := a.processes.Process(modelID); proc != nil && proc.CurrentState() == ProcessReady {
		proc.Proxy(w, stripRouterQuery(r))
		return
	}
	cfg := a.store.Get()
	model, ok := cfg.Models[modelID]
	if !ok {
		respondError(w, http.StatusNotFound, fmt.Errorf("model %s not found", modelID))
		return
	}
	if !shouldAutoload(r) {
		respondJSON(w, http.StatusOK, syntheticModelProps(model))
		return
	}
	proc, err := a.processes.EnsureModel(r.Context(), modelID)
	if err != nil {
		respondError(w, http.StatusBadGateway, err)
		return
	}
	proc.Proxy(w, stripRouterQuery(r))
}

func (a *App) handleSlots(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	modelID := r.URL.Query().Get("model")
	if modelID == "" {
		if proc := a.processes.ActiveProcess(); proc != nil && proc.CurrentState() == ProcessReady {
			proc.Proxy(w, stripRouterQuery(r))
			return
		}
		respondJSON(w, http.StatusOK, []any{})
		return
	}
	if proc := a.processes.Process(modelID); proc != nil && proc.CurrentState() == ProcessReady {
		proc.Proxy(w, stripRouterQuery(r))
		return
	}
	respondJSON(w, http.StatusOK, []any{})
}

func (a *App) handleTools(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	switch r.Method {
	case http.MethodGet:
		modelID := r.URL.Query().Get("model")
		if modelID == "" {
			if proc := a.processes.ActiveProcess(); proc != nil && proc.CurrentState() == ProcessReady {
				proc.Proxy(w, stripRouterQuery(r))
				return
			}
			respondJSON(w, http.StatusOK, []any{})
			return
		}
		if proc := a.processes.Process(modelID); proc != nil && proc.CurrentState() == ProcessReady {
			proc.Proxy(w, stripRouterQuery(r))
			return
		}
		if !shouldAutoload(r) {
			respondJSON(w, http.StatusOK, []any{})
			return
		}
		proc, err := a.processes.EnsureModel(r.Context(), modelID)
		if err != nil {
			respondError(w, http.StatusBadGateway, err)
			return
		}
		proc.Proxy(w, stripRouterQuery(r))
	case http.MethodPost:
		modelID := r.URL.Query().Get("model")
		if modelID == "" {
			if proc := a.processes.ActiveProcess(); proc != nil && proc.CurrentState() == ProcessReady {
				proc.Proxy(w, stripRouterQuery(r))
				return
			}
			respondError(w, http.StatusBadRequest, fmt.Errorf("model is required for built-in tool execution"))
			return
		}
		proc, err := a.processes.EnsureModel(r.Context(), modelID)
		if err != nil {
			respondError(w, http.StatusBadGateway, err)
			return
		}
		proc.Proxy(w, stripRouterQuery(r))
	default:
		methodNotAllowed(w)
	}
}

func (a *App) handleProxyByBodyOrActive(w http.ResponseWriter, r *http.Request) {
	if !a.requireAuth(w, r) {
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	modelID := modelIDFromJSON(body)
	if modelID == "" {
		modelID = r.URL.Query().Get("model")
	}
	proc, err := a.processForRequest(r.Context(), modelID)
	if err != nil {
		respondError(w, http.StatusBadRequest, err)
		return
	}
	effectiveModelID := modelID
	if effectiveModelID == "" {
		effectiveModelID = proc.id
	}
	if merged, changed := mergeGenerationPreset(body, a.generationPresetForModel(effectiveModelID)); changed {
		body = merged
	}
	r.Body = io.NopCloser(bytes.NewReader(body))
	r.ContentLength = int64(len(body))
	proc.Proxy(w, r)
}

func (a *App) generationPresetForModel(modelID string) map[string]any {
	if strings.TrimSpace(modelID) == "" {
		return nil
	}
	cfg := a.store.Get()
	model, ok := cfg.Models[modelID]
	if !ok {
		return nil
	}
	return cloneAnyMap(model.Generation)
}

func (a *App) processForRequest(ctx context.Context, modelID string) (*ModelProcess, error) {
	if modelID == "" {
		if proc := a.processes.ActiveProcess(); proc != nil && proc.CurrentState() == ProcessReady {
			return proc, nil
		}
		cfg := a.store.Get()
		var only string
		count := 0
		for id, model := range cfg.Models {
			if model.Available {
				only = id
				count++
			}
		}
		if count == 1 {
			modelID = only
		}
	}
	if modelID == "" {
		return nil, fmt.Errorf("model is required")
	}
	return a.processes.EnsureModel(ctx, modelID)
}

func (a *App) requireAuth(w http.ResponseWriter, r *http.Request) bool {
	keys := a.store.Get().Server.APIKeys
	if len(keys) == 0 {
		return true
	}
	provided := strings.TrimSpace(r.Header.Get("X-API-Key"))
	if provided == "" {
		auth := strings.TrimSpace(r.Header.Get("Authorization"))
		provided = strings.TrimSpace(strings.TrimPrefix(auth, "Bearer "))
	}
	if provided == "" {
		provided = r.URL.Query().Get("api_key")
	}
	for _, key := range keys {
		if provided != "" && provided == key {
			return true
		}
	}
	w.Header().Set("WWW-Authenticate", `Bearer realm="web-ui-app"`)
	respondError(w, http.StatusUnauthorized, fmt.Errorf("access denied"))
	return false
}

func modelIDFromJSON(raw []byte) string {
	if len(bytes.TrimSpace(raw)) == 0 {
		return ""
	}
	var body struct {
		Model string `json:"model"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		return ""
	}
	return body.Model
}

func sanitizeGenerationPreset(in map[string]any) (map[string]any, error) {
	out := map[string]any{}
	for key, value := range in {
		if _, ok := generationPresetKeys[key]; !ok {
			continue
		}
		if key == "custom" && !isClearedGenerationValue(value) {
			if _, err := customPresetMap(value); err != nil {
				return nil, fmt.Errorf("custom must be a JSON object: %w", err)
			}
		}
		out[key] = value
	}
	return out, nil
}

func mergeGenerationPreset(raw []byte, preset map[string]any) ([]byte, bool) {
	if len(preset) == 0 || len(bytes.TrimSpace(raw)) == 0 {
		return raw, false
	}
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil || body == nil {
		return raw, false
	}
	changed := false
	for key, value := range preset {
		if key == "custom" || isClearedGenerationValue(value) {
			continue
		}
		if _, exists := body[key]; !exists {
			body[key] = value
			changed = true
		}
	}
	if customRaw, ok := preset["custom"]; ok && !isClearedGenerationValue(customRaw) {
		if custom, err := customPresetMap(customRaw); err == nil {
			for key, value := range custom {
				if _, exists := body[key]; !exists {
					body[key] = value
					changed = true
				}
			}
		}
	}
	if !changed {
		return raw, false
	}
	merged, err := json.Marshal(body)
	if err != nil {
		return raw, false
	}
	return merged, true
}

func generationMapOrEmpty(in map[string]any) map[string]any {
	if in == nil {
		return map[string]any{}
	}
	return cloneAnyMap(in)
}

func customPresetMap(value any) (map[string]any, error) {
	switch typed := value.(type) {
	case map[string]any:
		return typed, nil
	case string:
		var out map[string]any
		if err := json.Unmarshal([]byte(strings.TrimSpace(typed)), &out); err != nil {
			return nil, err
		}
		if out == nil {
			return nil, fmt.Errorf("custom JSON must decode to an object")
		}
		return out, nil
	default:
		return nil, fmt.Errorf("unsupported custom value %T", value)
	}
}

func isClearedGenerationValue(value any) bool {
	if value == nil {
		return true
	}
	if text, ok := value.(string); ok {
		return strings.TrimSpace(text) == ""
	}
	return false
}

func routerProps() map[string]any {
	return map[string]any{
		"role":            "router",
		"max_instances":   1,
		"models_autoload": true,
		"model_alias":     "llama-server",
		"model_path":      "none",
		"default_generation_settings": map[string]any{
			"params": map[string]any{},
			"n_ctx":  0,
		},
		"webui_settings": map[string]any{},
		"build_info":     "web-ui-app llama-swap style router",
	}
}

func syntheticModelProps(model ModelConfig) map[string]any {
	nCtx := 0
	if model.Launch.ContextSize != nil {
		nCtx = *model.Launch.ContextSize
	}
	return map[string]any{
		"role":        "model",
		"model_alias": model.ID,
		"model_path":  model.ModelPath,
		"default_generation_settings": map[string]any{
			"params": map[string]any{},
			"n_ctx":  nCtx,
		},
		"modalities": map[string]any{
			"vision": model.MmprojPath != "",
			"audio":  false,
		},
		"webui":      true,
		"build_info": "web-ui-app synthetic props",
	}
}

func stripRouterQuery(r *http.Request) *http.Request {
	clone := r.Clone(r.Context())
	u := *r.URL
	q := u.Query()
	q.Del("model")
	q.Del("autoload")
	u.RawQuery = q.Encode()
	clone.URL = &u
	return clone
}

func shouldAutoload(r *http.Request) bool {
	value := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("autoload")))
	return value == "" || value == "1" || value == "true"
}

func routerStatusValue(state ProcessState, available bool) string {
	if !available {
		return "failed"
	}
	switch state {
	case ProcessReady:
		return "loaded"
	case ProcessStarting:
		return "loading"
	case ProcessFailed:
		return "failed"
	default:
		return "unloaded"
	}
}

func compactStrings(values []string) []string {
	out := []string{}
	seen := map[string]bool{}
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		out = append(out, value)
	}
	sort.Strings(out)
	return out
}

func respondJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func respondError(w http.ResponseWriter, status int, err error) {
	respondJSON(w, status, map[string]any{
		"error": map[string]any{
			"message": err.Error(),
			"type":    "invalid_request_error",
		},
	})
}

func methodNotAllowed(w http.ResponseWriter) {
	respondError(w, http.StatusMethodNotAllowed, fmt.Errorf("method not allowed"))
}

func logMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		if strings.HasPrefix(r.URL.Path, "/api/") {
			log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start).Round(time.Millisecond))
		}
	})
}
