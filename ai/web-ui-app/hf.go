package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

type HFService struct {
	appDir    string
	store     *ConfigStore
	discovery *DiscoveryService
	runtime   *RuntimeService
	client    *http.Client
	mu        sync.Mutex
	tasks     map[string]*DownloadTask
}

type HFTreeEntry struct {
	Path string `json:"path"`
	Type string `json:"type"`
	Size int64  `json:"size,omitempty"`
}

type DownloadTask struct {
	ID              string   `json:"id"`
	Status          string   `json:"status"`
	Repo            string   `json:"repo"`
	Revision        string   `json:"revision"`
	Paths           []string `json:"paths"`
	Location        string   `json:"location"`
	Current         string   `json:"current,omitempty"`
	DownloadedBytes int64    `json:"downloadedBytes"`
	TotalBytes      int64    `json:"totalBytes"`
	Error           string   `json:"error,omitempty"`
	CreatedAt       string   `json:"createdAt"`
	UpdatedAt       string   `json:"updatedAt"`
}

func NewHFService(appDir string, store *ConfigStore, discovery *DiscoveryService, runtimeSvc *RuntimeService) *HFService {
	return &HFService{
		appDir:    appDir,
		store:     store,
		discovery: discovery,
		runtime:   runtimeSvc,
		client:    &http.Client{Timeout: 0},
		tasks:     map[string]*DownloadTask{},
	}
}

