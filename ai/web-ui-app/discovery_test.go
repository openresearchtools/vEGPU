package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestSortedModelsForClientKeepsSavedVMModels(t *testing.T) {
	modelPath := "/home/pegpu/.cache/huggingface/hub/models--org--model/snapshots/abc/model.gguf"
	cfg := defaultConfig(t.TempDir())
	cfg.Models = map[string]ModelConfig{
		"VM-test-model": {
			ID:        "VM-test-model",
			Name:      "VM-test-model",
			Location:  modelLocationVM,
			ModelPath: modelPath,
			Available: true,
			Metadata:  map[string]string{modelMetadataDiscovered: "true"},
			Launch:    LaunchConfig{MainGPUDevice: "CUDA0"},
		},
	}

	app := &App{}
	models := app.sortedModelsForClient(context.Background(), cfg)

	if len(models) != 1 {
		t.Fatalf("expected saved VM model to be returned, got %d models", len(models))
	}
	if models[0].ModelPath != modelPath {
		t.Fatalf("expected saved VM model path %q, got %q", modelPath, models[0].ModelPath)
	}
	if models[0].Launch.MainGPUDevice != "CUDA0" {
		t.Fatalf("expected launch device settings to be preserved, got %q", models[0].Launch.MainGPUDevice)
	}
}

func TestMergeNewPreservesAutoDiscoveredVMModelsOnEmptySuccessfulScan(t *testing.T) {
	tempDir := t.TempDir()
	configPath := filepath.Join(tempDir, "profile", "ai", "llms", "app.yaml")
	store, err := NewConfigStore(tempDir, configPath)
	if err != nil {
		t.Fatalf("create config store: %v", err)
	}

	modelPath := "/home/pegpu/.cache/huggingface/hub/models--org--model/snapshots/abc/model.gguf"
	split := 0.5
	if err := store.Update(func(cfg *AppConfig) error {
		cfg.Discovery.Sources = []string{"app"}
		cfg.Models = map[string]ModelConfig{
			"VM-test-model": {
				ID:           "VM-test-model",
				Name:         "VM-test-model",
				Location:     modelLocationVM,
				ModelPath:    modelPath,
				Available:    true,
				DiscoveredAt: nowRFC3339(),
				Metadata: map[string]string{
					modelMetadataDiscovered:      "true",
					modelMetadataDiscoverySource: "vm",
				},
				Launch: LaunchConfig{
					MainGPUDevice: "CUDA0",
					Devices: []DeviceSelection{
						{Name: "CUDA0", Backend: "CUDA", Split: &split},
					},
					ExtraArgs: []string{"--keep-this"},
				},
			},
		}
		return nil
	}); err != nil {
		t.Fatalf("seed config: %v", err)
	}

	fakePEGPU := filepath.Join(tempDir, "pegpu-fake")
	if err := os.WriteFile(fakePEGPU, []byte(`#!/bin/sh
if [ "$1" = "machine" ] && [ "$2" = "llms-runtime" ] && [ "$3" = "list-models-if-running" ]; then
  printf '{"models":[]}\n'
  exit 0
fi
printf 'unexpected command:' >&2
printf ' %s' "$@" >&2
printf '\n' >&2
exit 2
`), 0o755); err != nil {
		t.Fatalf("write fake pegpu: %v", err)
	}
	t.Setenv("PEGPU_CLI_PATH", fakePEGPU)

	runtimeSvc := NewRuntimeService(tempDir, store)
	discovery := NewDiscoveryService(tempDir, runtimeSvc)
	added, err := discovery.MergeNew(store)
	if err != nil {
		t.Fatalf("merge discovery: %v", err)
	}
	if len(added) != 0 {
		t.Fatalf("expected no added models, got %v", added)
	}

	cfg := store.Get()
	id := modelIDForComparableKey(cfg.Models, modelComparableKey(modelLocationVM, modelPath))
	if id == "" {
		t.Fatalf("expected saved VM model to remain after empty successful VM scan")
	}
	got := cfg.Models[id]
	if got.Launch.MainGPUDevice != "CUDA0" {
		t.Fatalf("expected MainGPUDevice to survive, got %q", got.Launch.MainGPUDevice)
	}
	if len(got.Launch.Devices) != 1 || got.Launch.Devices[0].Name != "CUDA0" {
		t.Fatalf("expected device selections to survive, got %#v", got.Launch.Devices)
	}
	if len(got.Launch.ExtraArgs) != 1 || got.Launch.ExtraArgs[0] != "--keep-this" {
		t.Fatalf("expected extra args to survive, got %#v", got.Launch.ExtraArgs)
	}
	if !autoDiscoveredModel(got) {
		t.Fatalf("expected model to remain marked as auto-discovered")
	}
}
