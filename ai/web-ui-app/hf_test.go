package main

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestHFDownloadCompletes(t *testing.T) {
	data := []byte("a complete gguf-ish payload")
	server := newHFTestServer(t, data)
	defer server.Close()
	h, cache := newTestHFService(t, server.URL)

	task := h.StartDownload("org/model", "main", []string{"model.gguf"}, modelLocationMac)
	task = waitHFStatus(t, h, task.ID, downloadStatusComplete)

	got, err := os.ReadFile(filepath.Join(cache, "models--org--model", "snapshots", "main", "model.gguf"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, data) {
		t.Fatalf("downloaded data mismatch: %q", got)
	}
	if task.DownloadedBytes != int64(len(data)) {
		t.Fatalf("downloaded bytes = %d, want %d", task.DownloadedBytes, len(data))
	}
}

func TestHFDownloadResumesPartFile(t *testing.T) {
	data := []byte("resume this payload")
	server := newHFTestServer(t, data)
	defer server.Close()
	h, cache := newTestHFService(t, server.URL)

	part := filepath.Join(cache, "models--org--model", "snapshots", "main", "model.gguf.part")
	if err := os.MkdirAll(filepath.Dir(part), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(part, data[:7], 0644); err != nil {
		t.Fatal(err)
	}

	task := h.StartDownload("org/model", "main", []string{"model.gguf"}, modelLocationMac)
	waitHFStatus(t, h, task.ID, downloadStatusComplete)

	if got := server.getRanges(); len(got) == 0 || got[0] != "bytes=7-" {
		t.Fatalf("first GET range = %v, want bytes=7-", got)
	}
}

func TestHFPauseLeavesPartAndResumeContinues(t *testing.T) {
	data := []byte("pause then resume payload")
	server := newHFTestServer(t, data)
	server.idleFirstGETBytes = 6
	defer server.Close()
	h, cache := newTestHFService(t, server.URL)

	task := h.StartDownload("org/model", "main", []string{"model.gguf"}, modelLocationMac)
	part := filepath.Join(cache, "models--org--model", "snapshots", "main", "model.gguf.part")
	waitFileSizeAtLeast(t, part, 6)

	paused, err := h.PauseDownload(task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if paused.Status != downloadStatusPaused || !paused.CanResume {
		t.Fatalf("paused status=%s canResume=%v, want paused resumable", paused.Status, paused.CanResume)
	}
	if got := fileSize(part); got != 6 {
		t.Fatalf("part size after pause = %d, want 6", got)
	}

	if _, err := h.ResumeDownload(task.ID); err != nil {
		t.Fatal(err)
	}
	waitHFStatus(t, h, task.ID, downloadStatusComplete)
	if got := server.getRanges(); len(got) < 2 || got[1] != "bytes=6-" {
		t.Fatalf("ranges = %v, want resume request bytes=6-", got)
	}
	target := filepath.Join(cache, "models--org--model", "snapshots", "main", "model.gguf")
	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, data) {
		t.Fatalf("downloaded data mismatch after pause/resume: %q", got)
	}
}

func TestHFRestartDeletesPartAndStartsFromZero(t *testing.T) {
	data := []byte("restart from byte zero")
	server := newHFTestServer(t, data)
	defer server.Close()
	h, cache := newTestHFService(t, server.URL)

	part := filepath.Join(cache, "models--org--model", "snapshots", "main", "model.gguf.part")
	if err := os.MkdirAll(filepath.Dir(part), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(part, data[:8], 0644); err != nil {
		t.Fatal(err)
	}
	h.seedTask(DownloadTask{
		ID:        "dl-restart",
		Status:    downloadStatusStopped,
		Repo:      "org/model",
		Revision:  "main",
		Paths:     []string{"model.gguf"},
		Location:  modelLocationMac,
		CanResume: true,
		CreatedAt: nowRFC3339(),
		UpdatedAt: nowRFC3339(),
	})

	if _, err := h.RestartDownload("dl-restart"); err != nil {
		t.Fatal(err)
	}
	waitHFStatus(t, h, "dl-restart", downloadStatusComplete)
	if got := server.getRanges(); len(got) == 0 || got[0] != "" {
		t.Fatalf("first GET range = %v, want no Range header", got)
	}
}

func TestHFRetryAfterRateLimit(t *testing.T) {
	data := []byte("rate limit then resume")
	server := newHFTestServer(t, data)
	server.failFirstGET = true
	defer server.Close()
	h, _ := newTestHFService(t, server.URL)

	task := h.StartDownload("org/model", "main", []string{"model.gguf"}, modelLocationMac)
	task = waitHFStatus(t, h, task.ID, downloadStatusComplete)

	if task.RetryCount == 0 {
		t.Fatalf("retry count = 0, want retry after initial 429")
	}
}

func TestHFCompleteFileIsSkipped(t *testing.T) {
	data := []byte("already downloaded")
	server := newHFTestServer(t, data)
	defer server.Close()
	h, cache := newTestHFService(t, server.URL)

	target := filepath.Join(cache, "models--org--model", "snapshots", "main", "model.gguf")
	if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, data, 0644); err != nil {
		t.Fatal(err)
	}

	task := h.StartDownload("org/model", "main", []string{"model.gguf"}, modelLocationMac)
	waitHFStatus(t, h, task.ID, downloadStatusComplete)

	if got := server.getCount(); got != 0 {
		t.Fatalf("GET count = %d, want 0 for already-complete file", got)
	}
}

func TestHFInterruptedTaskLoadsPaused(t *testing.T) {
	appDir := t.TempDir()
	h := NewHFService(appDir, nil, nil, nil)
	h.seedTask(DownloadTask{
		ID:        "dl-old",
		Status:    downloadStatusRunning,
		Repo:      "org/model",
		Revision:  "main",
		Paths:     []string{"model.gguf"},
		Location:  modelLocationMac,
		CanResume: true,
		CreatedAt: nowRFC3339(),
		UpdatedAt: nowRFC3339(),
	})

	reloaded := NewHFService(appDir, nil, nil, nil)
	task, err := reloaded.getTaskCopy("dl-old")
	if err != nil {
		t.Fatal(err)
	}
	if task.Status != downloadStatusPaused || !task.CanResume {
		t.Fatalf("reloaded status=%s canResume=%v, want paused resumable", task.Status, task.CanResume)
	}
}

func TestHFIdleDownloadReconnectsAndResumes(t *testing.T) {
	data := []byte("idle reconnect payload")
	server := newHFTestServer(t, data)
	server.idleFirstGETBytes = 6
	defer server.Close()
	h, cache := newTestHFService(t, server.URL)
	h.idleTimeout = 20 * time.Millisecond

	task := h.StartDownload("org/model", "main", []string{"model.gguf"}, modelLocationMac)
	waitHFStatus(t, h, task.ID, downloadStatusComplete)

	if got := server.getRanges(); len(got) < 2 || got[1] != "bytes=6-" {
		t.Fatalf("ranges = %v, want second request to resume at byte 6", got)
	}
	target := filepath.Join(cache, "models--org--model", "snapshots", "main", "model.gguf")
	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, data) {
		t.Fatalf("downloaded data mismatch after idle resume: %q", got)
	}
}

func newTestHFService(t *testing.T, endpoint string) (*HFService, string) {
	t.Helper()
	appDir := t.TempDir()
	cache := t.TempDir()
	t.Setenv("HF_HUB_CACHE", cache)
	h := NewHFService(appDir, nil, nil, nil)
	h.endpoint = endpoint
	h.saveEvery = 0
	h.idleTimeout = 0
	h.retryBase = time.Millisecond
	h.retryMax = time.Millisecond
	return h, cache
}

func (h *HFService) seedTask(task DownloadTask) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.tasks[task.ID] = &task
	h.saveTasksLocked(true)
}

