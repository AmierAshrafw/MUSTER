package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func ageString(now time.Time, iso string) string {
	then, err := time.Parse("2006-01-02T15:04:05Z", iso)
	if err != nil {
		return "unknown"
	}
	d := now.Sub(then)
	switch {
	case d.Hours() >= 24:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	case d.Hours() >= 1:
		return fmt.Sprintf("%dh", int(d.Hours()))
	default:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	}
}

// statusBlock renders the v1 spec 8.3 board print from DB state.
func (a *App) statusBlock() (string, error) {
	b, err := a.St.Board()
	if err != nil {
		return "", err
	}
	if b.Total() == 0 {
		return "MUSTER: board empty - nothing ingested.", nil
	}
	branch, err := a.G.Branch()
	if err != nil {
		branch = "?"
	}
	var lines []string
	lines = append(lines, fmt.Sprintf("MUSTER status @ %s (%s)", filepath.Base(a.Root), branch))
	split := fmt.Sprintf("run %d, review %d", b.InboxRun, b.InboxReview)
	lines = append(lines, fmt.Sprintf("  inbox    %d ready      (%s) [%s]",
		len(b.InboxIDs), split, strings.Join(b.InboxIDs, ", ")))
	doingCell := ""
	for _, d := range b.Doing {
		age := "unknown"
		stale := ""
		if d.ClaimedAt != "" {
			age = ageString(a.Now().UTC(), d.ClaimedAt)
			if then, err := time.Parse("2006-01-02T15:04:05Z", d.ClaimedAt); err == nil &&
				a.Now().UTC().Sub(then).Hours() > 24 {
				stale = "        <- STALE: see .muster/RUNNER.md RECOVERY"
			}
		}
		doingCell = fmt.Sprintf("[%s claimed %s]%s", d.ID, age, stale)
	}
	lines = append(lines, strings.TrimRight(fmt.Sprintf("  doing    %d            %s", len(b.Doing), doingCell), " "))
	deadCell := ""
	if len(b.Dead) > 0 {
		deadCell = fmt.Sprintf("    (%d DEAD: %s)", len(b.Dead), strings.Join(b.Dead, "; "))
	}
	lines = append(lines, strings.TrimRight(fmt.Sprintf("  backlog  %d blocked%s", b.Backlog, deadCell), " "))
	lines = append(lines, strings.TrimRight(fmt.Sprintf("  failed   %d            [%s]", b.Failed, strings.Join(b.FailedIDs, ", ")), " "))
	lines = append(lines, fmt.Sprintf("  done     %d", b.Done))
	return strings.Join(lines, "\n"), nil
}

// boardLine is the counts-only summary done prints (v1 spec 4.3). No task ids.
func (a *App) boardLine() (string, error) {
	b, err := a.St.Board()
	if err != nil {
		return "", err
	}
	parts := []string{
		fmt.Sprintf("run %d", b.InboxRun),
		fmt.Sprintf("review %d", b.InboxReview),
	}
	backlogCell := fmt.Sprintf("backlog %d", b.Backlog)
	if len(b.Dead) > 0 {
		backlogCell += fmt.Sprintf(" (%d DEAD)", len(b.Dead))
	}
	parts = append(parts, backlogCell,
		fmt.Sprintf("failed %d", b.Failed),
		fmt.Sprintf("done %d", b.Done))
	return "Board: " + strings.Join(parts, " | "), nil
}

// Board implements `muster board`.
func (a *App) Board() int {
	block, err := a.statusBlock()
	if err != nil {
		return a.refuse("board query failed: %v", err)
	}
	fmt.Fprintln(a.Out, block)
	return 0
}

// Show implements `muster show <id>`: card body from disk plus the DB view.
func (a *App) Show(args []string) int {
	if len(args) != 1 {
		return a.refuse("show needs exactly one task id.")
	}
	t, err := a.St.Task(args[0])
	if err != nil {
		return a.refuse("show query failed: %v", err)
	}
	if t == nil {
		return a.refuse("no task '%s' on the board.", args[0])
	}
	if body, err := os.ReadFile(filepath.Join(a.Root, filepath.FromSlash(t.CardPath))); err == nil {
		fmt.Fprintln(a.Out, strings.TrimRight(string(body), "\n"))
	} else {
		a.pf("(card file missing on disk: %s)", t.CardPath)
	}
	a.pf("")
	a.pf("- status: %s", t.Status)
	a.pf("- tier: %s | type: %s | plan: %s | generation: %d", t.Tier, t.Type, t.Plan, t.Generation)
	if t.ClaimedAt != "" {
		a.pf("- claimed: %s by %s (head %s)", t.ClaimedAt, t.ClaimedBy, t.HeadAtClaim)
	}
	deps, _ := a.St.Deps(t.ID)
	if len(deps) > 0 {
		a.pf("- depends_on: %s", strings.Join(deps, ", "))
	}
	evs, _ := a.St.Events(t.ID)
	a.pf("- events:")
	for _, e := range evs {
		line := fmt.Sprintf("  - %s %s %s", e.CreatedAt, e.Actor, e.Verb)
		if e.Detail != "" {
			line += " (" + e.Detail + ")"
		}
		a.pf("%s", line)
	}
	vs, _ := a.St.Verdicts(t.ID)
	for _, v := range vs {
		a.pf("- verdict: %s by %s: %s", v.Verdict, v.Reviewer, v.Reason)
	}
	return 0
}
