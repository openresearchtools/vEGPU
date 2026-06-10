package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	downloadStatusQueued   = "queued"
	downloadStatusRunning  = "running"
	downloadStatusPaused   = "paused"
	downloadStatusStopped  = "stopped"
	downloadStatusRetrying = "retrying"
	downloadStatusStalled  = "stalled"
	downloadStatusError    = "error"
	downloadStatusComplete = "complete"
)

var (
	errDownloadCanceled = errors.New("download canceled")
	errDownloadIdle     = errors.New("download made no progress")
)

type HFService struct {
	appDir    string
	store     *ConfigStore
	discovery *DiscoveryService
	runtime   *RuntimeService
	client    *http.Client
	endpoint  string

	taskDir   string
	taskPath  string
	mu        sync.Mutex
	tasks     map[string]*DownloadTask
	active    map[string]*downloadRun
	lastSave  time.Time
	saveEvery time.Duration

	idleTimeout time.Duration
	retryBase   time.Duration
	retryMax    time.Duration
}

type downloadRun struct {
	cancel context.CancelFunc
	done   chan struct{}
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
	CanResume       bool     `json:"canResume"`
	RetryCount      int      `json:"retryCount"`
	LastBytesAt     string   `json:"lastBytesAt,omitempty"`
	RestartPending  bool     `json:"restartPending,omitempty"`
	CreatedAt       string   `json:"createdAt"`
	UpdatedAt       string   `json:"updatedAt"`
}

type hfTaskStore struct {
	Tasks []DownloadTask `json:"tasks"`
}

type hfFileMeta struct {
	URL    string
	Size   int64
	ETag   string
	Commit string
}

type downloadRetry struct {
	err     error
	delay   time.Duration
	stalled bool
}

func (e downloadRetry) Error() string { return e.err.Error() }
func (e downloadRetry) Unwrap() error { return e.err }

func NewHFService(appDir string, store *ConfigStore, discovery *DiscoveryService, runtimeSvc *RuntimeService) *HFService {
	taskDir := filepath.Join(appDir, "hf-downloads")
	h := &HFService{
		appDir:      appDir,
		store:       store,
		discovery:   discovery,
		runtime:     runtimeSvc,
		client:      &http.Client{Timeout: 0},
		endpoint:    "https://huggingface.co",
		taskDir:     taskDir,
		taskPath:    filepath.Join(taskDir, "tasks.json"),
		tasks:       map[string]*DownloadTask{},
		active:      map[string]*downloadRun{},
		saveEvery:   time.Second,
		idleTimeout: 90 * time.Second,
		retryBase:   2 * time.Second,
		retryMax:    time.Minute,
	}
	h.loadTasks()
	return h
}

func (h *HFService) ListTree(ctx context.Context, repo, revision, prefix string, recursive bool) ([]HFTreeEntry, error) {
	repo = normalizeHFRepo(repo)
	if repo == "" {
		return nil, fmt.Errorf("repo is required")
	}
	if revision == "" {
		revision = "main"
	}
	endpoint := fmt.Sprintf("%s/api/models/%s/tree/%s", strings.TrimRight(h.endpoint, "/"), url.PathEscape(repo), url.PathEscape(revision))
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
	now := nowRFC3339()
	task := DownloadTask{
		ID:        fmt.Sprintf("dl-%d", time.Now().UnixNano()),
		Status:    downloadStatusQueued,
		Repo:      normalizeHFRepo(repo),
		Revision:  revision,
		Paths:     normalizeHFPaths(paths),
		Location:  location,
		CanResume: true,
		CreatedAt: now,
		UpdatedAt: now,
	}
	h.mu.Lock()
	h.tasks[task.ID] = &task
	h.saveTasksLocked(true)
	h.mu.Unlock()
	h.startTask(task.ID)
	return task
}

func (h *HFService) Downloads() []DownloadTask {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.taskSnapshotLocked()
}

func (h *HFService) PauseDownload(id string) (DownloadTask, error) {
	task, err := h.setControlStatus(id, downloadStatusPaused)
	if err != nil {
		return task, err
	}
	h.cancelActive(id, 5*time.Second)
	return h.getTaskCopy(id)
}

