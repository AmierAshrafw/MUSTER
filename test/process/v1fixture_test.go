//go:build process

package process

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestBuildV1BoardShape(t *testing.T) {
	dir := t.TempDir()
	BuildV1Board(t, dir, true)
	for _, rel := range []string{
		"tasks/RUNNER.md",
		"tasks/bin/claim.ps1",
		"tasks/backlog/v1demo-03-c.md",
		"tasks/inbox/v1demo-02-b.md",
		"tasks/doing/v1demo-01-a.md",
		"tasks/doing/v1demo-01-a.verify.log",
		"tasks/done/v1demo-00-z.md",
		"tasks/done/v1demo-00-z.result.md",
		"tasks/failed/v1demo-04-d.md",
		"tasks/staging/v1demo-05-fix-e.md",
		"tasks/plan-v1demo.md",
	} {
		if _, err := os.Stat(filepath.Join(dir, filepath.FromSlash(rel))); err != nil {
			t.Fatalf("missing %s", rel)
		}
	}
	out, err := exec.Command("git", "-C", dir, "log", "--format=%s").Output()
	if err != nil {
		t.Fatal(err)
	}
	log := string(out)
	for _, want := range []string{
		"muster: init task board",
		"muster(v1demo): shard",
		"muster(v1demo): claim v1demo-01-a",
		"muster(v1demo): attempt 1 v1demo-01-a",
		"muster(v1demo): done v1demo-00-z",
	} {
		if !strings.Contains(log, want) {
			t.Fatalf("commit sequence missing %q:\n%s", want, log)
		}
	}
}

func TestBuildV1BoardDeadVariant(t *testing.T) {
	dir := t.TempDir()
	BuildV1Board(t, dir, false)
	for _, rel := range []string{"tasks/inbox", "tasks/backlog", "tasks/doing", "tasks/staging", "tasks/failed"} {
		matches, _ := filepath.Glob(filepath.Join(dir, filepath.FromSlash(rel), "*.md"))
		live := 0
		for _, m := range matches {
			n := filepath.Base(m)
			if !strings.HasSuffix(n, ".result.md") && !strings.HasSuffix(n, ".notes.md") {
				live++
			}
		}
		if live != 0 {
			t.Fatalf("dead variant has live files in %s: %v", rel, matches)
		}
	}
}
