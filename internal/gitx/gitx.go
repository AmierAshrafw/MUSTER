// Package gitx is the one seam between MUSTER and git. Reads dominate; the
// only writes are Add/Commit/AmendNoEdit, used exclusively by done and init.
package gitx

import (
	"fmt"
	"os/exec"
	"strings"
)

type Git interface {
	Head() (string, error)
	Branch() (string, error)
	IsAncestor(ancestor, descendant string) (bool, error)
	ShowAtHead(relPath string) (string, error) // errors when absent at HEAD
	DirtyPaths() ([]string, error)             // worktree+index, untracked=all, rename both sides
	DiffNamesSince(commit string) ([]string, error)
	Untracked() ([]string, error)
	IndexHas(relPath string) (bool, error)        // path tracked in the index (staged or committed)
	PathHistory(relPath string) ([]string, error) // commit SHAs that ever touched relPath, newest first
	Add(paths []string) error
	AddForce(paths []string) error           // -f: for MUSTER-owned artifacts the repo .gitignore may match
	Commit(msg string, paths []string) error // explicit pathspec, -c core.autocrlf=false
	AmendNoEdit() error
	LogGrep(grep, rangeSpec string) ([]string, error) // commit SHAs, newest first
	UserConfigured() (bool, error)
}

// FindRoot resolves the repo root from dir, or an error outside a repository.
func FindRoot(dir string) (string, error) {
	out, err := exec.Command("git", "-C", dir, "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return "", fmt.Errorf("not inside a git repository")
	}
	return strings.TrimSpace(string(out)), nil
}

// Repo is the real implementation, rooted at Dir.
type Repo struct{ Dir string }

func (r *Repo) git(args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", r.Dir}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("git %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

func (r *Repo) lines(args ...string) ([]string, error) {
	out, err := r.git(args...)
	if err != nil {
		return nil, err
	}
	var res []string
	for _, l := range strings.Split(out, "\n") {
		if strings.TrimRight(l, "\r") != "" {
			res = append(res, strings.TrimRight(l, "\r"))
		}
	}
	return res, nil
}

func (r *Repo) Head() (string, error) {
	out, err := r.git("rev-parse", "HEAD")
	return strings.TrimSpace(out), err
}

func (r *Repo) Branch() (string, error) {
	out, err := r.git("rev-parse", "--abbrev-ref", "HEAD")
	return strings.TrimSpace(out), err
}

func (r *Repo) IsAncestor(ancestor, descendant string) (bool, error) {
	cmd := exec.Command("git", "-C", r.Dir, "merge-base", "--is-ancestor", ancestor, descendant)
	err := cmd.Run()
	if err == nil {
		return true, nil
	}
	if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 1 {
		return false, nil
	}
	return false, err
}

func (r *Repo) ShowAtHead(relPath string) (string, error) {
	return r.git("show", "HEAD:"+relPath)
}

func (r *Repo) DirtyPaths() ([]string, error) {
	ls, err := r.lines("status", "--porcelain", "--untracked-files=all")
	if err != nil {
		return nil, err
	}
	return ParsePorcelain(ls), nil
}

func (r *Repo) DiffNamesSince(commit string) ([]string, error) {
	return r.lines("-c", "core.autocrlf=false", "diff", "--name-only", commit)
}

func (r *Repo) Untracked() ([]string, error) {
	return r.lines("ls-files", "--others", "--exclude-standard")
}

func (r *Repo) IndexHas(relPath string) (bool, error) {
	out, err := r.git("-c", "core.autocrlf=false", "ls-files", "--", relPath)
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(out) != "", nil
}

func (r *Repo) PathHistory(relPath string) ([]string, error) {
	return r.lines("-c", "core.autocrlf=false", "log", "--format=%H", "--", relPath)
}

func (r *Repo) Add(paths []string) error {
	_, err := r.git(append([]string{"-c", "core.autocrlf=false", "add", "--"}, paths...)...)
	return err
}

func (r *Repo) AddForce(paths []string) error {
	_, err := r.git(append([]string{"-c", "core.autocrlf=false", "add", "-f", "--"}, paths...)...)
	return err
}

func (r *Repo) Commit(msg string, paths []string) error {
	_, err := r.git(append([]string{"-c", "core.autocrlf=false", "commit", "-q", "-m", msg, "--"}, paths...)...)
	return err
}

func (r *Repo) AmendNoEdit() error {
	_, err := r.git("-c", "core.autocrlf=false", "commit", "-q", "--amend", "--no-edit")
	return err
}

func (r *Repo) LogGrep(grep, rangeSpec string) ([]string, error) {
	return r.lines("log", "--format=%H", "--grep", grep, rangeSpec)
}

func (r *Repo) UserConfigured() (bool, error) {
	for _, key := range []string{"user.name", "user.email"} {
		out, err := exec.Command("git", "-C", r.Dir, "config", key).Output()
		if err != nil || strings.TrimSpace(string(out)) == "" {
			return false, nil
		}
	}
	return true, nil
}

// ParsePorcelain converts `status --porcelain` lines to repo-relative paths.
// Rename lines yield both sides; surrounding quotes are stripped.
func ParsePorcelain(lines []string) []string {
	var paths []string
	for _, line := range lines {
		if len(line) < 4 {
			continue
		}
		p := line[3:]
		if i := strings.Index(p, " -> "); i >= 0 {
			paths = append(paths, strings.Trim(p[:i], `"`), strings.Trim(p[i+4:], `"`))
			continue
		}
		paths = append(paths, strings.Trim(p, `"`))
	}
	return paths
}