func (h *HFService) StopDownload(id string) (DownloadTask, error) {
	task, err := h.setControlStatus(id, downloadStatusStopped)
	if err != nil {
		return task, err
	}
	h.cancelActive(id, 5*time.Second)
	return h.getTaskCopy(id)
}

func (h *HFService) ResumeDownload(id string) (DownloadTask, error) {
	task, err := h.queueExistingTask(id, false)
	if err != nil {
		return task, err
	}
	h.startTask(id)
	return h.getTaskCopy(id)
}

func (h *HFService) RestartDownload(id string) (DownloadTask, error) {
	h.cancelActive(id, 5*time.Second)
	task, err := h.queueExistingTask(id, true)
	if err != nil {
		return task, err
	}
	if task.Location != modelLocationVM {
		_ = h.deleteDownloadFiles(task)
	}
	h.startTask(id)
	return h.getTaskCopy(id)
}

func (h *HFService) startTask(id string) {
	h.mu.Lock()
	if h.tasks[id] == nil || h.active[id] != nil {
		h.mu.Unlock()
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	run := &downloadRun{cancel: cancel, done: make(chan struct{})}
	h.active[id] = run
	h.mu.Unlock()

	go func() {
		defer func() {
			h.mu.Lock()
			delete(h.active, id)
			h.mu.Unlock()
			close(run.done)
		}()
		h.runDownload(ctx, id)
	}()
}

func (h *HFService) runDownload(ctx context.Context, id string) {
	h.updateTask(id, true, func(t *DownloadTask) {
		if t.Status == downloadStatusQueued || t.Status == downloadStatusRetrying || t.Status == downloadStatusStalled || t.Status == downloadStatusError {
			t.Status = downloadStatusRunning
			t.Error = ""
		}
	})
	task := h.getTask(id)
	if task == nil {
		return
	}
	if isTerminalControlStatus(task.Status) {
		return
	}
	if task.Location == modelLocationVM {
		h.runVMDownload(ctx, id, *task)
		return
	}
	if err := h.runMacDownload(ctx, id, *task); err != nil {
		if errors.Is(err, errDownloadCanceled) || ctx.Err() != nil {
			return
		}
		h.updateTask(id, true, func(t *DownloadTask) {
			if !isTerminalControlStatus(t.Status) {
				t.Status = downloadStatusError
				t.Error = err.Error()
				t.CanResume = true
			}
		})
		return
	}
	if ctx.Err() != nil {
		return
	}
	h.updateTask(id, true, func(t *DownloadTask) {
		t.Status = downloadStatusComplete
		t.Current = ""
		t.Error = ""
		t.CanResume = false
		t.RestartPending = false
		if t.TotalBytes > 0 {
			t.DownloadedBytes = t.TotalBytes
		}
	})
	if h.discovery != nil && h.store != nil {
		_, _ = h.discovery.MergeNew(h.store)
	}
}

func (h *HFService) runVMDownload(ctx context.Context, id string, task DownloadTask) {
	if h.runtime == nil {
		h.updateTask(id, true, func(t *DownloadTask) {
			t.Status = downloadStatusError
			t.Error = "VM runtime bridge is unavailable"
			t.CanResume = true
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
	err := h.runtime.DownloadHFToBridge(ctx, BridgeHFDownloadSpec{
		Repo:         task.Repo,
		Revision:     task.Revision,
		Paths:        task.Paths,
		Token:        hfToken(),
		ProgressPath: progressPath,
		Restart:      task.RestartPending,
	})
	if err != nil {
		if ctx.Err() != nil {
			return
		}
		h.updateTask(id, true, func(t *DownloadTask) {
			if !isTerminalControlStatus(t.Status) {
				t.Status = downloadStatusError
				t.Error = err.Error()
				t.CanResume = true
			}
		})
		return
	}
	h.updateTask(id, true, func(t *DownloadTask) {
		t.Status = downloadStatusComplete
		t.Current = ""
		t.Error = ""
		t.CanResume = false
		t.RestartPending = false
		if t.TotalBytes > 0 {
			t.DownloadedBytes = t.TotalBytes
		}
	})
	if h.discovery != nil && h.store != nil {
		_, _ = h.discovery.MergeNew(h.store)
	}
}

func (h *HFService) runMacDownload(ctx context.Context, id string, task DownloadTask) error {
	if len(task.Paths) == 0 {
		return fmt.Errorf("at least one valid Hugging Face path is required")
	}
	if task.RestartPending {
		_ = h.deleteDownloadFiles(task)
		h.updateTask(id, true, func(t *DownloadTask) {
			t.RestartPending = false
			t.DownloadedBytes = 0
			t.TotalBytes = 0
			t.RetryCount = 0
		})
	}
	metas := map[string]hfFileMeta{}
	var totalBytes int64
	for _, path := range task.Paths {
		if err := ctx.Err(); err != nil {
			return errDownloadCanceled
		}
		meta, err := h.fetchHFMetadata(ctx, task.Repo, task.Revision, path)
		if err != nil {
			return err
		}
		metas[path] = meta
		if meta.Size > 0 {
			totalBytes += meta.Size
		}
	}
	h.updateTask(id, true, func(t *DownloadTask) {
		if totalBytes > 0 {
			t.TotalBytes = totalBytes
		}
		t.CanResume = true
	})

	var completedBytes int64
	for _, path := range task.Paths {
		if err := ctx.Err(); err != nil {
			return errDownloadCanceled
		}
		meta := metas[path]
		target := h.hfCacheTarget(task.Repo, task.Revision, path)
		part := target + ".part"
		if isCompleteFile(target, meta.Size) {
			completedBytes += fileSize(target)
			h.updateTask(id, true, func(t *DownloadTask) {
				t.DownloadedBytes = completedBytes
				t.Current = path
			})
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return err
		}
		if meta.Size > 0 {
			if size := fileSize(part); size > meta.Size {
				_ = os.Remove(part)
			}
		}
		h.updateTask(id, true, func(t *DownloadTask) {
			t.Status = downloadStatusRunning
			t.Current = path
			t.Error = ""
		})
		for {
			if err := ctx.Err(); err != nil {
				return errDownloadCanceled
			}
			done, err := h.downloadAttempt(ctx, id, task.Repo, task.Revision, path, target, part, meta, completedBytes)
			if done {
				break
			}
			if err == nil {
				continue
			}
			if errors.Is(err, errDownloadCanceled) || ctx.Err() != nil {
				return errDownloadCanceled
			}
			var retry downloadRetry
			if !errors.As(err, &retry) {
				return err
			}
			h.updateTask(id, true, func(t *DownloadTask) {
				if retry.stalled {
					t.Status = downloadStatusStalled
				} else {
					t.Status = downloadStatusRetrying
				}
				t.Error = retry.err.Error()
				t.CanResume = true
				t.RetryCount++
			})
			if err := sleepContext(ctx, retry.delay); err != nil {
				return errDownloadCanceled
			}
			h.updateTask(id, false, func(t *DownloadTask) {
				if !isTerminalControlStatus(t.Status) {
					t.Status = downloadStatusRunning
					t.Error = ""
				}
			})
		}
		actual := fileSize(target)
		if actual == 0 && meta.Size > 0 {
			actual = meta.Size
		}
		completedBytes += actual
		h.updateTask(id, true, func(t *DownloadTask) {
			t.DownloadedBytes = completedBytes
			t.Current = path
			t.Error = ""
		})
	}
	return nil
}

func (h *HFService) downloadAttempt(ctx context.Context, taskID, repo, revision, remotePath, target, part string, meta hfFileMeta, baseBytes int64) (bool, error) {
	offset := fileSize(part)
	if meta.Size > 0 && offset == meta.Size {
		return true, os.Rename(part, target)
	}
	attemptCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	var lastByte atomic.Int64
	var idleCanceled atomic.Bool
	lastByte.Store(time.Now().UnixNano())
	if h.idleTimeout > 0 {
		done := make(chan struct{})
		defer close(done)
		go func() {
			ticker := time.NewTicker(time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-done:
					return
				case <-attemptCtx.Done():
					return
				case <-ticker.C:
					if time.Since(time.Unix(0, lastByte.Load())) > h.idleTimeout {
						idleCanceled.Store(true)
						cancel()
						return
					}
				}
			}
		}()
	}

	req, err := http.NewRequestWithContext(attemptCtx, http.MethodGet, h.hfResolveURL(repo, revision, remotePath), nil)
	if err != nil {
		return false, err
	}
	if token := hfToken(); token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if offset > 0 {
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-", offset))
	}
	resp, err := h.client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return false, errDownloadCanceled
		}
		if idleCanceled.Load() {
			return false, h.retryError(errDownloadIdle, true, 0)
		}
		return false, h.retryError(err, false, 0)
	}
	defer resp.Body.Close()

	switch {
	case resp.StatusCode == http.StatusRequestedRangeNotSatisfiable && meta.Size > 0 && offset >= meta.Size:
		return true, os.Rename(part, target)
	case resp.StatusCode == http.StatusOK && offset > 0:
		offset = 0
		if err := os.Remove(part); err != nil && !os.IsNotExist(err) {
			return false, err
		}
	case resp.StatusCode == http.StatusPartialContent || resp.StatusCode == http.StatusOK:
	default:
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		err := fmt.Errorf("download %s failed %d: %s", remotePath, resp.StatusCode, strings.TrimSpace(string(body)))
		if resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode >= 500 {
			return false, h.retryError(err, false, retryDelayFromHeaders(resp.Header))
		}
		return false, err
	}

	if resp.StatusCode == http.StatusPartialContent {
		if total := parseContentRangeTotal(resp.Header.Get("Content-Range")); total > 0 {
			meta.Size = total
			h.updateTask(taskID, false, func(t *DownloadTask) {
				if t.TotalBytes < baseBytes+total {
					t.TotalBytes = baseBytes + total
				}
			})
		}
	}
	out, err := os.OpenFile(part, os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return false, err
	}
	if offset == 0 {
		if err := out.Truncate(0); err != nil {
			_ = out.Close()
			return false, err
		}
	}
	if _, err := out.Seek(offset, io.SeekStart); err != nil {
		_ = out.Close()
		return false, err
	}

	buf := make([]byte, 512*1024)
	written := offset
	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			lastByte.Store(time.Now().UnixNano())
			if _, err := out.Write(buf[:n]); err != nil {
				_ = out.Close()
				return false, err
			}
			written += int64(n)
			now := nowRFC3339()
			h.updateTask(taskID, false, func(t *DownloadTask) {
				t.DownloadedBytes = baseBytes + written
				t.LastBytesAt = now
				t.CanResume = true
			})
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			_ = out.Close()
			if ctx.Err() != nil {
				return false, errDownloadCanceled
			}
			if idleCanceled.Load() {
				return false, h.retryError(errDownloadIdle, true, 0)
			}
			return false, h.retryError(readErr, false, 0)
		}
	}
	if err := out.Close(); err != nil {
		return false, err
	}
	if meta.Size > 0 && written != meta.Size {
		return false, h.retryError(fmt.Errorf("downloaded %d of %d bytes for %s", written, meta.Size, remotePath), false, 0)
	}
	if err := os.Rename(part, target); err != nil {
		return false, err
	}
	return true, nil
}

