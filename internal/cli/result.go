package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"muster/internal/card"
	"muster/internal/store"
)

type resultOpts struct {
	Status        string // done | failed | cycled
	Verdict       string // "" | pass | fail
	Attempts      int    // -1 = query AttemptsSinceClaim
	Probe         bool
	DoneCheckPass bool
	Surprises     string // override for the notes text (claim-probe auto-file)
	GenSuffix     string // ".gen<g>" for cycled review rounds, else ""
}

// changedSinceClaim = tracked diff against head_at_claim plus untracked new
// files (a bare diff misses exactly the normal impl output), sorted unique.
func (a *App) changedSinceClaim(t *store.Task) ([]string, error) {
	tracked, err := a.G.DiffNamesSince(t.HeadAtClaim)
	if err != nil {
		return nil, err
	}
	untracked, err := a.G.Untracked()
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var out []string
	for _, p := range append(tracked, untracked...) {
		if !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	sort.Strings(out)
	return out, nil
}

// writeResult assembles the result sidecar; everything above Surprises comes
// from git + the DB - the model only wrote notes. Returns the repo-relative
// sidecar path (forward slashes).
func (a *App) writeResult(t *store.Task, c *card.Card, o resultOpts) (string, error) {
	attempts := o.Attempts
	if attempts < 0 {
		n, err := a.St.AttemptsSinceClaim(t.ID)
		if err != nil {
			return "", err
		}
		attempts = n
	}
	verifyLine := fmt.Sprintf("verify: pass (attempt %d of 3)", attempts)
	if attempts == 0 {
		verifyLine = "verify: pass (done-check only)"
		if o.Probe {
			verifyLine = "verify: pass (claim-probe)"
		}
	}
	if !o.DoneCheckPass {
		verifyLine = "verify: FAIL (done-check red - see verify.log)"
	}
	chainHead, err := a.St.ChainHead()
	if err != nil {
		return "", err
	}
	lines := []string{"# Result: " + t.ID, "", "- status: " + o.Status}
	if o.Verdict != "" {
		lines = append(lines, "- verdict: "+o.Verdict)
	}
	lines = append(lines,
		"- head_at_claim: "+t.HeadAtClaim,
		"- claimed_at: "+t.ClaimedAt,
		"- completed_at: "+a.iso(),
		"- "+verifyLine,
		"- events_chain_head: "+chainHead,
		"- files_changed:")
	changed, err := a.changedSinceClaim(t)
	if err != nil {
		return "", err
	}
	for _, f := range changed {
		lines = append(lines, "  - "+f)
	}
	notes := "none reported"
	notesPath := filepath.Join(a.Dir, "cards", t.ID+".notes.md")
	if raw, err := os.ReadFile(notesPath); err == nil {
		notes = strings.TrimRight(string(raw), "\r\n")
	}
	if o.Surprises != "" {
		notes = o.Surprises
	}
	lines = append(lines, "", "## Surprises", "")
	if c.Type == "review" || c.Type == "integration" {
		lines = append(lines, "none reported", "", "## Findings", "", notes)
	} else {
		lines = append(lines, notes)
	}
	rel := ".muster/cards/" + t.ID + o.GenSuffix + ".result.md"
	abs := filepath.Join(a.Root, filepath.FromSlash(rel))
	if err := os.WriteFile(abs, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		return "", err
	}
	return rel, nil
}

// backupDB refreshes .muster/backup.db (survives `git clean -fd`; spec D-v2-4).
func (a *App) backupDB() error {
	return a.St.Backup(filepath.Join(a.Dir, "backup.db"))
}
