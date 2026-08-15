package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"muster/internal/gitx"
)

type fakeAndOut struct {
	fake *gitx.Fake
	out  *bytes.Buffer
}

var reviewCardText = func() string {
	s := strings.NewReplacer(
		"id: demo-01-w", "id: demo-02-review-w",
		"type: impl", "type: review",
		"tier: any", "tier: strong",
		"# demo-01-w: build w", "# demo-02-review-w: review w",
	).Replace(claimCard)
	s = strings.Replace(s, "plan: demo", "plan: demo\nreviews: demo-01-w", 1)
	return strings.Replace(s, "protected:\n  - internal/w/w_test.go\ncommit_paths:\n  - internal/w/w.go\n  - internal/w/w_test.go\n  - internal/w\n", "", 1)
}()

const stagedFixText = `---
id: demo-01-fix-w
plan: demo
type: fix
tier: any
fixes: demo-01-w
depends_on: []
protected:
  - internal/w/w_test.go
commit_paths:
  - internal/w/w.go
  - internal/w
verify:
  - cmd: go version
    expect_contains: go version
---
# demo-01-fix-w: fix w

## Context
ctx

## Steps
1. fix it

## Acceptance
- green
`

// reviewFixture: impl on the board (done), review claimed, notes written.
func reviewFixture(t *testing.T) (*App, *fakeAndOut) {
	t.Helper()
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "done")
	seedClaimable(t, a, fake, "demo-02-review-w", reviewCardText, "inbox")
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "strong"}); code != 0 {
		t.Fatalf("claim: %s", out.String())
	}
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-02-review-w.notes.md"), []byte("finding: broken"), 0o644)
	out.Reset()
	return a, &fakeAndOut{fake, out}
}

