package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// green verify: `go version` runs everywhere the build runs, no network.
const verifyGreenCard = claimCard

var verifyRedCard = strings.Replace(claimCard,
	"  - cmd: go version\n    expect_contains: go version",
	"  - cmd: go tool bogus-no-such-tool\n    expect_exit: 0", 1)

func claimFor(t *testing.T, a *App, out interface{ String() string }) {
	t.Helper()
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"}); code != 0 {
		t.Fatalf("fixture claim failed: %s", out.String())
	}
}

func TestVerifyRefusesEmptyDoing(t *testing.T) {
	a, _, out := newApp(t)
	if code := a.Dispatch("verify", nil); code != 1 {
		t.Fatalf("code %d", code)
	}
	if !strings.Contains(out.String(), "doing is empty") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestVerifyPassLogsAttempt(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", verifyGreenCard, "inbox")
	claimFor(t, a, out)
	if code := a.Dispatch("verify", nil); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	if !strings.Contains(out.String(), "VERIFY PASS (attempt 1)") {
		t.Fatalf("out: %s", out.String())
	}
	n, _ := a.St.AttemptsSinceClaim("demo-01-w")
	if n != 1 {
		t.Fatalf("attempts: %d", n)
	}
	log, err := os.ReadFile(filepath.Join(a.Dir, "cards", "demo-01-w.verify.log"))
	if err != nil || !strings.Contains(string(log), "=== attempt 1 |") {
		t.Fatalf("log: %v %s", err, log)
	}
}

func TestVerifyFailRetryThenTerminal(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", verifyRedCard, "inbox")
	claimFor(t, a, out)
	if code := a.Dispatch("verify", nil); code != 2 {
		t.Fatalf("attempt 1 code %d: %s", code, out.String())
	}
	if !strings.Contains(out.String(), "VERIFY FAIL (attempt 1 of 3)") ||
		!strings.Contains(out.String(), "Fix and rerun.") {
		t.Fatalf("out: %s", out.String())
	}
	a.Dispatch("verify", nil) // attempt 2
	if code := a.Dispatch("verify", nil); code != 3 {
		t.Fatal("attempt 3 must be terminal")
	}
	if !strings.Contains(out.String(), "VERIFY FAIL terminal") ||
		!strings.Contains(out.String(), "Session over.") {
		t.Fatalf("out: %s", out.String())
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "failed" {
		t.Fatalf("terminal status: %s", row.Status)
	}
}

func TestVerifyBurnsAttemptBeforeRunning(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", verifyGreenCard, "inbox")
	claimFor(t, a, out)
	// three attempts already burned: verify must go terminal WITHOUT running
	for i := 1; i <= 3; i++ {
		a.St.AppendEvent("demo-01-w", "claude/any", "attempt", "", "2026-01-02T00:00:00Z")
	}
	if code := a.Dispatch("verify", nil); code != 3 {
		t.Fatal("must be terminal")
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "failed" {
		t.Fatalf("status: %s", row.Status)
	}
}
