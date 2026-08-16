//go:build benchsmoke

// internal/bench/smoke_test.go
package bench

import (
	"path/filepath"
	"testing"
)

func TestSmokeFullLoopN3(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(t.TempDir(), "muster.exe")
	if _, err := BuildMuster(repoRoot, exe); err != nil {
		t.Fatalf("build: %v", err)
	}
	res, err := RunFullLoopOnce(exe, 1, 3)
	if err != nil {
		t.Fatalf("full loop error: %v", err)
	}
	if res.Status != "ok" {
		t.Fatalf("full loop status = %q, want ok", res.Status)
	}
	if res.WallNS <= 0 {
		t.Fatalf("wall time not recorded")
	}
	// N=3 -> 2 impl + 1 integration = 3 tasks, 2 verifier spawns each.
	if res.VerifierSpawns != 6 {
		t.Fatalf("verifier spawns = %d, want 6", res.VerifierSpawns)
	}
}