func stageFix(t *testing.T, a *App) string {
	t.Helper()
	p := filepath.Join(a.Dir, "staging", "demo-01-fix-w.md")
	if err := os.WriteFile(p, []byte(stagedFixText), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestDoneFailReviewCyclesTheBoard(t *testing.T) {
	a, fx := reviewFixture(t)
	stageFix(t, a)
	code := a.Dispatch("done", []string{"fail", "-reason", "verify asserts the wrong shape"})
	if code != 0 {
		t.Fatalf("code %d: %s", code, fx.out.String())
	}
	if !strings.Contains(fx.out.String(), "Review failed. Fix demo-01-fix1-w queued (generation 1 of 2). Session over.") {
		t.Fatalf("out: %s", fx.out.String())
	}
	// staged file consumed; stamped card landed in cards/
	if _, err := os.Stat(filepath.Join(a.Dir, "staging", "demo-01-fix-w.md")); err == nil {
		t.Fatal("staging file must be consumed")
	}
	raw, err := os.ReadFile(filepath.Join(a.Dir, "cards", "demo-01-fix1-w.md"))
	if err != nil {
		t.Fatal("stamped fix card missing")
	}
	if !strings.Contains(string(raw), "id: demo-01-fix1-w") ||
		!strings.Contains(string(raw), "# demo-01-fix1-w: fix w") ||
		strings.Contains(string(raw), "generation:") {
		t.Fatalf("stamping wrong:\n%s", raw)
	}
	// one reject commit, right grammar
	if len(fx.fake.Commits) != 1 || fx.fake.Commits[0].Msg != "muster(demo): reject demo-01-w gen1" {
		t.Fatalf("commits: %+v", fx.fake.Commits)
	}
	// DB half: fix row inbox gen 1; review backlogged behind it; verdict filed
	fix, _ := a.St.Task("demo-01-fix1-w")
	if fix == nil || fix.Status != "inbox" || fix.Generation != 1 || fix.Fixes != "demo-01-w" {
		t.Fatalf("fix row: %+v", fix)
	}
	rev, _ := a.St.Task("demo-02-review-w")
	if rev.Status != "backlog" {
		t.Fatalf("review status: %s", rev.Status)
	}
	deps, _ := a.St.Deps("demo-02-review-w")
	found := false
	for _, d := range deps {
		if d == "demo-01-fix1-w" {
			found = true
		}
	}
	if !found {
		t.Fatalf("review must re-block on the fix: %v", deps)
	}
	vs, _ := a.St.Verdicts("demo-02-review-w")
	if len(vs) != 1 || vs[0].Verdict != "fail" || vs[0].Reason != "verify asserts the wrong shape" {
		t.Fatalf("verdicts: %+v", vs)
	}
	// gen-suffixed round history exists
	if _, err := os.Stat(filepath.Join(a.Dir, "cards", "demo-02-review-w.gen1.result.md")); err != nil {
		t.Fatal("gen result missing")
	}
}

func TestDoneFailReviewNeedsExactlyOneStagedFix(t *testing.T) {
	a, fx := reviewFixture(t)
	if code := a.Dispatch("done", []string{"fail", "-reason", "r"}); code != 1 {
		t.Fatal("zero staged must refuse")
	}
	if !strings.Contains(fx.out.String(), "exactly one") {
		t.Fatalf("out: %s", fx.out.String())
	}
	stageFix(t, a)
	os.WriteFile(filepath.Join(a.Dir, "staging", "demo-01-fix-w2.md"), []byte(stagedFixText), 0o644)
	fx.out.Reset()
	if code := a.Dispatch("done", []string{"fail", "-reason", "r"}); code != 1 {
		t.Fatal("two staged must refuse")
	}
}

func TestDoneFailReviewFixTargetMismatch(t *testing.T) {
	a, fx := reviewFixture(t)
	bad := strings.ReplaceAll(stagedFixText, "fixes: demo-01-w", "fixes: other-01-x")
	os.WriteFile(filepath.Join(a.Dir, "staging", "demo-01-fix-w.md"), []byte(bad), 0o644)
	if code := a.Dispatch("done", []string{"fail", "-reason", "r"}); code != 1 {
		t.Fatal("mismatch must refuse")
	}
	if !strings.Contains(fx.out.String(), "does not match reviews") {
		t.Fatalf("out: %s", fx.out.String())
	}
	if _, err := os.Stat(filepath.Join(a.Dir, "staging", "demo-01-fix-w.md")); err != nil {
		t.Fatal("file must be left in place")
	}
}

func TestDoneFailReviewGenerationCap(t *testing.T) {
	a, fx := reviewFixture(t)
	// two landed generations already on the board
	for _, id := range []string{"demo-01-fix1-w", "demo-01-fix2-w"} {
		if _, err := a.St.DB().Exec(`INSERT INTO tasks(id, plan, seq, type, tier, status, card_path, frontmatter_sha, fixes, generation)
			VALUES (?, 'demo', 1, 'fix', 'any', 'done', ?, 'x', 'demo-01-w', 1)`, id, ".muster/cards/"+id+".md"); err != nil {
			t.Fatal(err)
		}
	}
	stageFix(t, a)
	if code := a.Dispatch("done", []string{"fail", "-reason", "r"}); code != 3 {
		t.Fatalf("cap must exit 3: %s", fx.out.String())
	}
	if !strings.Contains(fx.out.String(), "Review cap hit (2 fix generations). demo-01-w chain needs a human. Session over.") {
		t.Fatalf("out: %s", fx.out.String())
	}
	rev, _ := a.St.Task("demo-02-review-w")
	if rev.Status != "failed" {
		t.Fatalf("review status: %s", rev.Status)
	}
	if _, err := os.Stat(filepath.Join(a.Dir, "staging", "demo-01-fix-w.md")); err == nil {
		t.Fatal("staged fix must be removed at the cap")
	}
}

func TestDoneFailReviewCrashResume(t *testing.T) {
	a, fx := reviewFixture(t)
	// simulate: reject commit landed (stamped card on disk), DB flip lost
	stamped := strings.ReplaceAll(stagedFixText, "demo-01-fix-w", "demo-01-fix1-w")
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-01-fix1-w.md"), []byte(stamped), 0o644)
	code := a.Dispatch("done", []string{"fail", "-reason", "resume"})
	if code != 0 {
		t.Fatalf("resume must complete the DB half: %s", fx.out.String())
	}
	if !strings.Contains(fx.out.String(), "Resumed crashed done fail") {
		t.Fatalf("out: %s", fx.out.String())
	}
	fix, _ := a.St.Task("demo-01-fix1-w")
	if fix == nil || fix.Status != "inbox" || fix.Generation != 1 {
		t.Fatalf("fix row: %+v", fix)
	}
	rev, _ := a.St.Task("demo-02-review-w")
	if rev.Status != "backlog" {
		t.Fatalf("review status: %s", rev.Status)
	}
	if len(fx.fake.Commits) != 0 {
		t.Fatal("resume must not commit again")
	}
}
