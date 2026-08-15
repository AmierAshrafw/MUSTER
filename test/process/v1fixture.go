//go:build process

// Package process is the process tier: real muster.exe, real git, temp repos.
package process

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func run(t *testing.T, dir string, name string, args ...string) string {
	t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%s %v: %v\n%s", name, args, err, out)
	}
	return string(out)
}

func gitCommit(t *testing.T, dir, msg string, paths ...string) {
	t.Helper()
	run(t, dir, "git", append([]string{"add", "--"}, paths...)...)
	run(t, dir, "git", append([]string{"-c", "core.autocrlf=false", "commit", "-q", "-m", msg, "--"}, paths...)...)
}

func write(t *testing.T, dir, rel, content string) {
	t.Helper()
	abs := filepath.Join(dir, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(abs, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func v1Card(id, status string) string {
	return `---
id: ` + id + `
plan: v1demo
type: impl
tier: any
depends_on: []
protected: []
commit_paths:
  - src/out.txt
verify:
  - cmd: git --version
    expect_exit: 0
` + status + `---
# ` + id + `: synthetic v1 card

## Context
Frozen v1 fixture (spec D-v2-3).

## Steps
1. none - fixture only

## Acceptance
- fixture exists
`
}

// BuildV1Board freezes the synthetic v1 board (spec D-v2-3): cards in every
// folder plus the claim/attempt commit sequence. live=false leaves only
// dead-tree remnants (done/, archive/, orphaned sidecars) - the decommission
// fixture.
func BuildV1Board(t *testing.T, dir string, live bool) {
	t.Helper()
	run(t, dir, "git", "init", "-q", "-b", "main")
	run(t, dir, "git", "config", "user.name", "fixture")
	run(t, dir, "git", "config", "user.email", "fixture@test.local")

	// init commit: board skeleton
	for _, d := range []string{"backlog", "inbox", "doing", "done", "failed", "archive", "staging", "bin"} {
		write(t, dir, "tasks/"+d+"/.gitkeep", "")
	}
	write(t, dir, "tasks/RUNNER.md", "# RUNNER - v1 executor contract (frozen fixture)\n")
	write(t, dir, "tasks/bin/claim.ps1", "# v1 claim script (frozen fixture)\n")
	write(t, dir, "tasks/bin/claim.sh", "# v1 claim script (frozen fixture)\n")
	write(t, dir, "CLAUDE.md", "Task board: `tasks/` is managed by MUSTER. Executors follow `tasks/RUNNER.md` exactly. Never edit files under `tasks/` by hand; the `tasks/bin/` scripts own all state transitions.\n")
	gitCommit(t, dir, "muster: init task board", "tasks", "CLAUDE.md")

	// shard commit: plan snapshot + cards
	write(t, dir, "tasks/plan-v1demo.md", "# plan v1demo (frozen fixture)\n")
	write(t, dir, "tasks/backlog/v1demo-03-c.md", v1Card("v1demo-03-c", ""))
	write(t, dir, "tasks/inbox/v1demo-02-b.md", v1Card("v1demo-02-b", ""))
	write(t, dir, "tasks/inbox/v1demo-01-a.md", v1Card("v1demo-01-a", ""))
	write(t, dir, "tasks/done/v1demo-00-z.md", v1Card("v1demo-00-z", ""))
	write(t, dir, "tasks/failed/v1demo-04-d.md", v1Card("v1demo-04-d", ""))
	gitCommit(t, dir, "muster(v1demo): shard 5 tasks", "tasks")
	write(t, dir, "tasks/done/v1demo-00-z.result.md", "# Result: v1demo-00-z\n\n- status: done\n")
	gitCommit(t, dir, "muster(v1demo): done v1demo-00-z", "tasks/done")

	// claim commit: inbox -> doing with claimed_at stamped (v1 semantics)
	run(t, dir, "git", "mv", "tasks/inbox/v1demo-01-a.md", "tasks/doing/v1demo-01-a.md")
	write(t, dir, "tasks/doing/v1demo-01-a.md", v1Card("v1demo-01-a", "claimed_at: 2026-08-14T00:00:00Z\n"))
	run(t, dir, "git", "add", "-A", "tasks")
	run(t, dir, "git", "-c", "core.autocrlf=false", "commit", "-q", "-m", "muster(v1demo): claim v1demo-01-a")

	// attempt commit: verify.log header marker (D28)
	write(t, dir, "tasks/doing/v1demo-01-a.verify.log", "=== attempt 1 | 2026-08-14T00:01:00Z | task v1demo-01-a | HEAD x\n")
	gitCommit(t, dir, "muster(v1demo): attempt 1 v1demo-01-a", "tasks/doing/v1demo-01-a.verify.log")

	// staged fix from a crashed review session
	write(t, dir, "tasks/staging/v1demo-05-fix-e.md", v1Card("v1demo-05-fix-e", ""))

	if !live {
		// dead variant: clear every live folder, keep history + done/archive
		for _, rel := range []string{
			"tasks/backlog/v1demo-03-c.md", "tasks/inbox/v1demo-02-b.md",
			"tasks/doing/v1demo-01-a.md", "tasks/failed/v1demo-04-d.md",
			"tasks/staging/v1demo-05-fix-e.md", "tasks/plan-v1demo.md",
		} {
			os.Remove(filepath.Join(dir, filepath.FromSlash(rel)))
		}
		run(t, dir, "git", "add", "-A", "tasks")
		run(t, dir, "git", "-c", "core.autocrlf=false", "commit", "-q", "-m", "muster(v1demo): close")
	}
}