func (h *HFService) fetchHFMetadata(ctx context.Context, repo, revision, remotePath string) (hfFileMeta, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, h.hfResolveURL(repo, revision, remotePath), nil)
	if err != nil {
		return hfFileMeta{}, err
	}
	if token := hfToken(); token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := h.client.Do(req)
	if err != nil {
		return hfFileMeta{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return hfFileMeta{}, fmt.Errorf("metadata %s failed %d: %s", remotePath, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	size := resp.ContentLength
	if size <= 0 {
		size = int64Header(resp.Header, "X-Linked-Size")
	}
	return hfFileMeta{
		URL:    resp.Request.URL.String(),
		Size:   size,
		ETag:   firstNonEmpty(resp.Header.Get("X-Linked-ETag"), resp.Header.Get("ETag")),
		Commit: resp.Header.Get("X-Repo-Commit"),
	}, nil
}

func (h *HFService) retryError(err error, stalled bool, delay time.Duration) error {
	if delay <= 0 {
		delay = h.retryBase
	}
	if h.retryMax > 0 && delay > h.retryMax {
		delay = h.retryMax
	}
	return downloadRetry{err: err, delay: delay, stalled: stalled}
}

func (h *HFService) hfResolveURL(repo, revision, remotePath string) string {
	parts := strings.Split(remotePath, "/")
	for i := range parts {
		parts[i] = url.PathEscape(parts[i])
	}
	return fmt.Sprintf("%s/%s/resolve/%s/%s?download=true", strings.TrimRight(h.endpoint, "/"), repo, url.PathEscape(revision), strings.Join(parts, "/"))
}

func (h *HFService) hfCacheTarget(repo, revision, remotePath string) string {
	return filepath.Join(hfPrimaryCacheRoot(), hfRepoDir(repo), "snapshots", revision, filepath.FromSlash(remotePath))
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
			h.updateTask(id, false, func(t *DownloadTask) {
				if progress.CopiedBytes >= 0 {
					t.DownloadedBytes = progress.CopiedBytes
				}
				if progress.TotalBytes > 0 {
					t.TotalBytes = progress.TotalBytes
				}
				t.Current = progress.Current
				if progress.Status != "" && !isTerminalControlStatus(t.Status) && t.Status != downloadStatusComplete {
					t.Status = progress.Status
				}
			})
		}
	}
}

