package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"muster/internal/card"
)

var sidecarRx = regexp.MustCompile(`\.result\.md$|\.notes\.md$|\.verify\.log$|\.gen\d+\.`)

// Doctor implements `muster doctor`: chain verification, integrity check,
// stale claims, card/db drift, staging strays (spec CLI table).
func (a *App) Doctor() int {
	var findings []string
	fail := func(area, format string, args ...any) {
		findings = append(findings, "DOCTOR FAIL "+area+": "+fmt.Sprintf(format, args...))
	}

	// 1. sqlite integrity
	var integrity string
	if err := a.St.DB().QueryRow("PRAGMA integrity_check").Scan(&integrity); err != nil || integrity != "ok" {
		fail("sqlite", "integrity_check: %s %v", integrity, err)
	}
	// 2. event chain
	if err := a.St.VerifyChain(); err != nil {
		fail("events", "%v", err)
	}
	// 3-6. per-row checks
	for _, status := range []string{"backlog", "inbox", "doing", "done", "failed"} {
		rows, err := a.St.TasksByStatus(status)
		if err != nil {
			fail("query", "%v", err)
			continue
		}
		for _, t := range rows {
			abs := filepath.Join(a.Root, filepath.FromSlash(t.CardPath))
			if _, err := os.Stat(abs); err != nil {
				fail("cards", "%s has no file on disk (%s) - if it is an abandoned ingest, run: muster reconcile %s", t.ID, t.CardPath, t.ID)
			}
			if body, err := a.G.ShowAtHead(t.CardPath); err == nil {
				if c, errs := card.Parse(body, false); len(errs) == 0 && c.FrontmatterSHA != t.FrontmatterSHA {
					fail("drift", "%s frontmatter sha differs from HEAD - deliberate edits go through muster reimport", t.ID)
				}
			} else if status != "backlog" { // backlog cards may await the shard commit
				fail("cards", "%s not committed at HEAD", t.ID)
			}
			if status == "doing" {
				if t.ClaimedAt != "" {
					if then, err := time.Parse("2006-01-02T15:04:05Z", t.ClaimedAt); err == nil &&
						a.Now().UTC().Sub(then).Hours() > 24 {
						fail("claims", "%s doing since %s - stale claim, see RECOVERY", t.ID, t.ClaimedAt)
					}
				}
				if t.HeadAtClaim != "" {
					shas, err := a.G.LogGrep("^muster("+t.Plan+"): done "+t.ID+"$", t.HeadAtClaim+"..HEAD")
					if err == nil && len(shas) > 0 {
						fail("drift", "%s has a done commit but status doing - run muster claim to reconcile", t.ID)
					}
				}
			}
		}
	}
	// 7. orphan card files
	matches, _ := filepath.Glob(filepath.Join(a.Dir, "cards", "*.md"))
	for _, m := range matches {
		name := filepath.Base(m)
		if sidecarRx.MatchString(name) {
			continue
		}
		id := name[:len(name)-3]
		if t, _ := a.St.Task(id); t == nil {
			fail("cards", "%s has no board row - ingest it or delete it", name)
		}
	}
	// 8. staging strays
	for _, s := range a.stagedFiles() {
		fail("staging", "%s - stale staged fix from a crashed review session; safe to delete", filepath.Base(s))
	}

	if len(findings) == 0 {
		a.pf("DOCTOR OK - board consistent.")
		return 0
	}
	for _, f := range findings {
		a.pf("%s", f)
	}
	a.pf("DOCTOR: %d finding(s).", len(findings))
	return 1
}
