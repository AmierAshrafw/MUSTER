// internal/bench/measure.go
package bench

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// verb argv builders — pinned to the verified CLI contract.
// NextEligible matches tier by EXACT equality (store/claim.go), so a -tier
// strong session claims ONLY strong tasks. Impl cards are tier any; the
// integration is tier strong. So the loop claims -tier any until drained, then
// escalates to -tier strong for the integration.
func claimArgs(tier string) []string { return []string{"claim", "-harness", "codex", "-tier", tier} }
func verifyArgs() []string   { return []string{"verify"} }
func implDoneArgs() []string { return []string{"done"} }         // impl: no verdict
func intDoneArgs() []string  { return []string{"done", "pass"} } // integration: pass + notes

// runMusterOut runs one muster.exe verb in the fixture, capturing combined
// output (needed to identify the claimed task id). Wall time = parent-observed
// Start->Wait, the only valid source of a spawned process's wall time.
func runMusterOut(exe string, fx *Fixture, args ...string) (string, time.Duration, int, error) {
	cmd := exec.Command(exe, args...)
	cmd.Dir = fx.Root
	cmd.Env = fx.Env()
	t0 := time.Now()
	out, err := cmd.CombinedOutput()
	elapsed := time.Since(t0)
	code := 0
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else {
			return string(out), elapsed, -1, err
		}
	}
	return string(out), elapsed, code, nil
}

// runMuster is a thin wrapper for callers that ignore output.
func runMuster(exe string, fx *Fixture, args ...string) (time.Duration, int, error) {
	_, d, c, e := runMusterOut(exe, fx, args...)
	return d, c, e
}

// LoopResult is one whole-loop replicate's timing + diagnostics.
type LoopResult struct {
	WallNS         int64
	PerTaskNS      []int64
	ChildMusterNS  int64
	VerifierSpawns int
	Status         string // "ok" or a failure reason
}

// RunFullLoopOnce builds a fresh board OUTSIDE the timer, then times the whole
// lifecycle. exe is the built muster binary; seed/n define the workload.
func RunFullLoopOnce(exe string, seed int64, n int) (LoopResult, error) {
	root, err := os.MkdirTemp("", "bench-loop")
	if err != nil {
		return LoopResult{}, err
	}
	defer os.RemoveAll(root)
	fx, err := NewFixture(root)
	if err != nil {
		return LoopResult{}, err
	}
	// muster init (creates .muster/) — outside the timer.
	if _, _, err := runMuster(exe, fx, "init"); err != nil {
		return LoopResult{}, err
	}
	batches, _ := Generate(seed, n)

	// Card materialization is pre-timer setup (spec §3.4: "Outside timer: ...
	// card materialization"). Write every batch's card files now, and record each
	// batch's ingest paths (absolute, for `muster ingest`) and repo-relative card
	// paths (for a per-batch `git add`). Staging each batch by explicit path — not
	// the whole .muster/cards dir — keeps every batch a distinct shard commit even
	// though all card files already exist on disk before the timer starts; the
	// timer opens at the first `ingest`, matching the §3.2 window.
	type batchIO struct {
		ingestPaths []string // absolute, for `muster ingest`
		addPaths    []string // repo-relative slash, for `git add`
	}
	ios := make([]batchIO, len(batches))
	for bi, b := range batches {
		all := append(append([]Card{}, b.Impl...), b.Integration)
		for _, c := range all {
			if err := fx.WriteFile(c.Path, c.Bytes); err != nil {
				return LoopResult{}, err
			}
			ios[bi].ingestPaths = append(ios[bi].ingestPaths, filepath.Join(fx.Root, filepath.FromSlash(c.Path)))
			ios[bi].addPaths = append(ios[bi].addPaths, c.Path)
		}
	}

	var res LoopResult
	start := time.Now()
	for bi := range batches {
		// ingest + commit (this batch's cards only) + promote
		io := ios[bi]
		if out, _, code, _ := runMusterOut(exe, fx, append([]string{"ingest"}, io.ingestPaths...)...); code != 0 {
			res.Status = fmt.Sprintf("ingest failed (code %d): %s", code, firstLine(out))
			break
		}
		if err := fx.Git(append([]string{"-c", "core.autocrlf=false", "add"}, io.addPaths...)...); err != nil {
			return res, err
		}
		if err := fx.Git("-c", "core.autocrlf=false", "commit", "-q", "-m", "bench: shard"); err != nil {
			return res, err
		}
		if out, _, code, _ := runMusterOut(exe, fx, "promote"); code != 0 {
			res.Status = fmt.Sprintf("promote failed (code %d): %s", code, firstLine(out))
			break
		}
	}
	if res.Status == "" {
		res.Status = runClaimLoop(exe, fx, batches, &res)
	}
	res.WallNS = time.Since(start).Nanoseconds()
	if res.Status == "" {
		res.Status = "ok"
	}
	return res, nil
}

