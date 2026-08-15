package cli

import (
	"flag"
	"fmt"
	"io"
	"path"
	"strings"

	"muster/internal/card"
	"muster/internal/store"
)

// inScope: the claim/done scope rule (v1 spec 4.1.7/4.3.4, D27, re-homed).
// Under .muster/ only the executor-writable set is in scope: live notes,
// verify logs, and the staged fix. Everything else there is protocol surface.
// Outside .muster/, commit_paths is the whitelist. The db files are gitignored
// and never appear in porcelain output.
func inScope(p string, commitPaths []string) bool {
	for _, pat := range []string{".muster/cards/*.notes.md", ".muster/cards/*.verify.log", ".muster/staging/*.md"} {
		if ok, _ := path.Match(pat, p); ok {
			return true
		}
	}
	if p == ".muster" || strings.HasPrefix(p, ".muster/") {
		return false
	}
	return card.PathListed(p, commitPaths)
}

// headCard reads and parses the candidate's card from HEAD (hot-decision reads
// are HEAD reads - executor edits to the working-tree card stay inert), and
// files a warn event on a frontmatter sha mismatch (D-v2-2).
func (a *App) headCard(t *store.Task, actor string) (*card.Card, string, string) {
	body, err := a.G.ShowAtHead(t.CardPath)
	if err != nil {
		return nil, "", fmt.Sprintf("card %s is not committed at HEAD - commit the shard batch first.", t.CardPath)
	}
	c, errs := card.Parse(body, false)
	if len(errs) > 0 {
		return nil, "", fmt.Sprintf("%s card invalid at HEAD: %s. Human attention needed.", t.ID, errs[0])
	}
	if c.FrontmatterSHA != t.FrontmatterSHA {
		a.pf("MUSTER warn: %s frontmatter differs from the ingested copy - deliberate edits go through muster reimport.", t.ID)
		a.St.AppendEvent(t.ID, "system", "warn", "frontmatter sha mismatch", a.iso())
	}
	return c, body, ""
}

// reconcile heals rows stranded by a crash between done's commit and the DB
// flip: for each doing task, look for its done commit by message grammar in
// head_at_claim..HEAD (spec D-v2-4: status=done is derived).
func (a *App) reconcile() {
	doing, err := a.St.Doing()
	if err != nil {
		return
	}
	for _, t := range doing {
		if t.HeadAtClaim == "" {
			continue
		}
		shas, err := a.G.LogGrep("^muster("+t.Plan+"): done "+t.ID+"$", t.HeadAtClaim+"..HEAD")
		if err != nil || len(shas) == 0 {
			continue
		}
		if err := a.St.MarkDone(t.ID, "system", a.iso()); err == nil {
			a.pf("Reconciled %s: done commit found, row healed.", t.ID)
			a.St.Promote("system", a.iso())
		}
	}
}

// probe is the recovery probe (D12 re-homed): after claiming, when this task
// shows prior-claim evidence and is impl/fix, run its verify block; green
// means a crashed predecessor already finished the work - auto-file it via
// the normal pass machinery. Returns true when the task was auto-filed.
// Unlike v1 there is no precondition refusal branch here: head_at_claim was
// captured seconds ago at this claim, so the protected diff arm is empty by
// construction and the scope arm was already enforced by the dirty-tree check.
func (a *App) probe(t *store.Task, c *card.Card, identity string) bool {
	if c.Type != "impl" && c.Type != "fix" {
		return false
	}
	n, err := a.St.ClaimCount(t.ID)
	if err != nil || n < 2 {
		return false
	}
	res, err := a.runBlock(t, c, "claim-probe")
	if err != nil || !res.Pass {
		return false
	}
	row, err := a.St.Task(t.ID) // refetch: ClaimTask stamped the claim fields
	if err != nil || row == nil {
		return false
	}
	return a.completePass(row, c, passOpts{
		DoneCheckPass: true, Probe: true,
		Surprises: "auto-filed at claim: verify green before execution",
	}) == 0
}

// Claim implements `muster claim -harness X -tier Y`.
func (a *App) Claim(args []string) int {
	fs := flag.NewFlagSet("claim", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	harness := fs.String("harness", "", "")
	tier := fs.String("tier", "", "")
	_ = fs.Parse(args)
	if (*harness != "claude" && *harness != "codex") || (*tier != "any" && *tier != "strong") {
		return a.refuse("claim requires -harness <claude|codex> and -tier <any|strong> (the wrapper skill supplies them).")
	}
	identity := *harness + "/" + *tier

	// 1. heal crashed dones, then promotions dropped by a crashed predecessor
	a.reconcile()
	if _, err := a.St.Promote("system", a.iso()); err != nil {
		return a.refuse("promote failed: %v", err)
	}
	// 2. status print - fires before any refusal (CM-ORDER)
	if block, err := a.statusBlock(); err == nil {
		fmt.Fprintln(a.Out, block)
	}
	// 3. one executor per checkout
	doing, err := a.St.Doing()
	if err != nil {
		return a.refuse("board query failed: %v", err)
	}
	if len(doing) > 0 {
		age := "unknown"
		if doing[0].ClaimedAt != "" {
			age = ageString(a.Now().UTC(), doing[0].ClaimedAt)
		}
		return a.refuse("doing occupied by %s (claimed %s ago). One executor per checkout. RECOVERY in .muster/RUNNER.md.", doing[0].ID, age)
	}

	for {
		// 4. lowest eligible id; dependency order is the only order
		cand, err := a.St.NextEligible(*tier, *harness)
		if err != nil {
			return a.refuse("claim query failed: %v", err)
		}
		if cand == nil {
			return a.refuse("nothing to claim for %s.", identity)
		}
		c, body, refusal := a.headCard(cand, identity)
		if refusal != "" {
			return a.refuse("%s", refusal)
		}
		// 5. dirty-tree scope check, scoped to the candidate
		dirty, err := a.G.DirtyPaths()
		if err != nil {
			return a.refuse("git status failed: %v", err)
		}
		var outOfScope []string
		for _, p := range dirty {
			if !inScope(p, c.CommitPaths) {
				outOfScope = append(outOfScope, p)
			}
		}
		if len(outOfScope) > 0 {
			return a.refuse("working tree dirty outside %s's commit_paths: %s. Likely leftovers from a failed or crashed task - see RECOVERY (.muster/RUNNER.md), 'leftover dirt'.",
				cand.ID, strings.Join(outOfScope, ", "))
		}
		// 6. atomic claim: HEAD read outside the tx, nothing slow inside
		head, err := a.G.Head()
		if err != nil {
			return a.refuse("git rev-parse failed: %v", err)
		}
		ok, err := a.St.ClaimTask(cand.ID, identity, head, a.iso())
		if err == store.ErrDoingOccupied {
			return a.refuse("doing occupied - another session claimed first. One executor per checkout.")
		}
		if err != nil {
			return a.refuse("claim transaction failed: %v", err)
		}
		if !ok {
			continue // candidate raced away; take the next one
		}
		// 7. recovery probe (Task 17): auto-file finished work, then loop
		if a.probe(cand, c, identity) {
			a.pf("Auto-filed %s - a crashed predecessor already finished it (claim-probe green).", cand.ID)
			continue
		}
		// 8. print the card and hand over to RUNNER.md
		fmt.Fprintln(a.Out, strings.TrimRight(body, "\n"))
		a.pf("Claimed %s. Follow .muster/RUNNER.md.", cand.ID)
		return 0
	}
}
