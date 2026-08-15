//go:build process

package process

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

var musterExe string

func TestMain(m *testing.M) {
	tmp, err := os.MkdirTemp("", "muster-build")
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	globalConfig := filepath.Join(tmp, "global.gitconfig")
	if err := os.WriteFile(globalConfig, nil, 0o644); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	emptyIgnore := filepath.Join(tmp, "empty-ignore")
	if err := os.WriteFile(emptyIgnore, nil, 0o644); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	if err := os.Setenv("GIT_CONFIG_GLOBAL", globalConfig); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	for key, value := range map[string]string{
		"GIT_CONFIG_COUNT":   "2",
		"GIT_CONFIG_KEY_0":   "core.excludesFile",
		"GIT_CONFIG_VALUE_0": emptyIgnore,
		"GIT_CONFIG_KEY_1":   "safe.directory",
		"GIT_CONFIG_VALUE_1": "*",
	} {
		if err := os.Setenv(key, value); err != nil {
			fmt.Println(err)
			os.Exit(1)
		}
	}
	musterExe = filepath.Join(tmp, "muster.exe")
	root, _ := filepath.Abs(filepath.Join("..", ".."))
	cmd := exec.Command("go", "build", "-o", musterExe, "./cmd/muster")
	cmd.Dir = root
	if out, err := cmd.CombinedOutput(); err != nil {
		fmt.Printf("build failed: %v\n%s\n", err, out)
		os.Exit(1)
	}
	code := m.Run()
	os.RemoveAll(tmp)
	os.Exit(code)
}

// newRepo: temp git repo with identity and one initial commit.
func newRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	run(t, dir, "git", "init", "-q", "-b", "main")
	run(t, dir, "git", "config", "user.name", "proc")
	run(t, dir, "git", "config", "user.email", "proc@test.local")
	write(t, dir, "README.md", "process fixture\n")
	gitCommit(t, dir, "init", "README.md")
	return dir
}

// muster runs the built binary in repo; returns merged output + exit code.
func muster(t *testing.T, repo string, env []string, args ...string) (string, int) {
	t.Helper()
	cmd := exec.Command(musterExe, args...)
	cmd.Dir = repo
	cmd.Env = append(os.Environ(), env...)
	out, err := cmd.CombinedOutput()
	code := 0
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else {
			t.Fatalf("muster %v: %v\n%s", args, err, out)
		}
	}
	return string(out), code
}

func mustMuster(t *testing.T, repo string, args ...string) string {
	t.Helper()
	out, code := muster(t, repo, nil, args...)
	if code != 0 {
		t.Fatalf("muster %v exited %d:\n%s", args, code, out)
	}
	return out
}

const implCardP2 = `---
id: p2-01-hello
plan: p2
type: impl
tier: any
depends_on: []
protected: []
commit_paths:
  - src/hello.txt
verify:
  - cmd: findstr hello src\hello.txt
    expect_exit: 0
    expect_contains: hello
---
# p2-01-hello: write hello

## Context
Process-tier fixture.

## Steps
1. Create src/hello.txt containing the word hello.

## Acceptance
- findstr finds hello
`

const integrationCardP2 = `---
id: p2-99-int
plan: p2
type: integration
tier: strong
depends_on:
  - p2-01-hello
verify:
  - cmd: git --version
    expect_exit: 0
---
# p2-99-int: integrate

## Context
Process-tier fixture.

## Steps
1. Confirm the suite is green.

## Acceptance
- verify green
`

// boardWithCards: init + ingest + commit + promote; returns the repo.
func boardWithCards(t *testing.T, cards map[string]string) string {
	t.Helper()
	repo := newRepo(t)
	mustMuster(t, repo, "init")
	var paths []string
	var ingestPaths []string
	gitRoot := strings.TrimSpace(run(t, repo, "git", "rev-parse", "--show-toplevel"))
	for name, text := range cards {
		rel := ".muster/cards/" + name
		write(t, repo, rel, text)
		paths = append(paths, rel)
		ingestPaths = append(ingestPaths, filepath.Join(gitRoot, filepath.FromSlash(rel)))
	}
	// Git canonicalizes the root, so use it for the real-binary path guard.
	mustMuster(t, repo, append([]string{"ingest"}, ingestPaths...)...)
	gitCommit(t, repo, "muster(p2): shard", append([]string{}, paths...)...)
	mustMuster(t, repo, "promote")
	return repo
}

func defaultBoard(t *testing.T) string {
	return boardWithCards(t, map[string]string{
		"p2-01-hello.md": implCardP2,
		"p2-99-int.md":   integrationCardP2,
	})
}

func assertContains(t *testing.T, out string, wants ...string) {
	t.Helper()
	for _, w := range wants {
		if !strings.Contains(out, w) {
			t.Fatalf("output missing %q:\n%s", w, out)
		}
	}
}
