package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"muster/internal/gitx"
)

// setupDoneFixture: claimed impl task, commit_paths exist on disk, clean fake.
func setupDoneFixture(t *testing.T, cardText string) (*App, *gitx.Fake, *bytes.Buffer) {
	t.Helper()
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", cardText, "inbox")
	claimFor(t, a, out)
	out.Reset()
	wdir := filepath.Join(a.Root, "internal", "w")
	if err := os.MkdirAll(wdir, 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(wdir, "w.go"), []byte("package w\n"), 0o644)
	os.WriteFile(filepath.Join(wdir, "w_test.go"), []byte("package w\n"), 0o644)
	fake.DiffSince = nil
	fake.UntrackedList = []string{"internal/w/w.go", "internal/w/w_test.go"}
	return a, fake, out
}

func TestDoneImplPass(t *testing.T) {
	a, fake, out := setupDoneFixture(t, claimCard)
	if code := a.Dispatch("done", nil); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	s := out.String()
	for _, want := range []string{"Board: run 0", "Done: demo-01-w. Promoted: none. Do not claim another task. Session over."} {
		if !strings.Contains(s, want) {
			t.Fatalf("missing %q:\n%s", want, s)
		}
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "done" {
		t.Fatalf("status: %s", row.Status)
	}
	if len(fake.Commits) != 1 {
		t.Fatalf("commits: %+v", fake.Commits)
	}
	cm := fake.Commits[0]
	if cm.Msg != "muster(demo): done demo-01-w" {
		t.Fatalf("msg: %s", cm.Msg)
	}
	joined := strings.Join(cm.Paths, " ")
	for _, want := range []string{".muster/cards/demo-01-w.result.md", "internal/w/w.go", "internal/w/w_test.go"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("commit paths missing %s: %v", want, cm.Paths)
		}
	}
	if _, err := os.Stat(filepath.Join(a.Dir, "backup.db")); err != nil {
		t.Fatal("backup.db missing after done")
	}
}

func TestDoneRefusesVerdictOnImpl(t *testing.T) {
	a, _, out := setupDoneFixture(t, claimCard)
	if code := a.Dispatch("done", []string{"pass"}); code != 1 {
		t.Fatal("must refuse")
	}
	if !strings.Contains(out.String(), "done takes no verdict on impl/fix tasks.") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestDoneChecksRedRefusal(t *testing.T) {
	a, _, out := setupDoneFixture(t, verifyRedCard)
	if code := a.Dispatch("done", nil); code != 1 {
		t.Fatal("must refuse")
	}
	if !strings.Contains(out.String(), "done-check verify failed") {
		t.Fatalf("out: %s", out.String())
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "doing" {
		t.Fatalf("DB must stay untouched: %s", row.Status)
	}
}

func TestDoneProtectedRefusal(t *testing.T) {
	a, fake, out := setupDoneFixture(t, claimCard)
	fake.DiffSince = []string{"internal/w/w_test.go"} // tracked-and-modified protected path
	if code := a.Dispatch("done", nil); code != 1 {
		t.Fatal("must refuse")
	}
	if !strings.Contains(out.String(), "protected file(s) modified: internal/w/w_test.go") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestDoneScopeRefusal(t *testing.T) {
	a, fake, out := setupDoneFixture(t, claimCard)
	fake.UntrackedList = append(fake.UntrackedList, "stray.txt")
	if code := a.Dispatch("done", nil); code != 1 {
		t.Fatal("must refuse")
	}
	if !strings.Contains(out.String(), "changed outside commit_paths: stray.txt") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestDoneNonDescendantHead(t *testing.T) {
	a, fake, out := setupDoneFixture(t, claimCard)
	fake.AncestorOK = false
	if code := a.Dispatch("done", nil); code != 1 {
		t.Fatal("must refuse")
	}
	if !strings.Contains(out.String(), "not a descendant of head_at_claim") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestDoneCommitFailureLeavesDBUntouched(t *testing.T) {
	a, fake, _ := setupDoneFixture(t, claimCard)
	fake.CommitErr = os.ErrPermission
	if code := a.Dispatch("done", nil); code != 1 {
		t.Fatal("must refuse")
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "doing" {
		t.Fatalf("commit-first violated: %s", row.Status)
	}
}

func TestDoneHookMutationRestages(t *testing.T) {
	a, fake, out := setupDoneFixture(t, claimCard)
	fired := false
	fake.MutateOnCommit = func(f *gitx.Fake) {
		if !fired {
			fired = true
			f.Dirty = []string{"internal/w/w.go"}
		}
	}
	if code := a.Dispatch("done", nil); code != 0 {
		t.Fatalf("hook mutation must be absorbed: %s", out.String())
	}
	if fake.Amends != 1 {
		t.Fatalf("amends: %d", fake.Amends)
	}
}

func TestDoneReviewPassNeedsNotes(t *testing.T) {
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
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "strong"}); code != 0 {
		t.Fatalf("claim: %s", out.String())
	}
	out.Reset()
	if code := a.Dispatch("done", []string{"pass"}); code != 1 {
		t.Fatal("must refuse without notes")
	}
	if !strings.Contains(out.String(), "verdict needs .muster/cards/demo-02-review-w.notes.md") {
		t.Fatalf("out: %s", out.String())
	}
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-02-review-w.notes.md"), []byte("looks right"), 0o644)
	out.Reset()
	if code := a.Dispatch("done", []string{"pass"}); code != 0 {
		t.Fatalf("review pass: %s", out.String())
	}
	vs, _ := a.St.Verdicts("demo-02-review-w")
	if len(vs) != 1 || vs[0].Verdict != "pass" {
		t.Fatalf("verdict rows: %+v", vs)
	}
}
