package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRedoFromDoingAndFailed(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "doing")
	if code := a.Dispatch("redo", []string{"demo-01-w"}); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "inbox" || row.ClaimedAt != "" {
		t.Fatalf("row: %+v", row)
	}
	if !strings.Contains(out.String(), "Redo: demo-01-w") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestRedoRefusesWrongStatus(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "done")
	if code := a.Dispatch("redo", []string{"demo-01-w"}); code != 1 {
		t.Fatal("must refuse")
	}
	if !strings.Contains(out.String(), "MUSTER refuse:") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestFailVerb(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	if code := a.Dispatch("fail", []string{"demo-01-w"}); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "failed" {
		t.Fatalf("status: %s", row.Status)
	}
}

func TestReimportRehashesAndRewiresDeps(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "done")
	seedClaimable(t, a, fake, "demo-02-x", strings.NewReplacer("demo-01-w", "demo-02-x").Replace(claimCard), "backlog")
	// deliberate edit: demo-02-x now depends on demo-01-w and goes strong
	edited := strings.NewReplacer("demo-01-w", "demo-02-x").Replace(claimCard)
	edited = strings.Replace(edited, "tier: any", "tier: strong", 1)
	edited = strings.Replace(edited, "depends_on: []", "depends_on:\n  - demo-01-w", 1)
	if err := os.WriteFile(filepath.Join(a.Dir, "cards", "demo-02-x.md"), []byte(edited), 0o644); err != nil {
		t.Fatal(err)
	}
	if code := a.Dispatch("reimport", []string{"demo-02-x"}); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	row, _ := a.St.Task("demo-02-x")
	if row.Tier != "strong" {
		t.Fatalf("tier not refreshed: %+v", row)
	}
	deps, _ := a.St.Deps("demo-02-x")
	if len(deps) != 1 || deps[0] != "demo-01-w" {
		t.Fatalf("deps: %v", deps)
	}
	evs, _ := a.St.Events("demo-02-x")
	last := evs[len(evs)-1]
	if last.Verb != "reimport" {
		t.Fatalf("event: %+v", last)
	}
}

func TestReimportRefusesDoingAndLintFailures(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "doing")
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-01-w.md"), []byte(claimCard), 0o644)
	if code := a.Dispatch("reimport", []string{"demo-01-w"}); code != 1 {
		t.Fatal("doing must refuse")
	}
	if !strings.Contains(out.String(), "claimed task") {
		t.Fatalf("out: %s", out.String())
	}
	a2, fake2, out2 := newApp(t)
	_ = fake2
	seedClaimable(t, a2, fake2, "demo-01-w", claimCard, "backlog")
	bad := strings.Replace(claimCard, "## Context\nctx", "## Context\nTBD", 1)
	os.WriteFile(filepath.Join(a2.Dir, "cards", "demo-01-w.md"), []byte(bad), 0o644)
	if code := a2.Dispatch("reimport", []string{"demo-01-w"}); code != 1 {
		t.Fatal("lint failure must refuse")
	}
	if !strings.Contains(out2.String(), "LINT FAIL") {
		t.Fatalf("out: %s", out2.String())
	}
}