func (h *HFService) getTask(id string) *DownloadTask {
	h.mu.Lock()
	defer h.mu.Unlock()
	task := h.tasks[id]
	if task == nil {
		return nil
	}
	copy := *task
	copy.Paths = append([]string{}, task.Paths...)
	return &copy
}

func (h *HFService) getTaskCopy(id string) (DownloadTask, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	task := h.tasks[id]
	if task == nil {
		return DownloadTask{}, fmt.Errorf("download %s not found", id)
	}
	copy := *task
	copy.Paths = append([]string{}, task.Paths...)
	return copy, nil
}

func (h *HFService) updateTask(id string, forceSave bool, fn func(*DownloadTask)) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if task := h.tasks[id]; task != nil {
		fn(task)
		task.UpdatedAt = nowRFC3339()
		h.saveTasksLocked(forceSave)
	}
}

func (h *HFService) setControlStatus(id, status string) (DownloadTask, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	task := h.tasks[id]
	if task == nil {
		return DownloadTask{}, fmt.Errorf("download %s not found", id)
	}
	if task.Status == downloadStatusComplete {
		return *task, nil
	}
	task.Status = status
	task.Error = ""
	task.CanResume = true
	task.UpdatedAt = nowRFC3339()
	h.saveTasksLocked(true)
	return *task, nil
}

