package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

type ModelCopyService struct {
	store     *ConfigStore
	discovery *DiscoveryService
	runtime   *RuntimeService
	mu        sync.Mutex
	tasks     map[string]*ModelCopyTask
}

type ModelCopyTask struct {
	ID              string   `json:"id"`
	Status          string   `json:"status"`
	ModelID         string   `json:"modelId"`
	ModelName       string   `json:"modelName"`
	Provider        string   `json:"provider"`
	SourceLocation  string   `json:"sourceLocation"`
	TargetLocation  string   `json:"targetLocation"`
	Files           []string `json:"files"`
	Copied          []string `json:"copied,omitempty"`
	Current         string   `json:"current,omitempty"`
	DownloadedBytes int64    `json:"downloadedBytes"`
	TotalBytes      int64    `json:"totalBytes"`
	Error           string   `json:"error,omitempty"`
	CreatedAt       string   `json:"createdAt"`
	UpdatedAt       string   `json:"updatedAt"`
}

type bridgeCopyProgress struct {
	Status      string `json:"status"`
	Current     string `json:"current,omitempty"`
	CopiedBytes int64  `json:"copiedBytes"`
	TotalBytes  int64  `json:"totalBytes"`
}

func NewModelCopyService(store *ConfigStore, discovery *DiscoveryService, runtimeSvc *RuntimeService) *ModelCopyService {
	return &ModelCopyService{
		store:     store,
		discovery: discovery,
		runtime:   runtimeSvc,
		tasks:     map[string]*ModelCopyTask{},
	}
}

func (s *ModelCopyService) StartCopy(modelID string) (ModelCopyTask, error) {
	cfg := s.store.Get()
	model, ok := cfg.Models[modelID]
	if !ok {
		return ModelCopyTask{}, fmt.Errorf("model %s not found", modelID)
	}
	provider := strings.ToLower(strings.TrimSpace(model.Provider))
	macRoot, vmRoot, err := modelCopyRoots(model)
	if err != nil {
		return ModelCopyTask{}, err
	}
	files := compactStrings([]string{model.ModelPath, model.MmprojPath})
	if len(files) == 0 {
		return ModelCopyTask{}, fmt.Errorf("model has no files to copy")
	}
	source := normalizeModelLocation(model.Location, model.ModelPath)
	target := modelLocationVM
	if source == modelLocationVM {
		target = modelLocationMac
	}
	task := ModelCopyTask{
		ID:             fmt.Sprintf("copy-%d", time.Now().UnixNano()),
		Status:         "queued",
		ModelID:        model.ID,
		ModelName:      firstNonEmpty(model.Name, model.ID),
		Provider:       provider,
		SourceLocation: source,
		TargetLocation: target,
		Files:          append([]string{}, files...),
		TotalBytes:     modelCopyInitialTotal(model, files, source),
		CreatedAt:      nowRFC3339(),
		UpdatedAt:      nowRFC3339(),
	}
	progressPath := filepath.Join(os.TempDir(), task.ID+".json")
	s.mu.Lock()
	s.tasks[task.ID] = &task
	s.mu.Unlock()
	go s.runCopy(task.ID, BridgeModelCopySpec{
		Provider:       provider,
		SourceLocation: source,
		Files:          files,
		MacRoot:        macRoot,
		VMRoot:         vmRoot,
		ProgressPath:   progressPath,
	}, progressPath)
	return task, nil
}

func (s *ModelCopyService) Tasks() []ModelCopyTask {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]ModelCopyTask, 0, len(s.tasks))
	for _, task := range s.tasks {
		out = append(out, *task)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt > out[j].CreatedAt })
	return out
}

func (s *ModelCopyService) runCopy(id string, spec BridgeModelCopySpec, progressPath string) {
	s.updateTask(id, func(t *ModelCopyTask) {
		t.Status = "running"
	})
	done := make(chan struct{})
	go s.pollProgress(id, progressPath, done)
	defer func() {
		close(done)
		_ = os.Remove(progressPath)
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Hour)
	defer cancel()
	result, err := s.runtime.CopyModelAcrossBridge(ctx, spec)
	if err != nil {
		s.updateTask(id, func(t *ModelCopyTask) {
			t.Status = "error"
			t.Error = err.Error()
		})
		return
	}
	s.updateTask(id, func(t *ModelCopyTask) {
		t.Status = "complete"
		t.Copied = append([]string{}, result.Copied...)
		if t.TotalBytes > 0 {
			t.DownloadedBytes = t.TotalBytes
		}
		t.Current = ""
	})
	_, _ = s.discovery.MergeNew(s.store)
}

func (s *ModelCopyService) pollProgress(id, progressPath string, done <-chan struct{}) {
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
			s.updateTask(id, func(t *ModelCopyTask) {
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

func (s *ModelCopyService) updateTask(id string, fn func(*ModelCopyTask)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if task := s.tasks[id]; task != nil {
		fn(task)
		task.UpdatedAt = nowRFC3339()
	}
}

func modelCopyInitialTotal(model ModelConfig, files []string, source string) int64 {
	if source == modelLocationMac {
		var total int64
		for _, file := range files {
			info, err := os.Stat(expandPath(file))
			if err == nil && !info.IsDir() {
				total += info.Size()
			}
		}
		return total
	}
	if model.SizeBytes > 0 {
		return model.SizeBytes
	}
	return 0
}
