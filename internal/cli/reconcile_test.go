package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// orphan seeds a pristine abandoned-ingest orphan: a DB row whose card is
// absent from worktree, index, and history (the Fake defaults supply absence).
func orphan(t *testing.T, a *App, id string) {
	t.Helper()
	seed(t, a, id, "impl", "any", "backlog")
}

func TestReconcileDryRunEligible(t *testing.T) {
	a, _, out := newApp(t)
	orphan(t, a, "p-01-a")
	if code := a.Dispatch("reconcile", []string{"p-01-a"}); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	s := out.String()
	if !strings.Contains(s, "ELIGIBLE") || !strings.Contains(s, "--execute") {
		t.Fatalf("dry-run output: %s", s)
	}
	// dry-run must NOT mutate
	if row, _ := a.St.Task("p-01-a"); row == nil {
		t.Fatal("dry-run must not delete the row")
	}
}

func TestReconcileExecutePrunes(t *testing.T) {
	a, _, out := newApp(t)
	orphan(t, a, "p-01-a")
	if code := a.Dispatch("reconcile", []string{"p-01-a", "--execute", "--reason", "leftover"}); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	if row, _ := a.St.Task("p-01-a"); row != nil {
		t.Fatal("row must be pruned")
	}
	if !strings.Contains(out.String(), "Reconciled p-01-a") {
		t.Fatalf("out: %s", out.String())
	}
	// idempotent re-run
	out.Reset()
	if code := a.Dispatch("reconcile", []string{"p-01-a", "--execute"}); code != 0 {
		t.Fatalf("idempotent code %d: %s", code, out.String())
	}
	if !strings.Contains(out.String(), "already reconciled") {
		t.Fatalf("idempotent out: %s", out.String())
	}
}

func TestReconcileRefusesNonOrphan(t *testing.T) {
	a, fake, out := newApp(t)
	orphan(t, a, "p-01-a")
	// card committed => has history => ineligible
	fake.HistorySHAs = map[string][]string{".muster/cards/p-01-a.md": {"abc123"}}
	if code := a.Dispatch("reconcile", []string{"p-01-a", "--execute"}); code != 1 {
		t.Fatalf("must refuse, code %d: %s", code, out.String())
	}
	if row, _ := a.St.Task("p-01-a"); row == nil {
		t.Fatal("refused reconcile must not prune")
	}
	if !strings.Contains(out.String(), "git history") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestReconcileUnknownID(t *testing.T) {
	a, _, out := newApp(t)
	if code := a.Dispatch("reconcile", []string{"nope"}); code != 1 {
		t.Fatalf("code %d", code)
	}
	if !strings.Contains(out.String(), "MUSTER refuse:") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestReconcileRefusesWorktreePresent(t *testing.T) {
	a, _, out := newApp(t)
	orphan(t, a, "p-01-a")
	// card is present in the worktree -> not an abandoned ingest
	if err := os.WriteFile(filepath.Join(a.Dir, "cards", "p-01-a.md"), []byte("body"), 0o644); err != nil {
		t.Fatal(err)
	}
	if code := a.Dispatch("reconcile", []string{"p-01-a", "--execute"}); code != 1 {
		t.Fatalf("worktree-present must refuse, code %d: %s", code, out.String())
	}
	if row, _ := a.St.Task("p-01-a"); row == nil {
		t.Fatal("refused reconcile must not prune")
	}
	if !strings.Contains(out.String(), "worktree") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestReconcileRefusesIndexPresent(t *testing.T) {
	a, fake, out := newApp(t)
	orphan(t, a, "p-01-a")
	// card is staged in the index (absent from worktree + history)
	fake.IndexFiles = map[string]bool{".muster/cards/p-01-a.md": true}
	if code := a.Dispatch("reconcile", []string{"p-01-a", "--execute"}); code != 1 {
		t.Fatalf("index-present must refuse, code %d: %s", code, out.String())
	}
	if row, _ := a.St.Task("p-01-a"); row == nil {
		t.Fatal("refused reconcile must not prune")
	}
	if !strings.Contains(out.String(), "index") {
		t.Fatalf("out: %s", out.String())
	}
}
