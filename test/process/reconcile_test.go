//go:build process

package process

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReconcileProcess(t *testing.T) {
	repo := newRepo(t)
	mustMuster(t, repo, "init")
	gitRoot := strings.TrimSpace(run(t, repo, "git", "rev-parse", "--show-toplevel"))

	// write both cards and ingest (canonicalized paths) - but DO NOT commit them
	write(t, repo, ".muster/cards/p2-01-hello.md", implCardP2)
	write(t, repo, ".muster/cards/p2-99-int.md", integrationCardP2)
	mustMuster(t, repo, "ingest",
		filepath.Join(gitRoot, ".muster", "cards", "p2-01-hello.md"),
		filepath.Join(gitRoot, ".muster", "cards", "p2-99-int.md"))

	// simulate an abandoned ingest of the integration card: remove it from the
	// worktree; it was never staged or committed -> absent from worktree, index, history
	if err := os.Remove(filepath.Join(repo, ".muster", "cards", "p2-99-int.md")); err != nil {
		t.Fatal(err)
	}

	// dry-run: eligible
	out := mustMuster(t, repo, "reconcile", "p2-99-int")
	assertContains(t, out, "ELIGIBLE")

	// execute: pruned
	out = mustMuster(t, repo, "reconcile", "p2-99-int", "--execute")
	assertContains(t, out, "Reconciled p2-99-int")

	// re-ingest of the retired id refuses (tombstone guard); ingest exits 1
	write(t, repo, ".muster/cards/p2-99-int.md", integrationCardP2)
	out, code := muster(t, repo, nil, "ingest",
		filepath.Join(gitRoot, ".muster", "cards", "p2-99-int.md"))
	if code != 1 {
		t.Fatalf("re-ingest of a retired id must exit 1, got %d:\n%s", code, out)
	}
	if !strings.Contains(out, "reconciled") && !strings.Contains(out, "retired") {
		t.Fatalf("re-ingest refusal should name the retired id:\n%s", out)
	}
}
