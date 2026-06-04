package main

import (
	"path/filepath"
	"testing"
)

func TestModelAPIRouteSyncSeedsAndMovesRoute(t *testing.T) {
	appData := t.TempDir()
	t.Setenv("VEGPU_APP_DATA_DIR", appData)

	syncer := NewModelAPIRouteSync(".")
	cfg := defaultConfig(".")
	cfg.Server.Port = 9292

	if err := syncer.Sync(cfg); err != nil {
		t.Fatalf("seed route: %v", err)
	}
	portsPath := filepath.Join(appData, "machines", "default", "ports.json")
	first := readTestPortState(t, portsPath)
	if countModelRoute(first, 9292) != 1 {
		t.Fatalf("expected one 9292 model route, got %#v", first.Forwards)
	}

	cfg.Server.Port = 9393
	if err := syncer.Sync(cfg); err != nil {
		t.Fatalf("move route: %v", err)
	}
	second := readTestPortState(t, portsPath)
	if countModelRoute(second, 9292) != 0 {
		t.Fatalf("old 9292 route was not removed: %#v", second.Forwards)
	}
	if countModelRoute(second, 9393) != 1 {
		t.Fatalf("expected one 9393 model route, got %#v", second.Forwards)
	}
}

func readTestPortState(t *testing.T, path string) portForwardState {
	t.Helper()
	var state portForwardState
	if err := readJSONFile(path, &state); err != nil {
		t.Fatalf("read ports: %v", err)
	}
	return state
}

func countModelRoute(state portForwardState, port int) int {
	count := 0
	for _, forward := range state.Forwards {
		if isModelAPIConflict(normalizePortForward(forward), port) &&
			forward.MacPort == port &&
			forward.MacHost == vmnetGatewayHost {
			count++
		}
	}
	return count
}