func (h *HFService) queueExistingTask(id string, restart bool) (DownloadTask, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	task := h.tasks[id]
	if task == nil {
		return DownloadTask{}, fmt.Errorf("download %s not found", id)
	}
	task.Status = downloadStatusQueued
	task.Error = ""
	task.Current = ""
	task.CanResume = true
	if restart {
		task.RestartPending = true
		task.DownloadedBytes = 0
		task.RetryCount = 0
		task.LastBytesAt = ""
	}
	task.UpdatedAt = nowRFC3339()
	h.saveTasksLocked(true)
	return *task, nil
}

func (h *HFService) cancelActive(id string, wait time.Duration) {
	h.mu.Lock()
	run := h.active[id]
	h.mu.Unlock()
	if run == nil {
		return
	}
	run.cancel()
	if wait <= 0 {
		return
	}
	select {
	case <-run.done:
	case <-time.After(wait):
	}
}

func (h *HFService) loadTasks() {
	raw, err := os.ReadFile(h.taskPath)
	if err != nil {
		return
	}
	var store hfTaskStore
	if json.Unmarshal(raw, &store) != nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for i := range store.Tasks {
		task := store.Tasks[i]
		if isActiveDownloadStatus(task.Status) {
			task.Status = downloadStatusPaused
			task.CanResume = true
			task.Error = "Download was interrupted while PEGPU was not running."
		}
		task.Paths = normalizeHFPaths(task.Paths)
		h.tasks[task.ID] = &task
	}
	h.saveTasksLocked(true)
}

func (h *HFService) saveTasksLocked(force bool) {
	if h.taskPath == "" {
		return
	}
	if !force && h.saveEvery > 0 && time.Since(h.lastSave) < h.saveEvery {
		return
	}
	if err := os.MkdirAll(h.taskDir, 0755); err != nil {
		return
	}
	store := hfTaskStore{Tasks: h.taskSnapshotLocked()}
	raw, err := json.MarshalIndent(store, "", "  ")
	if err != nil {
		return
	}
	tmp := h.taskPath + ".tmp"
	if err := os.WriteFile(tmp, raw, 0644); err != nil {
		return
	}
	if err := os.Rename(tmp, h.taskPath); err == nil {
		h.lastSave = time.Now()
	}
}

