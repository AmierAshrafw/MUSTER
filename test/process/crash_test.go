//go:build process

package process

import (
	"strings"
	"testing"
)

func TestCrashBeforeCommitIsCleanRetry(t *testing.T) {
	skipOffWindows(t)
	repo := defaultBoard(t)
	mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	write(t, repo, "src/hello.txt", "hello world\n")
	out, code := muster(t, repo, []string{"MUSTER_CRASH_POINT=before-commit"}, "done")
	if code != 97 {
		t.Fatalf("crash injection missed: %d\n%s", code, out)
	}
	subject := strings.TrimSpace(run(t, repo, "git", "log", "-1", "--format=%s"))
	if strings.HasPrefix(subject, "muster(p2): done") {
		t.Fatal("no commit may exist before the crash point")
	}
	show := mustMuster(t, repo, "show", "p2-01-hello")
	assertContains(t, show, "status: doing")
	// clean retry
	out = mustMuster(t, repo, "done")
	assertContains(t, out, "Done: p2-01-hello")
}

func TestCrashAfterCommitHealsViaReconciler(t *testing.T) {
	skipOffWindows(t)
	repo := defaultBoard(t)
	mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	write(t, repo, "src/hello.txt", "hello world\n")
	out, code := muster(t, repo, []string{"MUSTER_CRASH_POINT=after-commit"}, "done")
	if code != 97 {
		t.Fatalf("crash injection missed: %d\n%s", code, out)
	}
	subject := strings.TrimSpace(run(t, repo, "git", "log", "-1", "--format=%s"))
	if subject != "muster(p2): done p2-01-hello" {
		t.Fatalf("done commit must exist: %s", subject)
	}
	show := mustMuster(t, repo, "show", "p2-01-hello")
	assertContains(t, show, "status: doing") // the torn state
	// next claim reconciles, then hands out the promoted integration task or
	// refuses - either way the row must heal
	out, _ = muster(t, repo, nil, "claim", "-harness", "claude", "-tier", "any")
	assertContains(t, out, "Reconciled p2-01-hello: done commit found, row healed.")
	show = mustMuster(t, repo, "show", "p2-01-hello")
	assertContains(t, show, "status: done")
}
