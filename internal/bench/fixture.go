// internal/bench/fixture.go
package bench

import (
	"debug/buildinfo"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

// Fixture is an isolated temp git repo with a hardened, benchmark-owned git
// environment. It copies the test/process pattern but widens the autocrlf guard:
// the target box's SYSTEM gitconfig sets core.autocrlf=true, which the global
// override alone does not neutralize.
type Fixture struct {
	Root string
	env  []string
}

// NewFixture initializes a git repo under root with a pinned identity, an empty
// global+system git config, and a .gitattributes disabling text conversion.
func NewFixture(root string) (*Fixture, error) {
	emptyGlobal := filepath.Join(root, ".global.gitconfig")
	if err := os.WriteFile(emptyGlobal, nil, 0o644); err != nil {
		return nil, err
	}
	emptySystem := filepath.Join(root, ".system.gitconfig")
	if err := os.WriteFile(emptySystem, nil, 0o644); err != nil {
		return nil, err
	}
	env := append(os.Environ(),
		"GIT_CONFIG_GLOBAL="+emptyGlobal,
		"GIT_CONFIG_SYSTEM="+emptySystem, // <-- closes the system core.autocrlf=true leak
		"GIT_CONFIG_COUNT=2",
		"GIT_CONFIG_KEY_0=safe.directory", "GIT_CONFIG_VALUE_0=*",
		"GIT_CONFIG_KEY_1=core.autocrlf", "GIT_CONFIG_VALUE_1=false",
	)
	fx := &Fixture{Root: root, env: env}
	// .gitattributes belongs INSIDE the repo so every git op sees it.
	if err := fx.WriteFile(".gitattributes", []byte("* -text\n")); err != nil {
		return nil, err
	}
	for _, args := range [][]string{
		{"init", "-q", "-b", "main"},
		{"config", "user.name", "bench"},
		{"config", "user.email", "bench@test.local"},
	} {
		if err := fx.Git(args...); err != nil {
			return nil, err
		}
	}
	if err := fx.WriteFile("README.md", []byte("bench fixture\n")); err != nil {
		return nil, err
	}
	if err := fx.Git("-c", "core.autocrlf=false", "add", ".gitattributes", "README.md"); err != nil {
		return nil, err
	}
	if err := fx.Git("-c", "core.autocrlf=false", "commit", "-q", "-m", "init"); err != nil {
		return nil, err
	}
	return fx, nil
}

// WriteFile writes rel (repo-relative, slash-separated) creating parents.
func (fx *Fixture) WriteFile(rel string, b []byte) error {
	p := filepath.Join(fx.Root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	return os.WriteFile(p, b, 0o644)
}

// Git runs git in the repo with the hardened env; returns combined output on error.
func (fx *Fixture) Git(args ...string) error {
	cmd := exec.Command("git", append([]string{"-C", fx.Root}, args...)...)
	cmd.Env = fx.env
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("git %v: %w\n%s", args, err, out)
	}
	return nil
}

// Env returns the hardened environment for running muster.exe in this repo.
func (fx *Fixture) Env() []string { return fx.env }

// ExeInfo is the provenance read back from a built binary.
type ExeInfo struct {
	GoVersion   string
	VCSRevision string
	VCSModified bool
}

// BuildMuster compiles ./cmd/muster from repoRoot into out, forcing VCS stamping,
// then reads the stamp back and fails loudly if it is absent.
func BuildMuster(repoRoot, out string) (ExeInfo, error) {
	cmd := exec.Command("go", "build", "-buildvcs=true", "-o", out, "./cmd/muster")
	cmd.Dir = repoRoot // MUST be the real repo (a copy has no .git -> silent no-stamp)
	if b, err := cmd.CombinedOutput(); err != nil {
		return ExeInfo{}, fmt.Errorf("go build: %w\n%s", err, b)
	}
	return ReadExeInfo(out)
}

// ReadExeInfo extracts go version + vcs settings from a built binary.
func ReadExeInfo(path string) (ExeInfo, error) {
	bi, err := buildinfo.ReadFile(path)
	if err != nil {
		return ExeInfo{}, err
	}
	info := ExeInfo{GoVersion: bi.GoVersion}
	for _, s := range bi.Settings {
		switch s.Key {
		case "vcs.revision":
			info.VCSRevision = s.Value
		case "vcs.modified":
			info.VCSModified = s.Value == "true"
		}
	}
	return info, nil
}
