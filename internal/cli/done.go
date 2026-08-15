package cli

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"muster/internal/card"
	"muster/internal/store"
)

// crashPoint honors MUSTER_CRASH_POINT for the process tier's crash proofs.
func (a *App) crashPoint(point string) {
	if a.Getenv("MUSTER_CRASH_POINT") == point {
		fmt.Fprintln(a.Out, "MUSTER crash injection: "+point)
		os.Exit(97)
	}
}

func fileExistsAt(root, rel string) bool {
	_, err := os.Stat(filepath.Join(root, filepath.FromSlash(rel)))
	return err == nil
}

// donePreconditions ports v1 Test-DonePreconditions onto head_at_claim:
// protected fires on the TRACKED diff arm only (D30 - a newly created
// protected path is the sanctioned self-authoring case), scope spans both arms.
func (a *App) donePreconditions(t *store.Task, c *card.Card) (string, error) {
	tracked, err := a.G.DiffNamesSince(t.HeadAtClaim)
	if err != nil {
		return "", err
	}
	var hits []string
	for _, p := range tracked {
		if card.PathListed(p, c.Protected) {
			hits = append(hits, p)
		}
	}
	if len(hits) > 0 {
		return fmt.Sprintf("protected file(s) modified: %s. Revert them; the verify definition is not yours to change.",
			strings.Join(hits, ", ")), nil
	}
	changed, err := a.changedSinceClaim(t)
	if err != nil {
		return "", err
	}
	var extras []string
	for _, p := range changed {
		// A crashed done retry leaves this file; it is this command's own output.
		if !inScope(p, c.CommitPaths) && p != ".muster/cards/"+t.ID+".result.md" {
			extras = append(extras, p)
		}
	}
	if len(extras) > 0 {
		return fmt.Sprintf("changed outside commit_paths: %s. Revert strays or stop for a human.",
			strings.Join(extras, ", ")), nil
	}
	return "", nil
}

type passOpts struct {
	Verdict, Reason string
	DoneCheckPass   bool
	Probe           bool
	Surprises       string
}

// completePass is the pass-path machinery (also used by the claim probe's
// auto-file): result sidecar, explicit-path commit (commit-first), DB flip,
// verdict row on judgment pass, backup, promote, board line.
func (a *App) completePass(t *store.Task, c *card.Card, o passOpts) int {
	rel, err := a.writeResult(t, c, resultOpts{
		Status: "done", Verdict: o.Verdict, Attempts: -1,
		Probe: o.Probe, DoneCheckPass: o.DoneCheckPass, Surprises: o.Surprises,
	})
	if err != nil {
		return a.refuse("result sidecar failed: %v", err)
	}
	paths := []string{rel}
	for _, side := range []string{t.ID + ".notes.md", t.ID + ".verify.log"} {
		if p := ".muster/cards/" + side; fileExistsAt(a.Root, p) {
			paths = append(paths, p)
		}
	}
	for _, cp := range c.CommitPaths {
		if fileExistsAt(a.Root, cp) {
			paths = append(paths, cp)
		}
	}
	if err := a.G.Add(paths); err != nil {
		return a.refuse("git add failed: %v", err)
	}
	a.crashPoint("before-commit")
	msg := fmt.Sprintf("muster(%s): done %s", t.Plan, t.ID)
	if err := a.G.Commit(msg, paths); err != nil {
		return a.refuse("completion commit failed: %v. DB untouched (commit-first) - fix git state and rerun done.", err)
	}
	// Hooks are honored, never silently bypassed: one re-stage + amend cycle
	// absorbs a tree-mutating hook (Authority note 2).
	if dirty, err := a.G.DirtyPaths(); err == nil {
		var again []string
		for _, d := range dirty {
			if card.PathListed(d, paths) {
				again = append(again, d)
			}
		}
		if len(again) > 0 {
			a.G.Add(again)
			a.G.AmendNoEdit()
			if d2, err := a.G.DirtyPaths(); err == nil {
				for _, d := range d2 {
					if card.PathListed(d, paths) {
						return a.refuse("a git hook keeps mutating committed files (%s) - fix the hook, then rerun done.", d)
					}
				}
			}
		}
	}
	a.crashPoint("after-commit")
	if err := a.St.MarkDone(t.ID, t.ClaimedBy, a.iso()); err != nil {
		return a.refuse("commit landed but the DB flip failed (%v) - rerun any verb; the claim-time reconciler heals this.", err)
	}
	if (c.Type == "review" || c.Type == "integration") && o.Verdict == "pass" {
		a.St.InsertVerdict(t.ID, t.ClaimedBy, "pass", o.Reason, a.iso())
	}
	if err := a.backupDB(); err != nil {
		a.pf("MUSTER warn: backup.db refresh failed: %v", err)
	}
	promoted, _ := a.St.Promote("system", a.iso())
	if o.Probe {
		// the auto-file happens INSIDE a claim - the claim loop keeps going,
		// so no board line and no "Session over." here (it is the only stop
		// signal and this session is not over).
		return 0
	}
	plist := "none"
	if len(promoted) > 0 {
		plist = strings.Join(promoted, ", ")
	}
	if line, err := a.boardLine(); err == nil {
		fmt.Fprintln(a.Out, line)
	}
	a.pf("Done: %s. Promoted: %s. Do not claim another task. Session over.", t.ID, plist)
	return 0
}