func (h *HFService) ListTree(ctx context.Context, repo, revision, prefix string, recursive bool) ([]HFTreeEntry, error) {
	repo = normalizeHFRepo(repo)
	if repo == "" {
		return nil, fmt.Errorf("repo is required")
	}
	if revision == "" {
		revision = "main"
	}
	endpoint := fmt.Sprintf("https://huggingface.co/api/models/%s/tree/%s", url.PathEscape(repo), url.PathEscape(revision))
	endpoint = strings.ReplaceAll(endpoint, "%2F", "/")
	if prefix != "" {
		endpoint += "/" + strings.TrimPrefix(prefix, "/")
	}
	q := url.Values{}
	if recursive {
		q.Set("recursive", "1")
	}
	if qs := q.Encode(); qs != "" {
		endpoint += "?" + qs
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	if token := hfToken(); token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := h.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return nil, fmt.Errorf("huggingface API error %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var raw []struct {
		Path string `json:"path"`
		Type string `json:"type"`
		Size int64  `json:"size"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return nil, err
	}
	out := make([]HFTreeEntry, 0, len(raw))
	for _, item := range raw {
		if item.Type == "file" {
			lower := strings.ToLower(item.Path)
			if !strings.HasSuffix(lower, ".gguf") && !strings.Contains(lower, "mmproj") {
				continue
			}
		}
		out = append(out, HFTreeEntry{Path: item.Path, Type: item.Type, Size: item.Size})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Type == out[j].Type {
			return out[i].Path < out[j].Path
		}
		return out[i].Type == "directory"
	})
	return out, nil
}

func (h *HFService) StartDownload(repo, revision string, paths []string, location string) DownloadTask {
	if revision == "" {
		revision = "main"
	}
	location = normalizeModelLocation(location, "")
	task := DownloadTask{
		ID:        fmt.Sprintf("dl-%d", time.Now().UnixNano()),
		Status:    "queued",
		Repo:      normalizeHFRepo(repo),
		Revision:  revision,
		Paths:     append([]string{}, paths...),
		Location:  location,
		CreatedAt: nowRFC3339(),
		UpdatedAt: nowRFC3339(),
	}
	h.mu.Lock()
	h.tasks[task.ID] = &task
	h.mu.Unlock()
	go h.runDownload(task.ID)
	return task
}

func (h *HFService) Downloads() []DownloadTask {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make([]DownloadTask, 0, len(h.tasks))
	for _, task := range h.tasks {
		out = append(out, *task)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt > out[j].CreatedAt })
	return out
}

func (h *HFService) runDownload(id string) {
	h.updateTask(id, func(t *DownloadTask) {
		t.Status = "running"
	})
	task := h.getTask(id)
	if task == nil {
		return
	}
	if task.Location == modelLocationVM {
		if h.runtime == nil {
			h.updateTask(id, func(t *DownloadTask) {
				t.Status = "error"
				t.Error = "VM runtime bridge is unavailable"
			})
			return
		}
		progressPath := filepath.Join(os.TempDir(), id+".json")
		done := make(chan struct{})
		go h.pollProgress(id, progressPath, done)
		defer func() {
			close(done)
			_ = os.Remove(progressPath)
		}()
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Hour)
		defer cancel()
		err := h.runtime.DownloadHFToBridge(ctx, BridgeHFDownloadSpec{
			Repo:         task.Repo,
			Revision:     task.Revision,
			Paths:        task.Paths,
			Token:        hfToken(),
			ProgressPath: progressPath,
		})
		if err != nil {
			h.updateTask(id, func(t *DownloadTask) {
				t.Status = "error"
				t.Error = err.Error()
			})
			return
		}
		h.updateTask(id, func(t *DownloadTask) {
			t.Status = "complete"
			t.Current = ""
			if t.TotalBytes > 0 {
				t.DownloadedBytes = t.TotalBytes
			}
		})
		_, _ = h.discovery.MergeNew(h.store)
		return
	}
	for _, path := range task.Paths {
		if err := h.downloadOne(id, task.Repo, task.Revision, path); err != nil {
			h.updateTask(id, func(t *DownloadTask) {
				t.Status = "error"
				t.Error = err.Error()
			})
			return
		}
	}
	h.updateTask(id, func(t *DownloadTask) {
		t.Status = "complete"
	})
	_, _ = h.discovery.MergeNew(h.store)
}

func (h *HFService) downloadOne(taskID, repo, revision, remotePath string) error {
	remotePath = strings.TrimPrefix(filepath.ToSlash(filepath.Clean(remotePath)), "/")
	if remotePath == "." || strings.Contains(remotePath, "../") {
		return fmt.Errorf("invalid path %s", remotePath)
	}
	target := filepath.Join(hfPrimaryCacheRoot(), hfRepoDir(repo), "snapshots", revision, filepath.FromSlash(remotePath))
	if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
		return err
	}
	url := fmt.Sprintf("https://huggingface.co/%s/resolve/%s/%s?download=true", repo, url.PathEscape(revision), remotePath)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	if token := hfToken(); token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := h.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("download %s failed %d: %s", remotePath, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	h.updateTask(taskID, func(t *DownloadTask) {
		if resp.ContentLength > 0 {
			t.TotalBytes += resp.ContentLength
		}
	})
	tmp := target + ".part"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	buf := make([]byte, 256*1024)
	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			if _, err := out.Write(buf[:n]); err != nil {
				_ = out.Close()
				return err
			}
			h.updateTask(taskID, func(t *DownloadTask) {
				t.DownloadedBytes += int64(n)
			})
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			_ = out.Close()
			return readErr
		}
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, target)
}

func (h *HFService) pollProgress(id, progressPath string, done <-chan struct{}) {
	ticker := time.NewTicker(750 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-done:
			return
		case <-ticker.C:
			raw, err := os.ReadFile(progressPath)
			if err != nil || len(raw) == 0 {
				continue
			}
			var progress bridgeCopyProgress
			if json.Unmarshal(raw, &progress) != nil {
				continue
			}
			h.updateTask(id, func(t *DownloadTask) {
				if progress.CopiedBytes >= 0 {
					t.DownloadedBytes = progress.CopiedBytes
				}
				if progress.TotalBytes > 0 {
					t.TotalBytes = progress.TotalBytes
				}
				t.Current = progress.Current
				if progress.Status != "" && t.Status != "error" && t.Status != "complete" {
					t.Status = progress.Status
				}
			})
		}
	}
}

func (h *HFService) getTask(id string) *DownloadTask {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.tasks[id]
}

func (h *HFService) updateTask(id string, fn func(*DownloadTask)) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if task := h.tasks[id]; task != nil {
		fn(task)
		task.UpdatedAt = nowRFC3339()
	}
}

func normalizeHFRepo(repo string) string {
	repo = strings.TrimSpace(repo)
	repo = strings.TrimPrefix(repo, "https://huggingface.co/")
	repo = strings.TrimPrefix(repo, "http://huggingface.co/")
	repo = strings.Trim(repo, "/")
	parts := strings.Split(repo, "/")
	if len(parts) >= 2 {
		return parts[0] + "/" + parts[1]
	}
	return repo
}

func hfRepoDir(repo string) string {
	return "models--" + strings.ReplaceAll(repo, "/", "--")
}

func hfPrimaryCacheRoot() string {
	if v := strings.TrimSpace(os.Getenv("HUGGINGFACE_HUB_CACHE")); v != "" {
		return filepath.Clean(v)
	}
	if v := strings.TrimSpace(os.Getenv("HF_HOME")); v != "" {
		return filepath.Join(v, "hub")
	}
	if home, err := os.UserHomeDir(); err == nil {
		return filepath.Join(home, ".cache", "huggingface", "hub")
	}
	return filepath.Join(".", "models", "huggingface", "hub")
}

func hfToken() string {
	for _, key := range []string{"HF_TOKEN", "HUGGINGFACE_HUB_TOKEN"} {
		if v := strings.TrimSpace(os.Getenv(key)); v != "" {
			return v
		}
	}
	return ""
}
