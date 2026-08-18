//go:build process

package process

import (
	"strings"
	"testing"
)

// A containing repo that ignores *.log must not stall `done`: MUSTER's own
// verify.log is force-added, so the completion commit still lands.
func TestDoneCommitsIgnoredVerifyLog(t *testing.T) {
	skipOffWindows(t) // the fixture verify uses findstr (Windows-only)
	repo := defaultBoard(t)
	// the blanket rule that swallowed .muster/cards/*.verify.log in the field.
	// Commit it BEFORE claim: an untracked .gitignore would itself trip
	// donePreconditions' "changed outside commit_paths" guard (it is not matched
	// by *.log), which is not the behavior under test. The real incident's ignore
	// file is a tracked repo file too.
	write(t, repo, ".gitignore", "*.log\n")
	gitCommit(t, repo, "ignore logs", ".gitignore")

	mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	write(t, repo, "src/hello.txt", "hello world\n")
	out := mustMuster(t, repo, "verify")
	assertContains(t, out, "VERIFY PASS (attempt 1)")

	out = mustMuster(t, repo, "done")
	assertContains(t, out, "Done: p2-01-hello", "Session over.")

	// the verify.log is actually committed despite the ignore rule
	ls := run(t, repo, "git", "ls-files", ".muster/cards/p2-01-hello.verify.log")
	if strings.TrimSpace(ls) == "" {
		t.Fatalf("verify.log must be tracked after done; git ls-files empty")
	}
}

// The mirror invariant: a USER commit_path the repo ignores is NOT force-added -
// `done` refuses, preserving the user's deliberate ignore intent (spec item 1).
func TestDoneRefusesIgnoredCommitPath(t *testing.T) {
	skipOffWindows(t)
	repo := defaultBoard(t)
	// ignore the task's own commit_path (src/hello.txt). The file still exists on
	// disk so verify's findstr passes; only the plain `git add` at completion fails.
	write(t, repo, ".gitignore", "src/hello.txt\n")
	gitCommit(t, repo, "ignore hello", ".gitignore")

	mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	write(t, repo, "src/hello.txt", "hello world\n")
	out := mustMuster(t, repo, "verify")
	assertContains(t, out, "VERIFY PASS (attempt 1)")

	out, code := muster(t, repo, nil, "done")
	if code == 0 {
		t.Fatalf("done must refuse an ignored user commit_path (user intent preserved), got exit 0:\n%s", out)
	}
	assertContains(t, out, "git add failed")
}

