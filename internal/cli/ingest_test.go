package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const ingestImpl = `---
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
  - cmd: go test internal/w
    expect_exit: 0
---
# demo-01-w: build w

## Context
ctx

## Steps
1. build

## Acceptance
- green
`

const ingestIntegration = `---
id: demo-99-int
plan: demo
type: integration
tier: strong
depends_on:
  - demo-01-w
verify:
  - cmd: go vet all
    expect_exit: 0
---
# demo-99-int: integrate

## Context
ctx

## Steps
1. run

## Acceptance
- green
`

func writeInCards(t *testing.T, a *App, name, text string) string {
	t.Helper()
	p := filepath.Join(a.Dir, "cards", name)
	if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestIngestHappyPath(t *testing.T) {
	a, _, out := newApp(t)
	p1 := writeInCards(t, a, "demo-01-w.md", ingestImpl)
	p2 := writeInCards(t, a, "demo-99-int.md", ingestIntegration)
	if code := a.Dispatch("ingest", []string{p1, p2}); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	if !strings.Contains(out.String(), "INGEST OK 2 task(s)") {
		t.Fatalf("out: %s", out.String())
	}
	got, _ := a.St.Task("demo-01-w")
	if got == nil || got.Status != "backlog" || got.CardPath != ".muster/cards/demo-01-w.md" {
		t.Fatalf("row: %+v", got)
	}
	if got.FrontmatterSHA == "" {
		t.Fatal("sha not stored")
	}
	deps, _ := a.St.Deps("demo-99-int")
	if len(deps) != 1 || deps[0] != "demo-01-w" {
		t.Fatalf("deps: %v", deps)
	}
}

func TestIngestExpandsCardGlob(t *testing.T) {
	a, _, out := newApp(t)
	writeInCards(t, a, "demo-01-w.md", ingestImpl)
	writeInCards(t, a, "demo-99-int.md", ingestIntegration)
	t.Chdir(a.Root)
	pattern := filepath.Join(".muster", "cards", "demo-*.md")

	if code := a.Dispatch("ingest", []string{pattern}); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	if !strings.Contains(out.String(), "INGEST OK 2 task(s)") {
		t.Fatalf("out: %s", out.String())
	}
	for _, id := range []string{"demo-01-w", "demo-99-int"} {
		if got, _ := a.St.Task(id); got == nil {
			t.Fatalf("card %s was not ingested", id)
		}
	}
}

func TestIngestRefusesCardGlobWithNoMatches(t *testing.T) {
	a, _, out := newApp(t)
	t.Chdir(a.Root)
	pattern := filepath.Join(".muster", "cards", "missing-*.md")

	if code := a.Dispatch("ingest", []string{pattern}); code != 1 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	if !strings.Contains(out.String(), "MUSTER refuse: no card files match "+pattern) {
		t.Fatalf("out: %s", out.String())
	}
}

func TestIngestLintFailure(t *testing.T) {
	a, _, out := newApp(t)
	bad := strings.Replace(ingestImpl, "## Context\nctx", "## Context\nTBD", 1)
	p := writeInCards(t, a, "demo-01-w.md", bad)
	if code := a.Dispatch("ingest", []string{p}); code != 1 {
		t.Fatalf("code %d", code)
	}
	if !strings.Contains(out.String(), "LINT FAIL") {
		t.Fatalf("out: %s", out.String())
	}
	if got, _ := a.St.Task("demo-01-w"); got != nil {
		t.Fatal("failed lint must not insert")
	}
}

func TestIngestRefusesOutsideCardsDir(t *testing.T) {
	a, _, out := newApp(t)
	p := filepath.Join(a.Root, "demo-01-w.md")
	os.WriteFile(p, []byte(ingestImpl), 0o644)
	if code := a.Dispatch("ingest", []string{p}); code != 1 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	if !strings.Contains(out.String(), "must live under .muster/cards/") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestIngestNoArgs(t *testing.T) {
	a, _, _ := newApp(t)
	if code := a.Dispatch("ingest", nil); code != 1 {
		t.Fatalf("code %d", code)
	}
}
