package verify

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"muster/internal/card"
)

func TestSplitCmdLine(t *testing.T) {
	toks, err := SplitCmdLine(`dotnet test "My Tests/X.csproj" -v q`)
	if err != nil || len(toks) != 5 || toks[2] != "My Tests/X.csproj" {
		t.Fatalf("%v %v", toks, err)
	}
	if _, err := SplitCmdLine(`echo "oops`); err == nil {
		t.Fatal("unbalanced quote must error")
	}
}

func block(t *testing.T, entries []card.VerifyEntry) (Result, string) {
	t.Helper()
	if runtime.GOOS != "windows" {
		t.Skip("runner tests are Windows-first (spec)")
	}
	dir := t.TempDir()
	log := filepath.Join(dir, "t.verify.log")
	r, err := RunBlock(entries, BlockOpts{
		WorkDir: dir, LogPath: log, Label: "attempt 1", TaskID: "t",
		Head: "abc123", NowIso: func() string { return "2026-01-01T00:00:00Z" },
	})
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(log)
	return r, string(raw)
}

func TestPassingBlockTranscript(t *testing.T) {
	r, raw := block(t, []card.VerifyEntry{
		{Cmd: "cmd /c echo hello", ExpectExit: "0", ExpectContains: "hello"},
	})
	if !r.Pass {
		t.Fatalf("pass: %+v", r)
	}
	for _, want := range []string{
		"=== attempt 1 | 2026-01-01T00:00:00Z | task t | HEAD abc123",
		"$ cmd /c echo hello",
		"exit 0 | expect_exit 0 -> OK | expect_contains \"hello\" -> OK",
		"=== attempt 1 result: PASS",
	} {
		if !strings.Contains(raw, want) {
			t.Fatalf("transcript missing %q in:\n%s", want, raw)
		}
	}
}

func TestFailStopsAtFirstEntry(t *testing.T) {
	r, raw := block(t, []card.VerifyEntry{
		{Cmd: "cmd /c exit 7", ExpectExit: "0"},
		{Cmd: "cmd /c echo second", ExpectExit: "0"},
	})
	if r.Pass {
		t.Fatal("must fail")
	}
	if !strings.Contains(r.FirstFail, "cmd /c exit 7") || !strings.Contains(r.FirstFail, "exit 7, expected 0") {
		t.Fatalf("first fail: %q", r.FirstFail)
	}
	if strings.Contains(raw, "echo second") {
		t.Fatal("second entry must not run")
	}
}

func TestMissingExecutableFailsEntry(t *testing.T) {
	r, raw := block(t, []card.VerifyEntry{{Cmd: "muster-no-such-exe", ExpectExit: "0"}})
	if r.Pass {
		t.Fatal("must fail")
	}
	if !strings.Contains(raw, "spawn failed") {
		t.Fatalf("transcript: %s", raw)
	}
}

func TestTimeoutKillsProcess(t *testing.T) {
	r, raw := block(t, []card.VerifyEntry{
		{Cmd: "cmd /c ping -n 30 127.0.0.1", ExpectExit: "0", TimeoutSeconds: "2"},
	})
	if r.Pass {
		t.Fatal("must fail")
	}
	if !strings.Contains(raw, "timeout 2s -> FAIL") {
		t.Fatalf("transcript: %s", raw)
	}
}

func TestOutputCap(t *testing.T) {
	// 200 lines of 1KB each exceeds the 64KB cap
	r, raw := block(t, []card.VerifyEntry{
		{Cmd: "cmd /c for /l %i in (1,1,200) do @echo " + strings.Repeat("x", 1024), ExpectExit: "0"},
	})
	_ = r
	if !strings.Contains(raw, "[output truncated]") {
		t.Fatal("cap marker missing")
	}
	if len(raw) > 80*1024 {
		t.Fatalf("log not capped: %d bytes", len(raw))
	}
}
