package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"muster/internal/card"
	"muster/internal/store"
)

var fixStemRx = regexp.MustCompile(`^(.+-\d{2})-fix-(.+)\.md$`)
var fixGenRx = regexp.MustCompile(`-fix(\d+)-`)
var idLineRx = regexp.MustCompile(`(?m)^id: .*$`)

func (a *App) stagedFiles() []string {
	matches, _ := filepath.Glob(filepath.Join(a.Dir, "staging", "*.md"))
	return matches
}

// failCommitAndFile: shared terminal filing for the review cap and the
// integration fail - result sidecar with the fail verdict, one commit of the
// sidecars (commit-first), then MarkFailed + verdict row + backup.
func (a *App) failCommitAndFile(t *store.Task, c *card.Card, reason string, doneCheckPass bool) int {
	rel, err := a.writeResult(t, c, resultOpts{Status: "failed", Verdict: "fail", Attempts: -1, DoneCheckPass: doneCheckPass})
	if err != nil {
		return a.refuse("result sidecar failed: %v", err)
	}
	paths := []string{rel}
	for _, side := range []string{t.ID + ".notes.md", t.ID + ".verify.log"} {
		if p := ".muster/cards/" + side; fileExistsAt(a.Root, p) {
			paths = append(paths, p)
		}
	}
	if err := a.G.AddForce(paths); err != nil {
		return a.refuse("git add failed: %v", err)
	}
	if err := a.G.Commit(fmt.Sprintf("muster(%s): fail %s", t.Plan, t.ID), paths); err != nil {
		return a.refuse("fail commit failed: %v. DB untouched - fix git state and rerun.", err)
	}
	if err := a.St.MarkFailed(t.ID, t.ClaimedBy, reason, a.iso()); err != nil {
		return a.refuse("commit landed but the DB flip failed: %v", err)
	}
	a.St.InsertVerdict(t.ID, t.ClaimedBy, "fail", reason, a.iso())
	a.backupDB()
	return -1 // caller prints its terminal line and exit code
}

// resumeReject: crash-resume for the reject path (Authority note 7). A
// committed, stamped fix card targeting the reviewed impl with no DB row
// means the reject commit landed and the DB half was lost - complete it.
func (a *App) resumeReject(t *store.Task, reason string) (bool, int) {
	matches, _ := filepath.Glob(filepath.Join(a.Dir, "cards", "*.md"))
	for _, m := range matches {
		raw, err := os.ReadFile(m)
		if err != nil {
			continue
		}
		fc, errs := card.Parse(string(raw), true)
		if len(errs) > 0 || fc.Type != "fix" || fc.Fixes != t.Reviews {
			continue
		}
		if row, _ := a.St.Task(fc.ID); row != nil {
			continue // already recorded
		}
		gm := fixGenRx.FindStringSubmatch(fc.ID)
		if gm == nil {
			continue // unstamped stray; doctor's territory
		}
		g := 0
		fmt.Sscanf(gm[1], "%d", &g)
		rel, _ := filepath.Rel(a.Root, m)
		fixRow := store.IngestTask{Task: store.Task{
			ID: fc.ID, Plan: fc.Plan, Seq: fc.Seq, Type: fc.Type, Tier: fc.Tier,
			Harness: fc.Harness, CardPath: filepath.ToSlash(rel),
			FrontmatterSHA: fc.FrontmatterSHA, Fixes: fc.Fixes,
		}, Deps: fc.DependsOn}
		if err := a.St.CycleReview(t.ID, t.ClaimedBy, reason, fixRow, g, a.iso()); err != nil {
			return true, a.refuse("crash-resume failed: %v", err)
		}
		a.backupDB()
		a.pf("Resumed crashed done fail: fix %s queued (generation %d of 2). Session over.", fc.ID, g)
		return true, 0
	}
	return false, 0
}

