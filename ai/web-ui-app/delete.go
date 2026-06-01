package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type DeleteResult struct {
	ModelID      string   `json:"modelId"`
	Deleted      []string `json:"deleted"`
	Skipped      []string `json:"skipped"`
	ConfigOnly   bool     `json:"configOnly"`
	ErrorMessage string   `json:"error,omitempty"`
}

func DeleteModelFiles(appDir string, cfg AppConfig, model ModelConfig) DeleteResult {
	result := DeleteResult{ModelID: model.ID}
	roots := safeDeleteRoots(appDir, cfg)
	deletePath := func(path string) {
		path = strings.TrimSpace(path)
		if path == "" {
			return
		}
		clean := filepath.Clean(path)
		if !isUnderAnyRoot(clean, roots) {
			result.Skipped = append(result.Skipped, clean+" (outside known model roots)")
			return
		}
		if err := os.Remove(clean); err != nil {
			if os.IsNotExist(err) {
				result.Skipped = append(result.Skipped, clean+" (missing)")
				return
			}
			result.Skipped = append(result.Skipped, fmt.Sprintf("%s (%v)", clean, err))
			return
		}
		result.Deleted = append(result.Deleted, clean)
	}
	deletePath(model.ModelPath)
	deletePath(model.MmprojPath)
	return result
}

func safeDeleteRoots(appDir string, cfg AppConfig) []string {
	discovery := NewDiscoveryService(appDir)
	roots := discovery.KnownRoots(cfg)
	roots = append(roots, filepath.Join(appDir, "models"))
	return roots
}

func isUnderAnyRoot(path string, roots []string) bool {
	pathAbs, err := filepath.Abs(path)
	if err != nil {
		return false
	}
	if resolved, err := filepath.EvalSymlinks(pathAbs); err == nil {
		pathAbs = resolved
	}
	for _, root := range roots {
		root = expandPath(root)
		rootAbs, err := filepath.Abs(root)
		if err != nil {
			continue
		}
		if resolved, err := filepath.EvalSymlinks(rootAbs); err == nil {
			rootAbs = resolved
		}
		rel, err := filepath.Rel(rootAbs, pathAbs)
		if err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return true
		}
	}
	return false
}