// runClaimLoop claims every task in dependency order and completes it. impl tasks
// write their commit_paths file; the integration task writes a notes sidecar and
// is completed with `done pass`. Returns "" on success or a failure reason.
func runClaimLoop(exe string, fx *Fixture, batches []Batch, res *LoopResult) string {
	byID := map[string]Card{}
	total := 0
	for _, b := range batches {
		for _, c := range b.Impl {
			byID[c.ID] = c
			total++
		}
		byID[b.Integration.ID] = b.Integration
		total++
	}
	tier := "any" // start on impl tier; escalate to strong when 'any' is drained
	for done := 0; done < total; {
		taskStart := time.Now()
		out, d, code, err := runMusterOut(exe, fx, claimArgs(tier)...)
		res.ChildMusterNS += d.Nanoseconds()
		if err != nil || code != 0 {
			// Nothing eligible for this tier. If we were on 'any', the impls are
			// done and only the strong integration remains — escalate once. Other
			// refusals are real lifecycle failures and must not be hidden.
			reason := lastLine(out)
			if tier == "any" && reason == "MUSTER refuse: nothing to claim for codex/any." {
				tier = "strong"
				continue
			}
			board, _, _, _ := runMusterOut(exe, fx, "board")
			return fmt.Sprintf("claim failed (code %d): %s\n%s", code, reason, strings.TrimSpace(board))
		}
		id := parseClaimedID(out)
		if id == "" {
			return "could not parse Claimed id from: " + firstLine(out)
		}
		c, ok := byID[id]
		if !ok {
			return "claimed unknown id " + id
		}
		// executor step: write the required file
		if c.Type == "integration" {
			notes := ".muster/cards/" + c.ID + ".notes.md"
			if err := fx.WriteFile(notes, []byte("# findings\nbench: green\n")); err != nil {
				return err.Error()
			}
		} else {
			if err := fx.WriteFile(c.CommitPath, []byte("bench\n")); err != nil {
				return err.Error()
			}
		}
		// verify (spawn #1)
		if _, d, code, _ := runMusterOut(exe, fx, verifyArgs()...); code != 0 {
			return "verify failed for " + id
		} else {
			res.ChildMusterNS += d.Nanoseconds()
			res.VerifierSpawns++
		}
		// done (spawn #2 via done-check)
		doneArgs := implDoneArgs()
		if c.Type == "integration" {
			doneArgs = intDoneArgs()
		}
		if _, d, code, _ := runMusterOut(exe, fx, doneArgs...); code != 0 {
			return "done failed for " + id
		} else {
			res.ChildMusterNS += d.Nanoseconds()
			res.VerifierSpawns++
		}
		res.PerTaskNS = append(res.PerTaskNS, time.Since(taskStart).Nanoseconds())
		done++
	}
	return ""
}

func parseClaimedID(out string) string {
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "Claimed ") {
			rest := strings.TrimPrefix(line, "Claimed ")
			fields := strings.Fields(rest)
			if len(fields) == 0 {
				return ""
			}
			return strings.TrimSuffix(fields[0], ".")
		}
	}
	return ""
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

func lastLine(s string) string {
	lines := strings.Split(s, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if line := strings.TrimSpace(lines[i]); line != "" {
			return line
		}
	}
	return ""
}

// ColdVerbResult times a single read-only verb against a prebuilt board.
type ColdVerbResult struct {
	Verb   string
	WallNS int64
	Status string
}

// RunColdVerb times one invocation of a read-only verb against a prebuilt board.
// extra carries any required argument — `show` needs exactly one task id
// (board.go: "show needs exactly one task id."); board/doctor take none.
func RunColdVerb(exe string, fx *Fixture, verb string, extra ...string) ColdVerbResult {
	d, code, err := runMuster(exe, fx, append([]string{verb}, extra...)...)
	r := ColdVerbResult{Verb: verb, WallNS: d.Nanoseconds(), Status: "ok"}
	if err != nil || code != 0 {
		r.Status = fmt.Sprintf("verb %s failed (code %d)", verb, code)
	}
	return r
}

// BuildBoard creates a fixture, inits, and ingests+promotes n tasks WITHOUT
// completing them (a populated board for read-only verbs). Returns the fixture
// (caller must os.RemoveAll(fx.Root)), a board-state hash (workload sha proxy),
// and a deterministic show target (the lowest impl id).
func BuildBoard(exe string, seed int64, n int) (*Fixture, string, string, error) {
	root, err := os.MkdirTemp("", "bench-board")
	if err != nil {
		return nil, "", "", err
	}
	fx, err := NewFixture(root)
	if err != nil {
		os.RemoveAll(root)
		return nil, "", "", err
	}
	if _, _, err := runMuster(exe, fx, "init"); err != nil {
		os.RemoveAll(root)
		return nil, "", "", err
	}
	batches, man := Generate(seed, n)
	showTarget := batches[0].Impl[0].ID // deterministic: lowest impl id
	for _, b := range batches {
		var paths []string
		all := append(append([]Card{}, b.Impl...), b.Integration)
		for _, c := range all {
			if err := fx.WriteFile(c.Path, c.Bytes); err != nil {
				os.RemoveAll(root)
				return nil, "", "", err
			}
			paths = append(paths, filepath.Join(fx.Root, filepath.FromSlash(c.Path)))
		}
		if _, code, _ := runMuster(exe, fx, append([]string{"ingest"}, paths...)...); code != 0 {
			os.RemoveAll(root)
			return nil, "", "", fmt.Errorf("board ingest failed at n=%d", n)
		}
		if err := fx.Git("-c", "core.autocrlf=false", "add", ".muster/cards"); err != nil {
			os.RemoveAll(root)
			return nil, "", "", err
		}
		if err := fx.Git("-c", "core.autocrlf=false", "commit", "-q", "-m", "bench: board"); err != nil {
			os.RemoveAll(root)
			return nil, "", "", err
		}
		runMuster(exe, fx, "promote")
	}
	return fx, man.SHA, showTarget, nil
}
