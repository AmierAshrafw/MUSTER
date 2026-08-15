package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestProbeAutoFilesFinishedWork(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	// prior-claim evidence: a claim event from a crashed predecessor session
	a.St.AppendEvent("demo-01-w", "claude/any", "claim", "", "2026-01-01T09:00:00Z")
	// the finished work sits in the tree
	wdir := filepath.Join(a.Root, "internal", "w")
	os.MkdirAll(wdir, 0o755)
	os.WriteFile(filepath.Join(wdir, "w.go"), []byte("package w\n"), 0o644)
	os.WriteFile(filepath.Join(wdir, "w_test.go"), []byte("package w\n"), 0o644)
	fake.UntrackedList = []string{"internal/w/w.go", "internal/w/w_test.go"}

	code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"})
	if code != 1 { // auto-file, then loop finds nothing else: refusal ends the run
		t.Fatalf("code %d: %s", code, out.String())
	}
	s := out.String()
	if !strings.Contains(s, "Auto-filed demo-01-w - a crashed predecessor already finished it (claim-probe green).") {
		t.Fatalf("out: %s", s)
	}
	if !strings.Contains(s, "nothing to claim for claude/any") {
		t.Fatalf("loop must continue to the empty-inbox refusal:\n%s", s)
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "done" {
		t.Fatalf("status: %s", row.Status)
	}
	if len(fake.Commits) != 1 || fake.Commits[0].Msg != "muster(demo): done demo-01-w" {
		t.Fatalf("commits: %+v", fake.Commits)
	}
	raw, _ := os.ReadFile(filepath.Join(a.Dir, "cards", "demo-01-w.result.md"))
	if !strings.Contains(string(raw), "verify: pass (claim-probe)") ||
		!strings.Contains(string(raw), "auto-filed at claim") {
		t.Fatalf("result: %s", raw)
	}
}

func TestProbeSkipsFirstClaims(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"}); code != 0 {
		t.Fatalf("first claim must hand over normally: %s", out.String())
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "doing" {
		t.Fatalf("no prior evidence must mean no auto-file: %s", row.Status)
	}
}

func TestProbeNeverTouchesReviewTasks(t *testing.T) {
	a, fake, out := newApp(t)
	review := strings.NewReplacer(
		"id: demo-01-w", "id: demo-02-review-w",
		"type: impl", "type: review",
		"tier: any", "tier: strong",
		"# demo-01-w: build w", "# demo-02-review-w: review",
	).Replace(claimCard)
	review = strings.Replace(review, "plan: demo", "plan: demo\nreviews: demo-01-w", 1)
	review = strings.Replace(review, "protected:\n  - internal/w/w_test.go\ncommit_paths:\n  - internal/w/w.go\n  - internal/w/w_test.go\n  - internal/w\n", "", 1)
	seedClaimable(t, a, fake, "demo-02-review-w", review, "inbox")
	a.St.AppendEvent("demo-02-review-w", "claude/strong", "claim", "", "2026-01-01T09:00:00Z")
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "strong"}); code != 0 {
		t.Fatalf("review with prior claim must still hand over: %s", out.String())
	}
	row, _ := a.St.Task("demo-02-review-w")
	if row.Status != "doing" {
		t.Fatalf("review must never auto-file: %s", row.Status)
	}
}

func TestProbeRedVerifyHandsOver(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", verifyRedCard, "inbox")
	a.St.AppendEvent("demo-01-w", "claude/any", "claim", "", "2026-01-01T09:00:00Z")
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"}); code != 0 {
		t.Fatalf("red probe must hand over for a redo: %s", out.String())
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "doing" {
		t.Fatalf("status: %s", row.Status)
	}
}
