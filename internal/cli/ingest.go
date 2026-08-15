package cli

import (
	"os"
	"path/filepath"
	"strings"

	"muster/internal/card"
	"muster/internal/store"
)

// existsOnBoard is the lint resolver: an id resolves when it has a DB row.
func (a *App) existsOnBoard(id string) bool {
	t, err := a.St.Task(id)
	return err == nil && t != nil
}

// Ingest implements `muster ingest <files...>`: shard handoff. Lint gate first
// (full mode); on success one transaction inserts rows + deps, fail closed.
// Cards are inserted BEFORE the shard commit lands them - the printed reminder
// closes the loop (claim refuses uncommitted cards at the HEAD-read step).
func (a *App) Ingest(paths []string) int {
	if len(paths) == 0 {
		return a.refuse("ingest needs at least one card file path.")
	}
	var expanded []string
	for _, p := range paths {
		if strings.ContainsAny(p, "*?") {
			matches, err := filepath.Glob(p)
			if err != nil || len(matches) == 0 {
				return a.refuse("no card files match %s.", p)
			}
			expanded = append(expanded, matches...)
			continue
		}
		expanded = append(expanded, p)
	}
	paths = expanded
	cardsDir := filepath.ToSlash(filepath.Join(a.Dir, "cards"))
	for _, p := range paths {
		abs, err := filepath.Abs(p)
		if err != nil || !strings.HasPrefix(filepath.ToSlash(abs), cardsDir+"/") {
			return a.refuse("card files must live under .muster/cards/ (got %s).", p)
		}
	}
	findings := card.Lint(paths, a.existsOnBoard, card.Full)
	if len(findings) > 0 {
		for _, f := range findings {
			a.pf("LINT FAIL %s", f)
		}
		return 1
	}
	var batch []store.IngestTask
	for _, p := range paths {
		raw, err := os.ReadFile(p)
		if err != nil {
			return a.refuse("cannot read %s: %v", p, err)
		}
		c, errs := card.Parse(string(raw), false)
		if len(errs) > 0 { // unreachable after a clean lint; belt and braces
			return a.refuse("%s: %s", filepath.Base(p), errs[0])
		}
		abs, _ := filepath.Abs(p)
		rel, err := filepath.Rel(a.Root, abs)
		if err != nil {
			return a.refuse("cannot relativize %s: %v", p, err)
		}
		batch = append(batch, store.IngestTask{
			Task: store.Task{
				ID: c.ID, Plan: c.Plan, Seq: c.Seq, Type: c.Type, Tier: c.Tier,
				Harness: c.Harness, CardPath: filepath.ToSlash(rel),
				FrontmatterSHA: c.FrontmatterSHA, Reviews: c.Reviews, Fixes: c.Fixes,
			},
			Deps: c.DependsOn,
		})
	}
	if err := a.St.Ingest(batch, "shard", a.iso()); err != nil {
		return a.refuse("ingest failed: %v", err)
	}
	a.pf("INGEST OK %d task(s). Commit the card files now, then run: muster promote", len(batch))
	return 0
}
