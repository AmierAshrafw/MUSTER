// cmd/musterbench/main.go
package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"muster/internal/bench"
)

func parseNSet(s string) ([]int, error) {
	var out []int
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		v, err := strconv.Atoi(part)
		if err != nil {
			return nil, fmt.Errorf("invalid N %q: %w", part, err)
		}
		out = append(out, v)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("empty N set")
	}
	return out, nil
}

func main() {
	record := flag.Bool("record", false, "persist results (JSONL + benchfmt + archive + docs/bench.md)")
	nSet := flag.String("n", "10,100,1000", "comma-separated task counts")
	archiveExe := flag.String("archive-exe", "", "prebuilt exe to benchmark + archive (safe default for an official baseline)")
	allowDirty := flag.Bool("allow-dirty", false, "permit --record from a dirty working tree (stamps vcs_modified=true)")
	flag.Parse()

	ns, err := parseNSet(*nSet)
	if err != nil {
		fmt.Fprintln(os.Stderr, "musterbench:", err)
		os.Exit(2)
	}
	if code := run(runOpts{Record: *record, NSet: ns, ArchiveExe: *archiveExe, AllowDirty: *allowDirty}); code != 0 {
		os.Exit(code)
	}
}

type runOpts struct {
	Record     bool
	NSet       []int
	ArchiveExe string
	AllowDirty bool
}

// run orchestrates the suite. Dry run prints; --record persists. Dirty-tree
// policy: a build-from-tree --record refuses on a dirty tree unless --allow-dirty.
func run(o runOpts) int {
	repoRoot, err := os.Getwd()
	if err != nil {
		fmt.Fprintln(os.Stderr, "musterbench:", err)
		return 1
	}
	if o.Record && o.ArchiveExe == "" && !o.AllowDirty {
		dirty, err := treeDirty(repoRoot)
		if err != nil {
			fmt.Fprintln(os.Stderr, "musterbench: git status failed:", err)
			return 1
		}
		if dirty {
			fmt.Fprintln(os.Stderr, "musterbench: refusing --record from a dirty tree "+
				"(provenance hole). Commit first, pass --archive-exe <clean exe>, or --allow-dirty.")
			return 1
		}
	}
	fmt.Printf("musterbench: record=%v n=%v (orchestration wired in Task 15)\n", o.Record, o.NSet)
	_ = bench.SchemaVersion
	return 0
}

// treeDirty reports whether the working tree has uncommitted changes.
func treeDirty(root string) (bool, error) {
	cmd := exec.Command("git", "-C", root, "status", "--porcelain")
	out, err := cmd.Output()
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(string(out)) != "", nil
}
