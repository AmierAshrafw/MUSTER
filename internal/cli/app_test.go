package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"muster/internal/gitx"
	"muster/internal/store"
)

// newApp builds a unit-tier App: temp repo dir with .muster/cards, temp store,
// fake git, captured output, frozen clock.
func newApp(t *testing.T) (*App, *gitx.Fake, *bytes.Buffer) {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, ".muster")
	for _, d := range []string{"cards", "staging", "plans"} {
		if err := os.MkdirAll(filepath.Join(dir, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	st, err := store.Open(filepath.Join(dir, "muster.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	fake := &gitx.Fake{HeadSHA: "head0", BranchName: "main", AncestorOK: true, UserOK: true,
		HeadFiles: map[string]string{}}
	out := &bytes.Buffer{}
	app := &App{
		Root: root, Dir: dir, St: st, G: fake, Out: out,
		Now:    func() time.Time { return time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC) },
		Getenv: func(string) string { return "" },
	}
	return app, fake, out
}

func seed(t *testing.T, a *App, id, typ, tier, status string, deps ...string) {
	t.Helper()
	err := a.St.Ingest([]store.IngestTask{{
		Task: store.Task{ID: id, Plan: "p", Seq: 1, Type: typ, Tier: tier,
			CardPath: ".muster/cards/" + id + ".md", FrontmatterSHA: "sha"},
		Deps: deps,
	}}, "shard", "2026-01-01T00:00:00Z")
	if err != nil {
		t.Fatal(err)
	}
	if status != "backlog" {
		if _, err := a.St.DB().Exec(`UPDATE tasks SET status=? WHERE id=?`, status, id); err != nil {
			t.Fatal(err)
		}
	}
}

func TestBoardEmpty(t *testing.T) {
	a, _, out := newApp(t)
	if code := a.Dispatch("board", nil); code != 0 {
		t.Fatalf("code %d", code)
	}
	if !strings.Contains(out.String(), "MUSTER: board empty") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestStatusBlockContent(t *testing.T) {
	a, _, out := newApp(t)
	seed(t, a, "p-01-a", "impl", "any", "inbox")
	seed(t, a, "p-02-r", "review", "strong", "inbox")
	seed(t, a, "p-03-c", "impl", "any", "doing")
	if _, err := a.St.DB().Exec(`UPDATE tasks SET claimed_at='2026-01-02T01:04:05Z' WHERE id='p-03-c'`); err != nil {
		t.Fatal(err)
	}
	seed(t, a, "p-04-d", "impl", "any", "failed")
	seed(t, a, "p-05-e", "impl", "any", "backlog", "p-04-d")
	a.Dispatch("board", nil)
	s := out.String()
	for _, want := range []string{
		"MUSTER status @",
		"(main)",
		"inbox    2 ready",
		"(run 1, review 1)",
		"[p-01-a, p-02-r]",
		"p-03-c claimed 2h",
		"backlog  1 blocked",
		"(1 DEAD: p-05-e behind failed p-04-d)",
		"failed   1",
		"[p-04-d]",
		"done     0",
	} {
		if !strings.Contains(s, want) {
			t.Fatalf("status block missing %q:\n%s", want, s)
		}
	}
}

func TestStatusBlockStaleMarker(t *testing.T) {
	a, _, out := newApp(t)
	seed(t, a, "p-01-a", "impl", "any", "doing")
	if _, err := a.St.DB().Exec(`UPDATE tasks SET claimed_at='2025-12-30T00:00:00Z' WHERE id='p-01-a'`); err != nil {
		t.Fatal(err)
	}
	a.Dispatch("board", nil)
	if !strings.Contains(out.String(), "STALE") {
		t.Fatalf("stale marker missing:\n%s", out.String())
	}
}

func TestShow(t *testing.T) {
	a, _, out := newApp(t)
	seed(t, a, "p-01-a", "impl", "any", "inbox")
	cardPath := filepath.Join(a.Dir, "cards", "p-01-a.md")
	if err := os.WriteFile(cardPath, []byte("---\nid: p-01-a\n---\nbody here"), 0o644); err != nil {
		t.Fatal(err)
	}
	if code := a.Dispatch("show", []string{"p-01-a"}); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	s := out.String()
	for _, want := range []string{"body here", "status: inbox", "ingest"} {
		if !strings.Contains(s, want) {
			t.Fatalf("show missing %q:\n%s", want, s)
		}
	}
}

func TestShowUnknownID(t *testing.T) {
	a, _, out := newApp(t)
	if code := a.Dispatch("show", []string{"nope"}); code != 1 {
		t.Fatalf("code %d", code)
	}
	if !strings.Contains(out.String(), "MUSTER refuse:") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestAgeString(t *testing.T) {
	now := time.Date(2026, 1, 2, 12, 0, 0, 0, time.UTC)
	for iso, want := range map[string]string{
		"2026-01-02T11:18:00Z": "42m",
		"2026-01-02T09:00:00Z": "3h",
		"2025-12-31T12:00:00Z": "2d",
	} {
		if got := ageString(now, iso); got != want {
			t.Fatalf("%s: got %s want %s", iso, got, want)
		}
	}
}
