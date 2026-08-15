package cli

import (
	"strings"
	"testing"

	"muster/internal/card"
	"muster/internal/gitx"
	"muster/internal/store"
)

const claimCard = `---
id: demo-01-w
plan: demo
type: impl
tier: any
depends_on: []
protected:
  - internal/w/w_test.go
commit_paths:
  - internal/w/w.go
  - internal/w/w_test.go
  - internal/w
verify:
  - cmd: go version
    expect_contains: go version
---
# demo-01-w: build w

## Context
ctx

## Steps
1. build

## Acceptance
- green
`

// seedClaimable inserts a row whose stored sha matches the HEAD card text and
// registers the card at the fake's HEAD.
func seedClaimable(t *testing.T, a *App, fake *gitx.Fake, id, text, status string) {
	t.Helper()
	c, errs := card.Parse(text, false)
	if len(errs) > 0 {
		t.Fatalf("fixture card invalid: %v", errs)
	}
	rel := ".muster/cards/" + id + ".md"
	err := a.St.Ingest([]store.IngestTask{{Task: store.Task{
		ID: id, Plan: c.Plan, Seq: c.Seq, Type: c.Type, Tier: c.Tier, Harness: c.Harness,
		CardPath: rel, FrontmatterSHA: c.FrontmatterSHA, Reviews: c.Reviews, Fixes: c.Fixes,
	}, Deps: c.DependsOn}}, "shard", "2026-01-01T00:00:00Z")
	if err != nil {
		t.Fatal(err)
	}
	if status != "backlog" {
		if _, err := a.St.DB().Exec(`UPDATE tasks SET status=? WHERE id=?`, status, id); err != nil {
			t.Fatal(err)
		}
	}
	fake.HeadFiles[rel] = text
}

func TestClaimRequiresIdentityFlags(t *testing.T) {
	a, _, out := newApp(t)
	if code := a.Dispatch("claim", nil); code != 1 {
		t.Fatalf("code %d", code)
	}
	if !strings.Contains(out.String(), "claim requires -harness") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestClaimHappyPath(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"})
	if code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	s := out.String()
	for _, want := range []string{"MUSTER status @", "# demo-01-w: build w", "Claimed demo-01-w. Follow .muster/RUNNER.md."} {
		if !strings.Contains(s, want) {
			t.Fatalf("missing %q:\n%s", want, s)
		}
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "doing" || row.HeadAtClaim != "head0" || row.ClaimedBy != "claude/any" {
		t.Fatalf("row: %+v", row)
	}
}

func TestClaimPromotesFirst(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "backlog") // dep-free backlog
	code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"})
	if code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "doing" {
		t.Fatalf("promote-then-claim failed: %s", row.Status)
	}
}

func TestClaimTierPinning(t *testing.T) {
	a, fake, out := newApp(t)
	strongCard := strings.Replace(claimCard, "tier: any", "tier: strong", 1)
	seedClaimable(t, a, fake, "demo-01-w", strongCard, "inbox")
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"}); code != 1 {
		t.Fatalf("any session must not take strong task: %d %s", code, out.String())
	}
	if !strings.Contains(out.String(), "nothing to claim for claude/any") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestClaimStatusBeforeRefusal(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "doing")
	if _, err := a.St.DB().Exec(`UPDATE tasks SET claimed_at='2026-01-02T02:04:05Z' WHERE id='demo-01-w'`); err != nil {
		t.Fatal(err)
	}
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"}); code != 1 {
		t.Fatal("must refuse")
	}
	s := out.String()
	iStatus := strings.Index(s, "MUSTER status @")
	iRefuse := strings.Index(s, "MUSTER refuse:")
	if iStatus < 0 || iRefuse < 0 || iStatus > iRefuse {
		t.Fatalf("status block must print before the refusal (CM-ORDER):\n%s", s)
	}
	if !strings.Contains(s, "doing occupied by demo-01-w") {
		t.Fatalf("out: %s", s)
	}
}

func TestClaimDirtyTreeScope(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	fake.Dirty = []string{"stray.txt"}
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"}); code != 1 {
		t.Fatal("must refuse")
	}
	if !strings.Contains(out.String(), "working tree dirty outside demo-01-w's commit_paths: stray.txt") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestClaimToleratesInScopeDirt(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	fake.Dirty = []string{"internal/w/w.go", ".muster/cards/demo-01-w.notes.md"}
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"}); code != 0 {
		t.Fatalf("in-scope dirt must not refuse: %s", out.String())
	}
}

func TestClaimCardNotAtHead(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	delete(fake.HeadFiles, ".muster/cards/demo-01-w.md")
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"}); code != 1 {
		t.Fatal("must refuse")
	}
	if !strings.Contains(out.String(), "not committed at HEAD") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestClaimShaMismatchWarns(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	if _, err := a.St.DB().Exec(`UPDATE tasks SET frontmatter_sha='stale' WHERE id='demo-01-w'`); err != nil {
		t.Fatal(err)
	}
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"}); code != 0 {
		t.Fatalf("mismatch is a warning, not a refusal: %s", out.String())
	}
	if !strings.Contains(out.String(), "MUSTER warn: demo-01-w frontmatter differs") {
		t.Fatalf("out: %s", out.String())
	}
	evs, _ := a.St.Events("demo-01-w")
	found := false
	for _, e := range evs {
		if e.Verb == "warn" {
			found = true
		}
	}
	if !found {
		t.Fatal("warn event missing")
	}
}

func TestReconcilerHealsCommittedDone(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "doing")
	if _, err := a.St.DB().Exec(`UPDATE tasks SET head_at_claim='head0', claimed_by='claude/any' WHERE id='demo-01-w'`); err != nil {
		t.Fatal(err)
	}
	fake.GrepSHAs = []string{"deadbeef"} // the done commit exists in git
	// nothing else claimable: claim reconciles, then refuses on empty inbox
	a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"})
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "done" {
		t.Fatalf("reconciler must heal: %s", row.Status)
	}
	if !strings.Contains(out.String(), "Reconciled demo-01-w") {
		t.Fatalf("out: %s", out.String())
	}
}
