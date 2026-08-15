package cli

import (
	"os"
	"path/filepath"

	"muster/internal/card"
)

// Redo implements `muster redo <id>`: doing/failed -> inbox, fresh attempts.
func (a *App) Redo(args []string) int {
	if len(args) != 1 {
		return a.refuse("redo needs exactly one task id.")
	}
	id := args[0]
	if t, err := a.St.Task(id); err != nil || t == nil {
		return a.refuse("no task '%s' on the board.", id)
	}
	if err := a.St.MarkInbox(id, "human", a.iso()); err != nil {
		return a.refuse("cannot redo %s: %v (redo takes a doing or failed task).", id, err)
	}
	a.pf("Redo: %s back in inbox with a fresh attempt budget. Leave the working tree alone - the next claim's probe auto-files finished work.", id)
	return 0
}

// Fail implements `muster fail <id>`: give up, keep the evidence.
func (a *App) Fail(args []string) int {
	if len(args) != 1 {
		return a.refuse("fail needs exactly one task id.")
	}
	id := args[0]
	if t, err := a.St.Task(id); err != nil || t == nil {
		return a.refuse("no task '%s' on the board.", id)
	}
	if err := a.St.MarkFailed(id, "human", "human fail verb", a.iso()); err != nil {
		return a.refuse("cannot fail %s: %v.", id, err)
	}
	a.pf("Failed: %s. Card, sidecars, and any working-tree dirt left in place as evidence.", id)
	return 0
}

// Reimport implements `muster reimport <id>`: the sanctioned card-edit path -
// re-lint (single mode), re-hash, refresh the denormalized copy and deps.
func (a *App) Reimport(args []string) int {
	if len(args) != 1 {
		return a.refuse("reimport needs exactly one task id.")
	}
	id := args[0]
	t, err := a.St.Task(id)
	if err != nil || t == nil {
		return a.refuse("no task '%s' on the board.", id)
	}
	if t.Status == "doing" {
		return a.refuse("cannot reimport a claimed task - finish or redo it first.")
	}
	abs := filepath.Join(a.Root, filepath.FromSlash(t.CardPath))
	if _, err := os.Stat(abs); err != nil {
		return a.refuse("card file missing on disk: %s.", t.CardPath)
	}
	notSelf := func(x string) bool { return x != id && a.existsOnBoard(x) }
	if findings := card.Lint([]string{abs}, notSelf, card.Single); len(findings) > 0 {
		for _, f := range findings {
			a.pf("LINT FAIL %s", f)
		}
		return 1
	}
	raw, err := os.ReadFile(abs)
	if err != nil {
		return a.refuse("cannot read %s: %v", t.CardPath, err)
	}
	c, errs := card.Parse(string(raw), false)
	if len(errs) > 0 {
		return a.refuse("%s: %s", id, errs[0])
	}
	if err := a.St.UpdateCard(id, c.Seq, c.Type, c.Tier, c.Harness, c.FrontmatterSHA,
		c.Reviews, c.Fixes, c.DependsOn, "human", a.iso()); err != nil {
		return a.refuse("reimport failed: %v", err)
	}
	a.pf("Reimported %s: card re-linted and re-hashed. Commit the card edit if you have not already.", id)
	return 0
}
