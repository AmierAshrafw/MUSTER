package card

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeCard writes text to dir/name and returns the path.
func writeCard(t *testing.T, dir, name, text string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func implCard(id, extra string) string {
	// commit_paths carries the bare `internal/w` entry so the verify token
	// passes lint check 5 - the exact convention the sharding notes mandate.
	return `---
id: ` + id + `
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
` + extra + `verify:
  - cmd: go test internal/w
    expect_exit: 0
---
# ` + id + `: title

## Context
ctx

## Steps
1. do the thing

## Acceptance
- it works
`
}

func integrationCard(id string, deps []string) string {
	depBlock := "depends_on:\n"
	for _, d := range deps {
		depBlock += "  - " + d + "\n"
	}
	return `---
id: ` + id + `
plan: demo
type: integration
tier: strong
` + depBlock + `verify:
  - cmd: go vet all
    expect_exit: 0
---
# ` + id + `: integrate

## Context
ctx

## Steps
1. run the suite

## Acceptance
- green
`
}

func noExisting(string) bool { return false }

func lintBatch(t *testing.T, dir string, texts map[string]string, exists func(string) bool, mode Mode) []string {
	t.Helper()
	var paths []string
	for name, text := range texts {
		paths = append(paths, writeCard(t, dir, name, text))
	}
	return Lint(paths, exists, mode)
}

func wantFinding(t *testing.T, findings []string, frag string) {
	t.Helper()
	for _, f := range findings {
		if strings.Contains(f, frag) {
			return
		}
	}
	t.Fatalf("findings %v lack %q", findings, frag)
}

func TestWellFormedBatchPasses(t *testing.T) {
	dir := t.TempDir()
	f := lintBatch(t, dir, map[string]string{
		"demo-01-w.md":   implCard("demo-01-w", ""),
		"demo-99-int.md": integrationCard("demo-99-int", []string{"demo-01-w"}),
	}, noExisting, Full)
	if len(f) != 0 {
		t.Fatalf("findings: %v", f)
	}
}

func TestIDStemAndPattern(t *testing.T) {
	dir := t.TempDir()
	f := lintBatch(t, dir, map[string]string{"other-name.md": implCard("demo-01-w", "")}, noExisting, Single)
	wantFinding(t, f, "does not equal filename stem")
	f = lintBatch(t, dir, map[string]string{"demow.md": implCard("demow", "")}, noExisting, Single)
	wantFinding(t, f, "does not match the task pattern")
}

func TestCollisionAgainstBoard(t *testing.T) {
	dir := t.TempDir()
	f := lintBatch(t, dir, map[string]string{"demo-01-w.md": implCard("demo-01-w", "")},
		func(id string) bool { return id == "demo-01-w" }, Single)
	wantFinding(t, f, "already on the board")
}

func TestDepExistsNowhere(t *testing.T) {
	dir := t.TempDir()
	text := strings.Replace(implCard("demo-01-w", ""), "depends_on: []", "depends_on:\n  - ghost-01-x", 1)
	f := lintBatch(t, dir, map[string]string{"demo-01-w.md": text}, noExisting, Single)
	wantFinding(t, f, "depends_on 'ghost-01-x' exists nowhere")
}

func TestVerifyCmdChecks(t *testing.T) {
	dir := t.TempDir()
	meta := strings.Replace(implCard("demo-01-w", ""), "cmd: go test internal/w", "cmd: go test internal/w | sort", 1)
	f := lintBatch(t, dir, map[string]string{"demo-01-w.md": meta}, noExisting, Single)
	wantFinding(t, f, "shell metacharacters")

	net := strings.Replace(implCard("demo-01-w", ""), "cmd: go test internal/w", "cmd: curl example.com", 1)
	f = lintBatch(t, dir, map[string]string{"demo-01-w.md": net}, noExisting, Single)
	wantFinding(t, f, "needs network but harness is not claude")

	// harness: claude exempts the network check
	netOK := strings.Replace(net, "plan: demo\n", "plan: demo\nharness: claude\n", 1)
	f = lintBatch(t, dir, map[string]string{"demo-01-w.md": netOK}, noExisting, Single)
	for _, x := range f {
		if strings.Contains(x, "needs network") {
			t.Fatalf("claude harness must exempt: %v", f)
		}
	}

	unlisted := strings.Replace(implCard("demo-01-w", ""), "cmd: go test internal/w", "cmd: go test other/pkg", 1)
	f = lintBatch(t, dir, map[string]string{"demo-01-w.md": unlisted}, noExisting, Single)
	wantFinding(t, f, "verify path 'other/pkg' not in protected or commit_paths")
}

func TestTestPathOnlyInCommitPaths(t *testing.T) {
	dir := t.TempDir()
	// verify cmd names the test file itself; protected is empty so the test
	// file resolves only through commit_paths = executor-writable grader (M2)
	text := strings.NewReplacer(
		"protected:\n  - internal/w/w_test.go", "protected: []",
		"cmd: go test internal/w", "cmd: go test internal/w/w_test.go",
	).Replace(implCard("demo-01-w", ""))
	f := lintBatch(t, dir, map[string]string{"demo-01-w.md": text}, noExisting, Single)
	wantFinding(t, f, "only in commit_paths - executor-writable grader")
	// and check 14: runner with empty protected
	wantFinding(t, f, "verify runs a test runner but protected is empty")
}

func TestProseChecks(t *testing.T) {
	dir := t.TempDir()
	cases := []struct{ orig, repl, frag string }{
		{"## Context\nctx", "## Context\nTBD", "placeholder text"},
		{"## Steps\n1. do the thing", "## Steps\n1. do the thing as appropriate", "judgment language in Steps"},
		{"## Context\nctx\n", "## Context\nsee docs/plan.md\n", "un-inlined reference"},
	}
	for _, tc := range cases {
		text := strings.Replace(implCard("demo-01-w", ""), tc.orig, tc.repl, 1)
		f := lintBatch(t, dir, map[string]string{"demo-01-w.md": text}, noExisting, Single)
		wantFinding(t, f, tc.frag)
	}
}

func TestHeadingOrderAndSizeCap(t *testing.T) {
	dir := t.TempDir()
	noSteps := strings.Replace(implCard("demo-01-w", ""), "## Steps", "## Stuff", 1)
	f := lintBatch(t, dir, map[string]string{"demo-01-w.md": noSteps}, noExisting, Single)
	wantFinding(t, f, "body headings missing or out of order")

	big := implCard("demo-01-w", "") + strings.Repeat("filler line\n", 300)
	f = lintBatch(t, dir, map[string]string{"demo-01-w.md": big}, noExisting, Single)
	wantFinding(t, f, "over the size cap")
}

func TestBatchChecksFullMode(t *testing.T) {
	dir := t.TempDir()
	// no integration task
	f := lintBatch(t, dir, map[string]string{"demo-01-w.md": implCard("demo-01-w", "")}, noExisting, Full)
	wantFinding(t, f, "expected exactly 1 integration task, found 0")
	// integration missing a batch dep
	f = lintBatch(t, dir, map[string]string{
		"demo-01-w.md":   implCard("demo-01-w", ""),
		"demo-02-x.md":   strings.NewReplacer("demo-01-w", "demo-02-x").Replace(implCard("demo-01-w", "")),
		"demo-99-int.md": integrationCard("demo-99-int", []string{"demo-01-w"}),
	}, noExisting, Full)
	wantFinding(t, f, "integration depends_on missing 'demo-02-x'")
}

func TestReviewWiring(t *testing.T) {
	dir := t.TempDir()
	review := `---
id: demo-02-review-w
plan: demo
type: review
tier: strong
reviews: demo-01-w
depends_on:
  - demo-01-w
verify:
  - cmd: go vet all
    expect_exit: 0
---
# demo-02-review-w: review

## Context
ctx

## Steps
1. judge

## Acceptance
- verdict filed
`
	f := lintBatch(t, dir, map[string]string{
		"demo-01-w.md":        implCard("demo-01-w", ""),
		"demo-02-review-w.md": review,
		"demo-99-int.md":      integrationCard("demo-99-int", []string{"demo-01-w", "demo-02-review-w"}),
	}, noExisting, Full)
	if len(f) != 0 {
		t.Fatalf("wired review must pass: %v", f)
	}
	broken := strings.Replace(review, "depends_on:\n  - demo-01-w", "depends_on: []", 1)
	f = lintBatch(t, dir, map[string]string{
		"demo-01-w.md":        implCard("demo-01-w", ""),
		"demo-02-review-w.md": broken,
		"demo-99-int.md":      integrationCard("demo-99-int", []string{"demo-01-w", "demo-02-review-w"}),
	}, noExisting, Full)
	wantFinding(t, f, "review depends_on must include its reviews id")
}

func TestLiteMode(t *testing.T) {
	dir := t.TempDir()
	fix := `---
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
  - cmd: go test internal/w
    expect_exit: 0
---
# demo-01-fix-w: fix

## Context
ctx

## Steps
1. fix it

## Acceptance
- green
`
	// lite skips batch checks and accepts the fix filename pattern; the fixes target exists on the board
	f := lintBatch(t, dir, map[string]string{"demo-01-fix-w.md": fix},
		func(id string) bool { return id == "demo-01-w" }, Lite)
	if len(f) != 0 {
		t.Fatalf("staged fix must pass lite: %v", f)
	}
	// lite enforces the fix filename pattern
	notFix := strings.NewReplacer("demo-01-fix-w", "demo-01-w", "type: fix\n", "type: impl\n", "fixes: demo-01-w\n", "").Replace(fix)
	f = lintBatch(t, dir, map[string]string{"demo-01-w.md": notFix}, noExisting, Lite)
	wantFinding(t, f, "does not match the task pattern")
}
