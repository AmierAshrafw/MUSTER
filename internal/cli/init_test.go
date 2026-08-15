package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"muster/internal/gitx"
)

// newInitApp: an App over a bare temp root with NO .muster/ yet.
func newInitApp(t *testing.T) (*App, *gitx.Fake, *bytes.Buffer) {
	t.Helper()
	root := t.TempDir()
	fake := &gitx.Fake{HeadSHA: "head0", BranchName: "main", UserOK: true, HeadFiles: map[string]string{}}
	out := &bytes.Buffer{}
	return &App{
		Root: root, Dir: filepath.Join(root, ".muster"), G: fake, Out: out,
		Now:    func() time.Time { return time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC) },
		Getenv: func(string) string { return "" },
	}, fake, out
}

func TestInitFreshInstall(t *testing.T) {
	a, fake, out := newInitApp(t)
	if code := a.Init(nil); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	for _, rel := range []string{
		".muster/cards", ".muster/staging", ".muster/plans",
		".muster/.gitignore", ".muster/.gitattributes", ".muster/RUNNER.md",
		".muster/muster.db",
	} {
		if _, err := os.Stat(filepath.Join(a.Root, filepath.FromSlash(rel))); err != nil {
			t.Fatalf("missing %s", rel)
		}
	}
	if len(fake.Commits) != 1 || fake.Commits[0].Msg != "muster: init" {
		t.Fatalf("commits: %+v", fake.Commits)
	}
	claude, _ := os.ReadFile(filepath.Join(a.Root, "CLAUDE.md"))
	if !strings.Contains(string(claude), ".muster/ is managed by MUSTER v2") {
		t.Fatalf("pointer missing:\n%s", claude)
	}
	if !strings.Contains(out.String(), "muster claim -harness claude -tier any") {
		t.Fatalf("dispatch lines missing:\n%s", out.String())
	}
}

func TestInitRefusesTwice(t *testing.T) {
	a, _, out := newInitApp(t)
	if code := a.Init(nil); code != 0 {
		t.Fatalf("first: %s", out.String())
	}
	if code := a.Init(nil); code != 1 {
		t.Fatal("second must refuse")
	}
	if !strings.Contains(out.String(), "already exists") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestInitRefusesMissingIdentity(t *testing.T) {
	a, fake, out := newInitApp(t)
	fake.UserOK = false
	if code := a.Init(nil); code != 1 {
		t.Fatal("must refuse")
	}
	if !strings.Contains(out.String(), "git identity missing") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestInitSyncRootGuard(t *testing.T) {
	a, fake, out := newInitApp(t)
	_ = fake
	sub := filepath.Join(a.Root, "OneDrive", "repo")
	os.MkdirAll(sub, 0o755)
	a.Root = sub
	a.Dir = filepath.Join(sub, ".muster")
	if code := a.Init(nil); code != 1 {
		t.Fatal("sync root must refuse without -sync-ok")
	}
	if !strings.Contains(out.String(), "sync engine") {
		t.Fatalf("out: %s", out.String())
	}
	out.Reset()
	if code := a.Init([]string{"-sync-ok"}); code != 0 {
		t.Fatalf("-sync-ok must proceed: %s", out.String())
	}
}

func makeV1Tree(t *testing.T, root string, live bool) {
	t.Helper()
	for _, d := range []string{"inbox", "backlog", "doing", "done", "failed", "archive", "staging", "bin"} {
		os.MkdirAll(filepath.Join(root, "tasks", d), 0o755)
		os.WriteFile(filepath.Join(root, "tasks", d, ".gitkeep"), nil, 0o644)
	}
	os.WriteFile(filepath.Join(root, "tasks", "bin", "claim.ps1"), []byte("# v1 claim"), 0o644)
	os.WriteFile(filepath.Join(root, "tasks", "bin", "claim.sh"), []byte("# v1 claim"), 0o644)
	os.WriteFile(filepath.Join(root, "tasks", "RUNNER.md"), []byte("# v1 runner"), 0o644)
	// orphaned sidecars must never count as live
	os.WriteFile(filepath.Join(root, "tasks", "doing", "old.verify.log"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(root, "tasks", "doing", "old.notes.md"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(root, "tasks", "done", "p-01-a.md"), []byte("done card"), 0o644)
	os.WriteFile(filepath.Join(root, "CLAUDE.md"), []byte(
		"Task board: `tasks/` is managed by MUSTER. Executors follow `tasks/RUNNER.md` exactly. Never edit files under `tasks/` by hand; the `tasks/bin/` scripts own all state transitions.\n"), 0o644)
	if live {
		os.WriteFile(filepath.Join(root, "tasks", "inbox", "p-02-b.md"), []byte("live card"), 0o644)
	}
}

func TestInitRefusesLiveV1(t *testing.T) {
	a, _, out := newInitApp(t)
	makeV1Tree(t, a.Root, true)
	if code := a.Init(nil); code != 1 {
		t.Fatal("live v1 must refuse")
	}
	s := out.String()
	if !strings.Contains(s, "tasks/inbox/p-02-b.md") {
		t.Fatalf("refusal must name the live files:\n%s", s)
	}
	if !strings.Contains(s, "v1 board is live") {
		t.Fatalf("out: %s", s)
	}
	if _, err := os.Stat(a.Dir); err == nil {
		t.Fatal("refusal must not half-install")
	}
}

func TestInitDecommissionsDeadV1(t *testing.T) {
	a, fake, out := newInitApp(t)
	makeV1Tree(t, a.Root, false)
	if code := a.Init(nil); code != 0 {
		t.Fatalf("dead v1 must install: %s", out.String())
	}
	stub, _ := os.ReadFile(filepath.Join(a.Root, "tasks", "bin", "claim.ps1"))
	if !strings.Contains(string(stub), "MUSTER refuse: v1 board decommissioned") {
		t.Fatalf("ps1 stub wrong:\n%s", stub)
	}
	stubSh, _ := os.ReadFile(filepath.Join(a.Root, "tasks", "bin", "claim.sh"))
	if !strings.Contains(string(stubSh), "MUSTER refuse: v1 board decommissioned") {
		t.Fatalf("sh stub wrong:\n%s", stubSh)
	}
	claude, _ := os.ReadFile(filepath.Join(a.Root, "CLAUDE.md"))
	s := string(claude)
	if strings.Contains(s, "tasks/ is managed by MUSTER.") {
		t.Fatalf("v1 pointer must be gone:\n%s", s)
	}
	if !strings.Contains(s, ".muster/ is managed by MUSTER v2") {
		t.Fatalf("v2 pointer missing:\n%s", s)
	}
	joined := strings.Join(fake.Commits[0].Paths, " ")
	if !strings.Contains(joined, "tasks/bin/claim.ps1") || !strings.Contains(joined, "CLAUDE.md") {
		t.Fatalf("stubs and pointer must be committed: %v", fake.Commits[0].Paths)
	}
}