func (h *HFService) taskSnapshotLocked() []DownloadTask {
	out := make([]DownloadTask, 0, len(h.tasks))
	for _, task := range h.tasks {
		copy := *task
		copy.Paths = append([]string{}, task.Paths...)
		out = append(out, copy)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt > out[j].CreatedAt })
	return out
}

func (h *HFService) deleteDownloadFiles(task DownloadTask) error {
	var firstErr error
	for _, path := range task.Paths {
		target := h.hfCacheTarget(task.Repo, task.Revision, path)
		for _, candidate := range []string{target + ".part", target} {
			if err := os.Remove(candidate); err != nil && !os.IsNotExist(err) && firstErr == nil {
				firstErr = err
			}
		}
	}
	return firstErr
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

func normalizeHFPaths(paths []string) []string {
	out := make([]string, 0, len(paths))
	seen := map[string]bool{}
	for _, path := range paths {
		path = strings.TrimPrefix(filepath.ToSlash(filepath.Clean(strings.TrimSpace(path))), "/")
		if path == "" || path == "." || strings.Contains(path, "../") || seen[path] {
			continue
		}
		seen[path] = true
		out = append(out, path)
	}
	return out
}

func hfRepoDir(repo string) string {
	return "models--" + strings.ReplaceAll(repo, "/", "--")
}

func hfPrimaryCacheRoot() string {
	if v := strings.TrimSpace(os.Getenv("HF_HUB_CACHE")); v != "" {
		return filepath.Clean(v)
	}
	if v := strings.TrimSpace(os.Getenv("HF_HOME")); v != "" {
		return filepath.Join(v, "hub")
	}
	if v := strings.TrimSpace(os.Getenv("HUGGINGFACE_HUB_CACHE")); v != "" {
		return filepath.Clean(v)
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

func isActiveDownloadStatus(status string) bool {
	switch status {
	case downloadStatusQueued, downloadStatusRunning, downloadStatusRetrying, downloadStatusStalled:
		return true
	default:
		return false
	}
}

func isTerminalControlStatus(status string) bool {
	return status == downloadStatusPaused || status == downloadStatusStopped
}

func fileSize(path string) int64 {
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return 0
	}
	return info.Size()
}

func isCompleteFile(path string, expected int64) bool {
	size := fileSize(path)
	if size <= 0 {
		return false
	}
	return expected <= 0 || size == expected
}

func int64Header(header http.Header, key string) int64 {
	value := strings.TrimSpace(header.Get(key))
	if value == "" {
		return 0
	}
	parsed, _ := strconv.ParseInt(value, 10, 64)
	return parsed
}

func parseContentRangeTotal(value string) int64 {
	value = strings.TrimSpace(value)
	slash := strings.LastIndex(value, "/")
	if slash < 0 || slash+1 >= len(value) {
		return 0
	}
	total := strings.TrimSpace(value[slash+1:])
	if total == "*" {
		return 0
	}
	parsed, _ := strconv.ParseInt(total, 10, 64)
	return parsed
}

func retryDelayFromHeaders(header http.Header) time.Duration {
	if retryAfter := strings.TrimSpace(header.Get("Retry-After")); retryAfter != "" {
		if seconds, err := strconv.ParseInt(retryAfter, 10, 64); err == nil && seconds > 0 {
			return time.Duration(seconds) * time.Second
		}
		if when, err := http.ParseTime(retryAfter); err == nil {
			if delay := time.Until(when); delay > 0 {
				return delay
			}
		}
	}
	for _, part := range strings.Split(header.Get("RateLimit"), ";") {
		part = strings.TrimSpace(strings.Trim(part, `"`))
		if strings.HasPrefix(part, "t=") {
			if seconds, err := strconv.ParseInt(strings.TrimPrefix(part, "t="), 10, 64); err == nil && seconds > 0 {
				return time.Duration(seconds) * time.Second
			}
		}
	}
	return 0
}

func sleepContext(ctx context.Context, delay time.Duration) error {
	if delay <= 0 {
		return nil
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
