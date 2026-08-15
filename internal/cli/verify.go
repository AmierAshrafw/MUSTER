package cli

import (
	"fmt"
	"path/filepath"
	"strconv"

	"muster/internal/card"
	"muster/internal/store"
	"muster/internal/verify"
)

// occupant returns the sole doing task and its HEAD card, or a refusal exit
// code. Shared by verify and done.
func (a *App) occupant() (*store.Task, *card.Card, int) {
	doing, err := a.St.Doing()
	if err != nil {
		return nil, nil, a.refuse("board query failed: %v", err)
	}
	if len(doing) == 0 {
		return nil, nil, a.refuse("doing is empty - nothing in progress.")
	}
	if len(doing) > 1 {
		return nil, nil, a.refuse("doing holds %d tasks - one executor per checkout broke. RECOVERY in .muster/RUNNER.md.", len(doing))
	}
	t := doing[0]
	c, _, refusal := a.headCard(&t, t.ClaimedBy)
	if refusal != "" {
		return nil, nil, a.refuse("%s", refusal)
	}
	return &t, c, -1
}

// runBlock wraps the verify runner with app wiring (HEAD, clock, log path).
func (a *App) runBlock(t *store.Task, c *card.Card, label string) (verify.Result, error) {
	head, err := a.G.Head()
	if err != nil {
		return verify.Result{}, err
	}
	return verify.RunBlock(c.Verify, verify.BlockOpts{
		WorkDir: a.Root,
		LogPath: filepath.Join(a.Dir, "cards", t.ID+".verify.log"),
		Label:   label, TaskID: t.ID, Head: head,
		NowIso: a.iso,
	})
}

const terminalMsg = "VERIFY FAIL terminal. Task failed - card, sidecars, and working-tree dirt left as evidence. Session over."

// Verify implements `muster verify`.
func (a *App) Verify() int {
	t, c, code := a.occupant()
	if t == nil {
		return code
	}
	count, err := a.St.AttemptsSinceClaim(t.ID)
	if err != nil {
		return a.refuse("attempt query failed: %v", err)
	}
	if count >= 3 {
		a.St.MarkFailed(t.ID, t.ClaimedBy, "verify terminal", a.iso())
		fmt.Fprintln(a.Out, terminalMsg)
		return 3
	}
	n := count + 1
	// D28: the attempt burns BEFORE any command runs - killing the verify
	// mid-run still counts. The event row is the counter; the log is transcript.
	if err := a.St.AppendEvent(t.ID, t.ClaimedBy, "attempt", strconv.Itoa(n), a.iso()); err != nil {
		return a.refuse("cannot record the attempt - refusing to run unaccounted: %v", err)
	}
	res, err := a.runBlock(t, c, fmt.Sprintf("attempt %d", n))
	if err != nil {
		return a.refuse("verify runner failed: %v", err)
	}
	if res.Pass {
		a.pf("VERIFY PASS (attempt %d)", n)
		return 0
	}
	if n < 3 {
		a.pf("VERIFY FAIL (attempt %d of 3): %s. Fix and rerun.", n, res.FirstFail)
		return 2
	}
	a.St.MarkFailed(t.ID, t.ClaimedBy, "verify terminal", a.iso())
	fmt.Fprintln(a.Out, terminalMsg)
	return 3
}
