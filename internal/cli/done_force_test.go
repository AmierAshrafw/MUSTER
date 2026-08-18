package cli

import (
	"os"
	"path/filepath"
	"testing"

	"muster/internal/card"
	"muster/internal/store"
)

// writeArtifact drops a file under the repo root so fileExistsAt sees it.
func writeArtifact(t *testing.T, a *App, rel string) {
	t.Helper()
	p := filepath.Join(a.Root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestCompletePassForcesMusterArtifactsOnly(t *testing.T) {
	a, fake, _ := newApp(t)
	seed(t, a, "p-01-x", "impl", "any", "doing")
	tk, err := a.St.Task("p-01-x")
	if err != nil || tk == nil {
		t.Fatalf("seed task missing: %v", err)
	}
	// the task's own live sidecars + one user commit_path
	writeArtifact(t, a, ".muster/cards/p-01-x.notes.md")
	writeArtifact(t, a, ".muster/cards/p-01-x.verify.log")
	writeArtifact(t, a, "src/hello.txt")
	c := &card.Card{ID: "p-01-x", Plan: "p", Type: "impl", CommitPaths: []string{"src/hello.txt"}}

	if code := a.completePass(tk, c, passOpts{DoneCheckPass: true}); code != 0 {
		t.Fatalf("completePass exited %d", code)
	}

	// MUSTER artifacts (result.md written by completePass, plus notes + verify.log) go through AddForce
	forced := flat(fake.Forced)
	for _, want := range []string{".muster/cards/p-01-x.result.md", ".muster/cards/p-01-x.notes.md", ".muster/cards/p-01-x.verify.log"} {
		if !contains(forced, want) {
			t.Fatalf("expected %s force-added; forced=%v", want, forced)
		}
	}
	// user commit_paths must NOT be force-added
	if contains(forced, "src/hello.txt") {
		t.Fatalf("user commit_path must not be force-added; forced=%v", forced)
	}
	if !contains(flat(fake.Added), "src/hello.txt") {
		t.Fatalf("user commit_path must be plain-added; added=%v", fake.Added)
	}
	// the completion commit must carry every path
	if len(fake.Commits) != 1 {
		t.Fatalf("expected one completion commit, got %d", len(fake.Commits))
	}
	for _, want := range []string{".muster/cards/p-01-x.result.md", "src/hello.txt"} {
		if !contains(fake.Commits[0].Paths, want) {
			t.Fatalf("commit missing %s; paths=%v", want, fake.Commits[0].Paths)
		}
	}
	_ = store.Task{}
}

func flat(xs [][]string) []string {
	var out []string
	for _, x := range xs {
		out = append(out, x...)
	}
	return out
}

func contains(xs []string, want string) bool {
	for _, x := range xs {
		if x == want {
			return true
		}
	}
	return false
}
