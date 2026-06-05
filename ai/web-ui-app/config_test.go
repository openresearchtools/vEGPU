package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNormalizeConfigPrefixesModelKeysByPath(t *testing.T) {
	macPath := writeTestModelFile(t, "qwen-mac.gguf")
	vmPath := "/home/vegpu/.cache/huggingface/hub/models--org--qwen/snapshots/abc/qwen-vm.gguf"
	cfg := AppConfig{
		Models: map[string]ModelConfig{
			"old-mac": {
				Name:      "Qwen",
				Location:  modelLocationVM,
				ModelPath: macPath,
			},
			"old-vm": {
				Name:      "Qwen",
				Location:  modelLocationMac,
				ModelPath: vmPath,
			},
		},
	}

	normalizeConfig(&cfg, t.TempDir())

	mac, ok := cfg.Models["MAC-qwen"]
	if !ok {
		t.Fatalf("expected MAC-qwen key, got %#v", keysOfModels(cfg.Models))
	}
	if mac.ID != "MAC-qwen" || mac.Name != "MAC-qwen" || mac.Location != modelLocationMac {
		t.Fatalf("unexpected mac model after normalization: %#v", mac)
	}
	vm, ok := cfg.Models["VM-qwen"]
	if !ok {
		t.Fatalf("expected VM-qwen key, got %#v", keysOfModels(cfg.Models))
	}
	if vm.ID != "VM-qwen" || vm.Name != "VM-qwen" || vm.Location != modelLocationVM {
		t.Fatalf("unexpected vm model after normalization: %#v", vm)
	}
}

func TestNormalizeConfigKeepsExistingPrefixWithoutDoubling(t *testing.T) {
	macPath := writeTestModelFile(t, "prefixed.gguf")
	cfg := AppConfig{
		Models: map[string]ModelConfig{
			"MAC-prefixed": {
				Name:      "MAC-prefixed",
				Location:  modelLocationMac,
				ModelPath: macPath,
			},
		},
	}

	normalizeConfig(&cfg, t.TempDir())

	if _, ok := cfg.Models["MAC-prefixed"]; !ok {
		t.Fatalf("expected MAC-prefixed key, got %#v", keysOfModels(cfg.Models))
	}
	if _, ok := cfg.Models["MAC-mac-prefixed"]; ok {
		t.Fatalf("model key was double-prefixed: %#v", keysOfModels(cfg.Models))
	}
}

func TestNormalizeConfigAddsSourceSuffixOnSameLocationCollision(t *testing.T) {
	hfPath := writeTestModelFile(t, filepath.Join("hf", "qwen.gguf"))
	lmPath := writeTestModelFile(t, filepath.Join("lm", "qwen.gguf"))
	cfg := AppConfig{
		Models: map[string]ModelConfig{
			"hf-old": {
				Name:      "Qwen",
				Provider:  "huggingface",
				Location:  modelLocationMac,
				ModelPath: hfPath,
			},
			"lm-old": {
				Name:      "Qwen",
				Provider:  "lmstudio",
				Location:  modelLocationMac,
				ModelPath: lmPath,
			},
		},
	}

	normalizeConfig(&cfg, t.TempDir())

	if _, ok := cfg.Models["MAC-qwen-hf"]; !ok {
		t.Fatalf("expected MAC-qwen-hf key, got %#v", keysOfModels(cfg.Models))
	}
	if _, ok := cfg.Models["MAC-qwen-lm"]; !ok {
		t.Fatalf("expected MAC-qwen-lm key, got %#v", keysOfModels(cfg.Models))
	}
	if _, ok := cfg.Models["MAC-qwen"]; ok {
		t.Fatalf("collision kept unsuffixed key: %#v", keysOfModels(cfg.Models))
	}
}

func writeTestModelFile(t *testing.T, name string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("test"), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func keysOfModels(models map[string]ModelConfig) []string {
	keys := make([]string, 0, len(models))
	for key := range models {
		keys = append(keys, key)
	}
	return keys
}
