package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWriteResultImpl(t *testing.T) {
	a, fake, _ := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "doing")
	if _, err := a.St.DB().Exec(`UPDATE tasks SET head_at_claim='head0',
		claimed_at='2026-01-01T10:00:00Z', claimed_by='claude/any' WHERE id='demo-01-w'`); err != nil {
		t.Fatal(err)
	}
	a.St.AppendEvent("demo-01-w", "claude/any", "claim", "", "2026-01-01T10:00:00Z")
	a.St.AppendEvent("demo-01-w", "claude/any", "attempt", "1", "2026-01-01T10:05:00Z")
	fake.DiffSince = []string{"internal/w/w.go"}
	fake.UntrackedList = []string{"internal/w/w_test.go"}
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-01-w.notes.md"), []byte("one surprise"), 0o644)

	row, _ := a.St.Task("demo-01-w")
	c, _, _ := a.headCard(row, "claude/any")
	rel, err := a.writeResult(row, c, resultOpts{Status: "done", Attempts: -1, DoneCheckPass: true})
	if err != nil {
		t.Fatal(err)
	}
	if rel != ".muster/cards/demo-01-w.result.md" {
		t.Fatalf("rel: %s", rel)
	}
	raw, _ := os.ReadFile(filepath.Join(a.Root, filepath.FromSlash(rel)))
	s := string(raw)
	head, _ := a.St.ChainHead()
	for _, want := range []string{
		"# Result: demo-01-w",
		"- status: done",
		"- head_at_claim: head0",
		"- claimed_at: 2026-01-01T10:00:00Z",
		"- completed_at: 2026-01-02T03:04:05Z",
		"- verify: pass (attempt 1 of 3)",
		"- events_chain_head: " + head,
		"  - internal/w/w.go",
		"  - internal/w/w_test.go",
		"## Surprises",
		"one surprise",
	} {
		if !strings.Contains(s, want) {
			t.Fatalf("result missing %q:\n%s", want, s)
		}
	}
}

func TestWriteResultVariants(t *testing.T) {
	a, fake, _ := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "doing")
	row, _ := a.St.Task("demo-01-w")
	c, _, _ := a.headCard(row, "x")

	rel, _ := a.writeResult(row, c, resultOpts{Status: "done", Attempts: 0, Probe: true, DoneCheckPass: true,
		Surprises: "auto-filed at claim: verify green before execution"})
	raw, _ := os.ReadFile(filepath.Join(a.Root, filepath.FromSlash(rel)))
	if !strings.Contains(string(raw), "verify: pass (claim-probe)") ||
		!strings.Contains(string(raw), "auto-filed at claim") {
		t.Fatalf("probe variant:\n%s", raw)
	}

	rel, _ = a.writeResult(row, c, resultOpts{Status: "failed", Verdict: "fail", Attempts: 0, DoneCheckPass: false})
	raw, _ = os.ReadFile(filepath.Join(a.Root, filepath.FromSlash(rel)))
	if !strings.Contains(string(raw), "verify: FAIL (done-check red - see verify.log)") ||
		!strings.Contains(string(raw), "- verdict: fail") {
		t.Fatalf("red variant:\n%s", raw)
	}

	rel, _ = a.writeResult(row, c, resultOpts{Status: "cycled", Verdict: "fail", Attempts: 2, DoneCheckPass: true, GenSuffix: ".gen1"})
	if rel != ".muster/cards/demo-01-w.gen1.result.md" {
		t.Fatalf("gen path: %s", rel)
	}
}

func TestWriteResultReviewFindings(t *testing.T) {
	a, fake, _ := newApp(t)
	review := strings.NewReplacer(
		"id: demo-01-w", "id: demo-02-review-w",
		"type: impl", "type: review",
		"tier: any", "tier: strong",
		"# demo-01-w: build w", "# demo-02-review-w: review",
	).Replace(claimCard)
	review = strings.Replace(review, "plan: demo", "plan: demo\nreviews: demo-01-w", 1)
	review = strings.Replace(review, "protected:\n  - internal/w/w_test.go\ncommit_paths:\n  - internal/w/w.go\n  - internal/w/w_test.go\n  - internal/w\n", "", 1)
	seedClaimable(t, a, fake, "demo-02-review-w", review, "doing")
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-02-review-w.notes.md"), []byte("finding: gap"), 0o644)
	row, _ := a.St.Task("demo-02-review-w")
	c, _, _ := a.headCard(row, "x")
	rel, _ := a.writeResult(row, c, resultOpts{Status: "done", Verdict: "pass", Attempts: 0, DoneCheckPass: true})
	raw, _ := os.ReadFile(filepath.Join(a.Root, filepath.FromSlash(rel)))
	s := string(raw)
	if !strings.Contains(s, "## Findings") || !strings.Contains(s, "finding: gap") {
		t.Fatalf("review result:\n%s", s)
	}
}

func TestBackupDB(t *testing.T) {
	a, _, _ := newApp(t)
	if err := a.backupDB(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(a.Dir, "backup.db")); err != nil {
		t.Fatal("backup.db missing")
	}
}
