package cli

import (
	"flag"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"muster/internal/store"
)

const v2Pointer = "Task board: .muster/ is managed by MUSTER v2. Executors follow .muster/RUNNER.md exactly. All board state lives in .muster/muster.db; the muster CLI owns every state transition and every board commit. Never edit .muster/ contents or the database by hand."

const v1Pointer = "Task board: `tasks/` is managed by MUSTER. Executors follow `tasks/RUNNER.md` exactly. Never edit files under `tasks/` by hand; the `tasks/bin/` scripts own all state transitions."

const stubPs1 = "Write-Output 'MUSTER refuse: v1 board decommissioned - this repo is managed by MUSTER v2 (.muster/ + muster CLI). See .muster/RUNNER.md.'\nexit 1\n"
const stubSh = "echo 'MUSTER refuse: v1 board decommissioned - this repo is managed by MUSTER v2 (.muster/ + muster CLI). See .muster/RUNNER.md.'\nexit 1\n"

// v1LiveFiles applies v1's own task-file semantics (spec D-v2-3): *.md minus
// *.result.md/*.notes.md in the five live folders, plus plan snapshots at the
// tasks root. Returns repo-relative paths, sorted.
func v1LiveFiles(root string) []string {
	var live []string
	for _, folder := range []string{"inbox", "backlog", "doing", "staging", "failed"} {
		matches, _ := filepath.Glob(filepath.Join(root, "tasks", folder, "*.md"))
		for _, m := range matches {
			name := filepath.Base(m)
			if strings.HasSuffix(name, ".result.md") || strings.HasSuffix(name, ".notes.md") {
				continue
			}
			live = append(live, "tasks/"+folder+"/"+name)
		}
	}
	matches, _ := filepath.Glob(filepath.Join(root, "tasks", "plan-*.md"))
	for _, m := range matches {
		live = append(live, "tasks/"+filepath.Base(m))
	}
	sort.Strings(live)
	return live
}

// Init implements `muster init` (spec CLI table).
func (a *App) Init(args []string) int {
	fs := flag.NewFlagSet("init", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	syncOK := fs.Bool("sync-ok", false, "")
	_ = fs.Parse(args)

	// preflight
	if ok, err := a.G.UserConfigured(); err != nil || !ok {
		return a.refuse("git identity missing - set user.name and user.email (the muster binary commits).")
	}
	if _, err := os.Stat(a.Dir); err == nil {
		return a.refuse(".muster/ already exists - MUSTER v2 appears installed. Nothing changed.")
	}
	if !*syncOK {
		for _, s := range []string{"OneDrive", "Dropbox", "Google Drive"} {
			if strings.Contains(a.Root, s) {
				return a.refuse("repo sits under a sync engine (%s) - sync duplication corrupts boards. Rerun with -sync-ok to accept the risk.", s)
			}
		}
	}
	hasV1 := false
	if _, err := os.Stat(filepath.Join(a.Root, "tasks", "bin")); err == nil {
		hasV1 = true
	}
	if hasV1 {
		if live := v1LiveFiles(a.Root); len(live) > 0 {
			for _, f := range live {
				a.pf("  live: %s", f)
			}
			return a.refuse("v1 board is live (%d task files above). Finish or /muster:close the v1 plans, then rerun muster init.", len(live))
		}
	}

	// install
	for _, d := range []string{"cards", "staging", "plans"} {
		if err := os.MkdirAll(filepath.Join(a.Dir, d), 0o755); err != nil {
			return a.refuse("cannot create .muster/%s: %v", d, err)
		}
	}
	writes := map[string]string{
		".gitignore":     GitignoreTemplate,
		".gitattributes": GitattributesTemplate,
		"RUNNER.md":      RunnerMD,
	}
	for name, content := range writes {
		if err := os.WriteFile(filepath.Join(a.Dir, name), []byte(content), 0o644); err != nil {
			return a.refuse("cannot write .muster/%s: %v", name, err)
		}
	}
	st, err := store.Open(filepath.Join(a.Dir, "muster.db"))
	if err != nil {
		return a.refuse("cannot create board db: %v", err)
	}
	defer st.Close()
	if a.St == nil {
		a.St = st
	} else {
		st.Close()
	}

	commitPaths := []string{".muster/.gitignore", ".muster/.gitattributes", ".muster/RUNNER.md"}

	// decommission a dead v1 tree (spec D-v2-3: close the stale-dispatch window)
	decommissioned := []string{}
	if hasV1 {
		matches, _ := filepath.Glob(filepath.Join(a.Root, "tasks", "bin", "*.ps1"))
		for _, m := range matches {
			os.WriteFile(m, []byte(stubPs1), 0o644)
			rel := "tasks/bin/" + filepath.Base(m)
			decommissioned = append(decommissioned, rel)
		}
		matches, _ = filepath.Glob(filepath.Join(a.Root, "tasks", "bin", "*.sh"))
		for _, m := range matches {
			os.WriteFile(m, []byte(stubSh), 0o644)
			rel := "tasks/bin/" + filepath.Base(m)
			decommissioned = append(decommissioned, rel)
		}
		commitPaths = append(commitPaths, decommissioned...)
	}

	// CLAUDE.md pointer: replace the v1 paragraph when present, else append
	claudePath := filepath.Join(a.Root, "CLAUDE.md")
	existing := ""
	if raw, err := os.ReadFile(claudePath); err == nil {
		existing = string(raw)
	}
	if strings.Contains(existing, v1Pointer) {
		existing = strings.Replace(existing, v1Pointer, v2Pointer, 1)
	} else {
		if existing != "" && !strings.HasSuffix(existing, "\n") {
			existing += "\n"
		}
		if existing != "" {
			existing += "\n"
		}
		existing += v2Pointer + "\n"
	}
	if err := os.WriteFile(claudePath, []byte(existing), 0o644); err != nil {
		return a.refuse("cannot write CLAUDE.md: %v", err)
	}
	commitPaths = append(commitPaths, "CLAUDE.md")

	if err := a.G.Add(commitPaths); err != nil {
		return a.refuse("git add failed: %v", err)
	}
	if err := a.G.Commit("muster: init", commitPaths); err != nil {
		return a.refuse("init commit failed: %v", err)
	}

	// report
	a.pf("MUSTER v2 installed: .muster/ (cards, staging, plans, RUNNER.md, muster.db).")
	if len(decommissioned) > 0 {
		a.pf("v1 decommissioned: %d scripts stubbed under tasks/bin/, CLAUDE.md pointer rewritten.", len(decommissioned))
	}
	hooks, _ := filepath.Glob(filepath.Join(a.Root, ".git", "hooks", "*"))
	var active []string
	for _, h := range hooks {
		if !strings.HasSuffix(h, ".sample") {
			active = append(active, filepath.Base(h))
		}
	}
	if len(active) > 0 {
		a.pf("Active git hooks detected: %s. Hooks are honored - a tree-mutating hook costs done one re-stage cycle.", strings.Join(active, ", "))
	}
	a.pf("Recommended: add a Windows Defender exclusion for this repo (commit latency is Defender-dominated).")
	a.pf("Dispatch lines:")
	a.pf("  executor: muster claim -harness claude -tier any")
	a.pf("  reviewer: muster claim -harness claude -tier strong")
	return 0
}