// Done implements `muster done [pass|fail] [--reason <text>]`.
func (a *App) Done(args []string) int {
	verdict := ""
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		verdict = args[0]
		args = args[1:]
	}
	fs := flag.NewFlagSet("done", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	reason := fs.String("reason", "", "")
	_ = fs.Parse(args)

	t, c, code := a.occupant()
	if t == nil {
		return code
	}
	isJudgment := c.Type == "review" || c.Type == "integration"
	if !isJudgment && verdict != "" {
		return a.refuse("done takes no verdict on impl/fix tasks.")
	}
	if isJudgment && verdict != "pass" && verdict != "fail" {
		return a.refuse("done needs a pass or fail verdict on review/integration tasks.")
	}
	if verdict == "fail" && strings.TrimSpace(*reason) == "" {
		return a.refuse("done fail requires --reason \"<one line>\" (the reason lands in the verdicts table).")
	}
	// head_at_claim discipline: done refuses when history was rewritten under
	// the claim (spec D-v2-4).
	head, err := a.G.Head()
	if err != nil {
		return a.refuse("git rev-parse failed: %v", err)
	}
	ok, err := a.G.IsAncestor(t.HeadAtClaim, head)
	if err != nil || !ok {
		return a.refuse("HEAD is not a descendant of head_at_claim (%s) - history rewritten under a claim. Human recovery.", t.HeadAtClaim)
	}
	// confirmation verify - kills stale-pass; logged as done-check, never
	// counts. A fail verdict on a judgment task records a red done-check
	// instead of gating on it (D29): a broken build IS the finding.
	res, err := a.runBlock(t, c, "done-check")
	if err != nil {
		return a.refuse("verify runner failed: %v", err)
	}
	if !res.Pass && !(isJudgment && verdict == "fail") {
		return a.refuse("done-check verify failed: %s. Run muster verify, fix, and retry.", res.FirstFail)
	}
	if msg, err := a.donePreconditions(t, c); err != nil {
		return a.refuse("precondition check failed: %v", err)
	} else if msg != "" {
		return a.refuse("%s", msg)
	}
	if isJudgment && !fileExistsAt(a.Root, ".muster/cards/"+t.ID+".notes.md") {
		return a.refuse("verdict needs .muster/cards/%s.notes.md with findings.", t.ID)
	}
	if verdict == "fail" {
		if c.Type == "review" {
			return a.doneFailReview(t, c, *reason, res.Pass)
		}
		return a.doneFailIntegration(t, c, *reason, res.Pass)
	}
	return a.completePass(t, c, passOpts{Verdict: verdict, Reason: *reason, DoneCheckPass: res.Pass})
}
