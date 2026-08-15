//go:build process

package process

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
)

func skipOffWindows(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("findstr fixtures are Windows-first")
	}
}

func TestFullHappyLoop(t *testing.T) {
	skipOffWindows(t)
	repo := defaultBoard(t)
	out := mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	assertContains(t, out, "Claimed p2-01-hello. Follow .muster/RUNNER.md.")
	write(t, repo, "src/hello.txt", "hello world\n")
	out = mustMuster(t, repo, "verify")
	assertContains(t, out, "VERIFY PASS (attempt 1)")
	out = mustMuster(t, repo, "done")
	assertContains(t, out, "Board:", "Done: p2-01-hello. Promoted: p2-99-int. Do not claim another task. Session over.")
	subject := strings.TrimSpace(run(t, repo, "git", "log", "-1", "--format=%s"))
	if subject != "muster(p2): done p2-01-hello" {
		t.Fatalf("subject: %s", subject)
	}
	if porcelain := strings.TrimSpace(run(t, repo, "git", "status", "--porcelain")); porcelain != "" {
		t.Fatalf("tree not clean after done:\n%s", porcelain)
	}
	// integration leg: notes required, verdict recorded
	out = mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "strong")
	assertContains(t, out, "Claimed p2-99-int")
	write(t, repo, ".muster/cards/p2-99-int.notes.md", "suite green\n")
	out = mustMuster(t, repo, "done", "pass")
	assertContains(t, out, "Done: p2-99-int")
	out = mustMuster(t, repo, "show", "p2-99-int")
	assertContains(t, out, "status: done", "verdict: pass")
	// backup survived
	if _, err := os.Stat(filepath.Join(repo, ".muster", "backup.db")); err != nil {
		t.Fatal("backup.db missing")
	}
}

func TestClaimRaceTwoProcesses(t *testing.T) {
	skipOffWindows(t)
	repo := defaultBoard(t)
	var wg sync.WaitGroup
	outs := make([]string, 2)
	codes := make([]int, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			outs[i], codes[i] = muster(t, repo, nil, "claim", "-harness", "claude", "-tier", "any")
		}(i)
	}
	wg.Wait()
	winners := 0
	for i := 0; i < 2; i++ {
		if strings.Contains(outs[i], "Claimed p2-01-hello") {
			winners++
		} else if !strings.Contains(outs[i], "MUSTER refuse:") {
			t.Fatalf("racer %d neither claimed nor refused:\n%s", i, outs[i])
		}
	}
	if winners != 1 {
		t.Fatalf("winners = %d\nA:\n%s\nB:\n%s", winners, outs[0], outs[1])
	}
}

func TestStatusBlockBeforeRefusal(t *testing.T) {
	skipOffWindows(t)
	repo := defaultBoard(t)
	mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	out, code := muster(t, repo, nil, "claim", "-harness", "claude", "-tier", "any")
	if code != 1 {
		t.Fatalf("code %d", code)
	}
	iStatus := strings.Index(out, "MUSTER status @")
	iRefuse := strings.Index(out, "MUSTER refuse:")
	if iStatus < 0 || iRefuse < 0 || iStatus > iRefuse {
		t.Fatalf("CM-ORDER violated:\n%s", out)
	}
}

func TestVerifyTerminalEvidence(t *testing.T) {
	skipOffWindows(t)
	red := strings.Replace(implCardP2, "cmd: findstr hello src\\hello.txt", "cmd: findstr absent src\\hello.txt", 1)
	red = strings.Replace(red, "    expect_contains: hello\n", "", 1)
	repo := boardWithCards(t, map[string]string{
		"p2-01-hello.md": red,
		"p2-99-int.md":   integrationCardP2,
	})
	mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	write(t, repo, "src/hello.txt", "hello world\n")
	for want, i := 2, 1; i <= 3; i++ {
		out, code := muster(t, repo, nil, "verify")
		if i == 3 {
			want = 3
		}
		if code != want {
			t.Fatalf("attempt %d: code %d\n%s", i, code, out)
		}
	}
	out := mustMuster(t, repo, "board")
	assertContains(t, out, "failed   1")
	if _, err := os.Stat(filepath.Join(repo, "src", "hello.txt")); err != nil {
		t.Fatal("evidence must stay in the tree")
	}
}

func TestDoneRefusesNonDescendantHead(t *testing.T) {
	skipOffWindows(t)
	repo := defaultBoard(t)
	write(t, repo, "note.txt", "post-shard commit\n")
	gitCommit(t, repo, "unrelated", "note.txt")
	mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	write(t, repo, "src/hello.txt", "hello world\n")
	// HEAD moves behind head_at_claim; src/hello.txt is untracked and survives
	run(t, repo, "git", "reset", "--hard", "HEAD~1")
	out, code := muster(t, repo, nil, "done")
	if code != 1 || !strings.Contains(out, "not a descendant of head_at_claim") {
		t.Fatalf("code %d:\n%s", code, out)
	}
}

func TestHookMutationAbsorbed(t *testing.T) {
	skipOffWindows(t)
	repo := defaultBoard(t)
	// idempotent tree-mutating pre-commit hook (appends a marker once)
	write(t, repo, ".git/hooks/pre-commit",
		"#!/bin/sh\ngrep -q HOOKED src/hello.txt 2>/dev/null || echo HOOKED >> src/hello.txt\nexit 0\n")
	mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	write(t, repo, "src/hello.txt", "hello world\n")
	mustMuster(t, repo, "verify")
	out := mustMuster(t, repo, "done")
	assertContains(t, out, "Session over.")
	if porcelain := strings.TrimSpace(run(t, repo, "git", "status", "--porcelain")); porcelain != "" {
		t.Fatalf("hook dirt left behind:\n%s", porcelain)
	}
	blob := run(t, repo, "git", "show", "HEAD:src/hello.txt")
	if !strings.Contains(blob, "HOOKED") {
		t.Fatalf("hook mutation must be committed, not bypassed:\n%s", blob)
	}
}
