package card

import (
	"strings"
	"testing"
)

const goodImpl = `---
id: demo-01-widget
plan: demo
type: impl
tier: any
depends_on: []
protected:
  - tests/widget_test.go
commit_paths:
  - src/widget.go
  - tests/widget_test.go
verify:
  - cmd: go test ./tests
    expect_exit: 0
---
# demo-01-widget: build the widget

## Context
ctx

## Steps
1. do

## Acceptance
- done
`

func parseOK(t *testing.T, text string) *Card {
	t.Helper()
	c, errs := Parse(text, false)
	if len(errs) > 0 {
		t.Fatalf("unexpected errors: %v", errs)
	}
	return c
}

func TestParseGoodImpl(t *testing.T) {
	c := parseOK(t, goodImpl)
	if c.ID != "demo-01-widget" || c.Plan != "demo" || c.Type != "impl" || c.Tier != "any" {
		t.Fatalf("fields: %+v", c)
	}
	if c.Seq != 1 {
		t.Fatalf("seq: %d", c.Seq)
	}
	if len(c.DependsOn) != 0 || len(c.Protected) != 1 || len(c.CommitPaths) != 2 {
		t.Fatalf("lists: %+v", c)
	}
	if len(c.Verify) != 1 || c.Verify[0].Cmd != "go test ./tests" || c.Verify[0].ExpectExit != "0" {
		t.Fatalf("verify: %+v", c.Verify)
	}
	if !strings.Contains(c.Body, "## Steps") {
		t.Fatalf("body lost")
	}
	if len(c.FrontmatterSHA) != 64 {
		t.Fatalf("sha: %q", c.FrontmatterSHA)
	}
}

func TestShaCoversFrontmatterOnly(t *testing.T) {
	a := parseOK(t, goodImpl)
	b := parseOK(t, strings.Replace(goodImpl, "## Context\nctx", "## Context\nother", 1))
	if a.FrontmatterSHA != b.FrontmatterSHA {
		t.Fatalf("body change moved the sha")
	}
	c := parseOK(t, strings.Replace(goodImpl, "tier: any", "tier: strong", 1))
	if a.FrontmatterSHA == c.FrontmatterSHA {
		t.Fatalf("frontmatter change kept the sha")
	}
}

func errContains(t *testing.T, text, want string) {
	t.Helper()
	_, errs := Parse(text, false)
	for _, e := range errs {
		if strings.Contains(e, want) {
			return
		}
	}
	t.Fatalf("errors %v lack %q", errs, want)
}

func TestParseErrors(t *testing.T) {
	errContains(t, "no marker", "missing opening --- marker")
	errContains(t, "---\nid: x\n", "missing closing --- marker")
	errContains(t, strings.Replace(goodImpl, "plan: demo", "Bad Line", 1), "unparseable frontmatter line")
	errContains(t, strings.Replace(goodImpl, "plan: demo", "plan: &anchor", 1), "anchors/aliases are not allowed")
	errContains(t, strings.Replace(goodImpl, "plan: demo", "plan: demo\nclaimed_at: x", 1), "unknown frontmatter key")
	errContains(t, strings.Replace(goodImpl, "plan: demo", "plan: demo\ngeneration: 1", 1), "unknown frontmatter key")
	errContains(t, strings.Replace(goodImpl, "depends_on: []", "depends_on:", 1), "empty value - use [] for an empty list")
}

func TestSchemaErrors(t *testing.T) {
	errContains(t, strings.Replace(goodImpl, "type: impl", "type: chore", 1), "type: illegal value")
	errContains(t, strings.Replace(goodImpl, "tier: any", "tier: mega", 1), "tier: illegal value")
	errContains(t, strings.Replace(goodImpl, "id: demo-01-widget", "id: Demo_01", 1), "id: must be kebab-case")
	// impl needs protected + commit_paths
	errContains(t, strings.Replace(goodImpl, "commit_paths:\n  - src/widget.go\n  - tests/widget_test.go\n", "", 1), "commit_paths: required on impl tasks")
	// review needs reviews; commit_paths forbidden
	rev := strings.NewReplacer(
		"type: impl", "type: review",
		"id: demo-01-widget", "id: demo-02-review-widget",
		"# demo-01-widget: build the widget", "# demo-02-review-widget: review").Replace(goodImpl)
	_, errs := Parse(rev, false)
	joined := strings.Join(errs, "|")
	if !strings.Contains(joined, "reviews: required on review tasks") {
		t.Fatalf("missing reviews error: %v", errs)
	}
	if !strings.Contains(joined, "commit_paths: must be omitted on review tasks") {
		t.Fatalf("missing commit_paths error: %v", errs)
	}
}

func TestVerifySchema(t *testing.T) {
	errContains(t, strings.Replace(goodImpl, "    expect_exit: 0", "    expect_wrong: 0", 1), "verify: unknown key")
	errContains(t, strings.Replace(goodImpl, "    expect_exit: 0", "    expect_exit: soon", 1), "verify: expect_exit must be an integer")
	errContains(t, strings.Replace(goodImpl, "  - cmd: go test ./tests\n    expect_exit: 0", "  - cmd: go test ./tests", 1), "verify: entry needs expect_exit and/or expect_contains")
	errContains(t, strings.Replace(goodImpl, "verify:\n  - cmd: go test ./tests\n    expect_exit: 0", "verify: inline", 1), "verify: must be a block list")
}

func TestStagedMode(t *testing.T) {
	fix := strings.NewReplacer(
		"type: impl", "type: fix",
		"id: demo-01-widget", "id: demo-01-fix-widget",
		"# demo-01-widget: build the widget", "# demo-01-fix-widget: fix").Replace(goodImpl)
	fix = strings.Replace(fix, "plan: demo", "plan: demo\nfixes: demo-01-widget", 1)
	c, errs := Parse(fix, true)
	if len(errs) > 0 {
		t.Fatalf("staged fix should parse: %v", errs)
	}
	if c.Fixes != "demo-01-widget" {
		t.Fatalf("fixes: %q", c.Fixes)
	}
}

func TestQuoteStripping(t *testing.T) {
	q := strings.Replace(goodImpl, `  - cmd: go test ./tests`, `  - cmd: "go test ./tests"`, 1)
	c := parseOK(t, q)
	if c.Verify[0].Cmd != "go test ./tests" {
		t.Fatalf("quotes not stripped: %q", c.Verify[0].Cmd)
	}
}
