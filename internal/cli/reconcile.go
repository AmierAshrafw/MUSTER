package cli

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"muster/internal/store"
)

// reconcileGitFails returns the failed git-side predicate messages for t's
// card. Any unexpected git error is returned (fail closed) - the caller must
// refuse, never treat an error as "absent".
func (a *App) reconcileGitFails(t *store.Task) ([]string, error) {
	var fails []string
	abs := filepath.Join(a.Root, filepath.FromSlash(t.CardPath))
	if _, err := os.Stat(abs); err == nil {
		fails = append(fails, fmt.Sprintf("card present in the worktree (%s)", t.CardPath))
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	inIndex, err := a.G.IndexHas(t.CardPath)
	if err != nil {
		return nil, err
	}
	if inIndex {
		fails = append(fails, "card is staged in the git index")
	}
	hist, err := a.G.PathHistory(t.CardPath)
	if err != nil {
		return nil, err
	}
	if len(hist) > 0 {
		fails = append(fails, fmt.Sprintf("card has git history (%d commit(s)) - it was committed before", len(hist)))
	}
	return fails, nil
}

// Reconcile implements `muster reconcile <id> [--execute] [--reason <text>]`.
func (a *App) Reconcile(args []string) int {
	var id string
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		id = args[0]
		args = args[1:]
	}
	fs := flag.NewFlagSet("reconcile", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	execute := fs.Bool("execute", false, "")
	reason := fs.String("reason", "", "")
	if err := fs.Parse(args); err != nil {
		return a.refuse("reconcile: %v", err)
	}
	if id == "" {
		return a.refuse("reconcile needs exactly one task id.")
	}

	t, err := a.St.Task(id)
	if err != nil {
		return a.refuse("reconcile query failed: %v", err)
	}
	if t == nil {
		if has, _ := a.St.HasTombstone(id); has {
			a.pf("Reconcile: %s already reconciled (tombstone present). Nothing to do.", id)
			return 0
		}
		return a.refuse("no task '%s' on the board.", id)
	}

	gitFails, err := a.reconcileGitFails(t)
	if err != nil {
		return a.refuse("reconcile git check failed: %v (treating as ineligible)", err)
	}
	info, dbFails, err := a.St.ReconcileEligibility(id)
	if err != nil {
		return a.refuse("reconcile db check failed: %v", err)
	}
	if info == nil { // row vanished between the Task() read and here (concurrent prune by another process)
		if has, _ := a.St.HasTombstone(id); has {
			a.pf("Reconcile: %s already reconciled (tombstone present). Nothing to do.", id)
			return 0
		}
		return a.refuse("no task '%s' on the board.", id)
	}
	fails := append(gitFails, dbFails...)

	if !*execute {
		a.pf("Reconcile dry-run for %s (status %s):", id, t.Status)
		if len(fails) == 0 {
			a.pf("  ELIGIBLE - abandoned-ingest orphan.")
			a.pf("  Would delete: task row %s + %d dep edge(s) %v", id, len(info.OutgoingDeps), info.OutgoingDeps)
			a.pf("  Would write a tombstone event (the id then refuses re-ingest).")
			a.pf("Run: muster reconcile %s --execute", id)
			return 0
		}
		a.pf("  INELIGIBLE - not a safe orphan:")
		for _, f := range fails {
			a.pf("    - %s", f)
		}
		return 1
	}

	if len(fails) > 0 {
		a.pf("MUSTER refuse: %s is not a safe orphan:", id)
		for _, f := range fails {
			a.pf("    - %s", f)
		}
		return 1
	}
	pruned, err := a.St.Reconcile(id, "human", *reason, a.iso())
	if err != nil {
		return a.refuse("reconcile failed: %v", err)
	}
	if !pruned {
		a.pf("Reconcile: %s already reconciled (tombstone present). Nothing to do.", id)
		return 0
	}
	a.pf("Reconciled %s: row and %d dep edge(s) pruned; tombstone written. The id is retired - re-ingesting it will refuse.", id, len(info.OutgoingDeps))
	return 0
}
