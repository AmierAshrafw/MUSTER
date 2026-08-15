//go:build process

package process

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInitFreshRepoProcess(t *testing.T) {
	repo := newRepo(t)
	out := mustMuster(t, repo, "init")
	assertContains(t, out, "MUSTER v2 installed", "muster claim -harness claude -tier any")
	subject := strings.TrimSpace(run(t, repo, "git", "log", "-1", "--format=%s"))
	if subject != "muster: init" {
		t.Fatalf("subject: %s", subject)
	}
	for _, rel := range []string{".muster/RUNNER.md", ".muster/.gitignore", ".muster/muster.db"} {
		if _, err := os.Stat(filepath.Join(repo, filepath.FromSlash(rel))); err != nil {
			t.Fatalf("missing %s", rel)
		}
	}
	// db must be ignored
	porcelain := run(t, repo, "git", "status", "--porcelain", "--untracked-files=all")
	if strings.Contains(porcelain, "muster.db") {
		t.Fatalf("db leaked into git status:\n%s", porcelain)
	}
	if out, code := muster(t, repo, nil, "init"); code != 1 || !strings.Contains(out, "already exists") {
		t.Fatalf("second init must refuse: %d\n%s", code, out)
	}
}

func TestInitRefusesLiveV1Process(t *testing.T) {
	dir := t.TempDir()
	BuildV1Board(t, dir, true)
	out, code := muster(t, dir, nil, "init")
	if code != 1 {
		t.Fatalf("code %d:\n%s", code, out)
	}
	assertContains(t, out, "v1 board is live", "tasks/inbox/v1demo-02-b.md", "tasks/staging/v1demo-05-fix-e.md")
	if _, err := os.Stat(filepath.Join(dir, ".muster")); err == nil {
		t.Fatal("half-install")
	}
}

func TestInitDecommissionsDeadV1Process(t *testing.T) {
	dir := t.TempDir()
	BuildV1Board(t, dir, false)
	out := mustMuster(t, dir, "init")
	assertContains(t, out, "v1 decommissioned")
	stub, _ := os.ReadFile(filepath.Join(dir, "tasks", "bin", "claim.ps1"))
	if !strings.Contains(string(stub), "v1 board decommissioned") {
		t.Fatalf("stub: %s", stub)
	}
	claude, _ := os.ReadFile(filepath.Join(dir, "CLAUDE.md"))
	if !strings.Contains(string(claude), ".muster/ is managed by MUSTER v2") {
		t.Fatalf("pointer: %s", claude)
	}
}