// doneFailReview: spec D-v2-5. Verdict + one staged fix -> lint-lite ->
// generation cap -> stamp -> reject commit -> DB cycle.
func (a *App) doneFailReview(t *store.Task, c *card.Card, reason string, doneCheckPass bool) int {
	implID := c.Reviews
	staged := a.stagedFiles()
	if len(staged) == 0 {
		if resumed, code := a.resumeReject(t, reason); resumed {
			return code
		}
	}
	if len(staged) != 1 {
		return a.refuse("done fail needs exactly one valid fix task in .muster/staging/ (found %d files). File left in place - fix it and rerun.", len(staged))
	}
	findings := card.Lint([]string{staged[0]}, a.existsOnBoard, card.Lite)
	raw, err := os.ReadFile(staged[0])
	if err != nil {
		return a.refuse("cannot read staged fix: %v", err)
	}
	fix, errs := card.Parse(string(raw), true)
	if len(errs) == 0 && fix.Fixes != implID {
		findings = append([]string{fmt.Sprintf("fixes '%s' does not match reviews '%s'", fix.Fixes, implID)}, findings...)
	}
	if len(findings) > 0 {
		return a.refuse("done fail needs exactly one valid fix task in .muster/staging/ (%s). File left in place - fix it and rerun.", findings[0])
	}
	// generation cap: two landed generations = human territory (D11)
	g, err := a.St.FixGeneration(implID)
	if err != nil {
		return a.refuse("generation query failed: %v", err)
	}
	if g >= 3 {
		os.Remove(staged[0])
		if code := a.failCommitAndFile(t, c, reason, doneCheckPass); code != -1 {
			return code
		}
		a.pf("Review cap hit (2 fix generations). %s chain needs a human. Session over.", implID)
		return 3
	}
	// stamp: filename, id line, title (generation stays OUT of frontmatter)
	base := filepath.Base(staged[0])
	m := fixStemRx.FindStringSubmatch(base)
	if m == nil {
		return a.refuse("staged fix filename malformed: %s.", base)
	}
	fixID := fmt.Sprintf("%s-fix%d-%s", m[1], g, m[2])
	text := string(raw)
	text = idLineRx.ReplaceAllString(text, "id: "+fixID)
	text = strings.Replace(text, "# "+fix.ID+":", "# "+fixID+":", 1)
	fixRel := ".muster/cards/" + fixID + ".md"
	if err := os.WriteFile(filepath.Join(a.Root, filepath.FromSlash(fixRel)), []byte(text), 0o644); err != nil {
		return a.refuse("cannot write stamped fix card: %v", err)
	}
	os.Remove(staged[0])
	// this round's sidecars become gen-suffixed history (plain renames: none
	// of these files are tracked yet)
	genSuffix := fmt.Sprintf(".gen%d", g)
	logOld := filepath.Join(a.Dir, "cards", t.ID+".verify.log")
	logNewRel := ".muster/cards/" + t.ID + genSuffix + ".verify.log"
	hadLog := false
	if _, err := os.Stat(logOld); err == nil {
		os.Rename(logOld, filepath.Join(a.Root, filepath.FromSlash(logNewRel)))
		hadLog = true
	}
	genResultRel, err := a.writeResult(t, c, resultOpts{Status: "cycled", Verdict: "fail",
		Attempts: -1, DoneCheckPass: doneCheckPass, GenSuffix: genSuffix})
	if err != nil {
		return a.refuse("gen result sidecar failed: %v", err)
	}
	notesOld := filepath.Join(a.Dir, "cards", t.ID+".notes.md")
	notesNewRel := ".muster/cards/" + t.ID + genSuffix + ".notes.md"
	hadNotes := false
	if _, err := os.Stat(notesOld); err == nil {
		os.Rename(notesOld, filepath.Join(a.Root, filepath.FromSlash(notesNewRel)))
		hadNotes = true
	}
	// ONE reject commit (commit-first)
	paths := []string{fixRel, genResultRel}
	if hadLog {
		paths = append(paths, logNewRel)
	}
	if hadNotes {
		paths = append(paths, notesNewRel)
	}
	if err := a.G.AddForce(paths); err != nil {
		return a.refuse("git add failed: %v", err)
	}
	if err := a.G.Commit(fmt.Sprintf("muster(%s): reject %s gen%d", t.Plan, implID, g), paths); err != nil {
		return a.refuse("reject commit failed: %v. DB untouched - fix git state and rerun done fail.", err)
	}
	// DB half (crash after the commit above resumes via resumeReject)
	stamped, _ := card.Parse(text, true)
	fixRow := store.IngestTask{Task: store.Task{
		ID: fixID, Plan: stamped.Plan, Seq: stamped.Seq, Type: stamped.Type, Tier: stamped.Tier,
		Harness: stamped.Harness, CardPath: fixRel,
		FrontmatterSHA: stamped.FrontmatterSHA, Fixes: stamped.Fixes,
	}, Deps: stamped.DependsOn}
	if err := a.St.CycleReview(t.ID, t.ClaimedBy, reason, fixRow, g, a.iso()); err != nil {
		return a.refuse("reject commit landed but the DB cycle failed (%v) - rerun done fail to resume.", err)
	}
	a.backupDB()
	a.pf("Review failed. Fix %s queued (generation %d of 2). Session over.", fixID, g)
	return 0
}

// doneFailIntegration: plan-level drift belongs to the orchestrator, not a
// fix task (v1 spec 4.3). Terminal: result + one fail commit + status failed.
func (a *App) doneFailIntegration(t *store.Task, c *card.Card, reason string, doneCheckPass bool) int {
	if len(a.stagedFiles()) > 0 {
		return a.refuse("integration done fail accepts no fix task - clear .muster/staging/.")
	}
	if code := a.failCommitAndFile(t, c, reason, doneCheckPass); code != -1 {
		return code
	}
	a.pf("Integration review failed. Bring .muster/cards/%s.result.md to the orchestrator to shard a fix-up plan. Session over.", t.ID)
	return 3
}