func waitHFStatus(t *testing.T, h *HFService, id, status string) DownloadTask {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		task, err := h.getTaskCopy(id)
		if err != nil {
			t.Fatal(err)
		}
		if task.Status == status {
			return task
		}
		if task.Status == downloadStatusError {
			t.Fatalf("download errored: %s", task.Error)
		}
		time.Sleep(10 * time.Millisecond)
	}
	task, _ := h.getTaskCopy(id)
	t.Fatalf("timed out waiting for %s, last status=%s error=%s", status, task.Status, task.Error)
	return DownloadTask{}
}

func waitFileSizeAtLeast(t *testing.T, path string, min int64) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if size := fileSize(path); size >= min {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s to reach %d bytes", path, min)
}

type hfTestServer struct {
	*httptest.Server
	t                 *testing.T
	data              []byte
	failFirstGET      bool
	idleFirstGETBytes int

	mu     sync.Mutex
	gets   int
	ranges []string
}

func newHFTestServer(t *testing.T, data []byte) *hfTestServer {
	t.Helper()
	s := &hfTestServer{t: t, data: data}
	s.Server = httptest.NewServer(http.HandlerFunc(s.handle))
	return s
}

func (s *hfTestServer) handle(w http.ResponseWriter, r *http.Request) {
	if !strings.HasSuffix(r.URL.Path, "/org/model/resolve/main/model.gguf") {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("ETag", `"test-etag"`)
	w.Header().Set("X-Repo-Commit", "test-commit")
	w.Header().Set("X-Linked-Size", fmt.Sprintf("%d", len(s.data)))
	if r.Method == http.MethodHead {
		w.Header().Set("Content-Length", fmt.Sprintf("%d", len(s.data)))
		w.WriteHeader(http.StatusOK)
		return
	}
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	s.mu.Lock()
	s.gets++
	getNumber := s.gets
	rangeHeader := r.Header.Get("Range")
	s.ranges = append(s.ranges, rangeHeader)
	failFirst := s.failFirstGET && getNumber == 1
	idleBytes := s.idleFirstGETBytes
	s.mu.Unlock()
	if failFirst {
		w.Header().Set("Retry-After", "0")
		http.Error(w, "slow down", http.StatusTooManyRequests)
		return
	}
	start := 0
	if rangeHeader != "" {
		var parsed int
		if _, err := fmt.Sscanf(rangeHeader, "bytes=%d-", &parsed); err != nil {
			http.Error(w, "bad range", http.StatusRequestedRangeNotSatisfiable)
			return
		}
		start = parsed
		if start >= len(s.data) {
			w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", len(s.data)))
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, len(s.data)-1, len(s.data)))
		w.Header().Set("Content-Length", fmt.Sprintf("%d", len(s.data)-start))
		w.WriteHeader(http.StatusPartialContent)
	} else {
		w.Header().Set("Content-Length", fmt.Sprintf("%d", len(s.data)))
		w.WriteHeader(http.StatusOK)
	}
	if idleBytes > 0 && getNumber == 1 {
		_, _ = w.Write(s.data[start:idleBytes])
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
		<-r.Context().Done()
		return
	}
	_, _ = w.Write(s.data[start:])
}

func (s *hfTestServer) getRanges() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string{}, s.ranges...)
}

func (s *hfTestServer) getCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.gets
}
