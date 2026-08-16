// internal/bench/suite.go
package bench

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// SuiteResult holds every attempt row produced by a suite run.
type SuiteResult struct {
	Rows []Row
}

// repCounts returns tiered rep counts by per-rep cost.
//
// DEVIATION from spec §3.2's stated ranges (owner-approved, 2026-08-16). The full
// spec sample does not finish inside the one-time descriptive-baseline budget
// (~1.5-2h) on this spawn-bound box: muster's lifecycle shells out ~26 processes
// per task (~1.9s/task), so one N=1000 loop ≈ 30 min and N=1000 dominates total
// wall-time. The only honest wall-clock lever is fewer independent replicates
// (parallelism, board reuse, or dropping the verify step would each change WHAT is
// measured), applied in this order:
//   - N=1000 warmup DROPPED (spec: 1-2). A discarded large-N warmup costs ~30 min
//     and buys ~nothing here: fresh process per verb, no JIT, and the exe+git are
//     already page-cached by the N=10/100 phases that run first.
//   - N=100 warmup DROPPED and timed trimmed 12 -> 9 (spec: 10-15). N=100 is not
//     the wall-time driver, so trimming it barely helps the budget, but 9 still
//     yields a real distribution while spending nothing wasteful.
//   - Every timed count kept ODD so RenderTable's median (vals[len/2]) is a
//     genuine middle observation, not the arbitrary upper-of-two an even count
//     picks — this matters most at N=1000 where the median IS the headline.
// N=1000 stays at 3 (spec's floor, already labeled "preliminary") and N=10 stays
// rich (cheap; its 2 warmups also prime the OS page cache for the whole session).
func repCounts(n int) (warmup, timed int) {
	switch {
	case n >= 1000:
		return 0, 3
	case n >= 100:
		return 0, 9
	default:
		return 2, 25
	}
}

// RunSuite runs cold-verb + full-loop reps for each N. Every attempt (incl.
// failures) becomes a Row.
func RunSuite(exe string, nSet []int) SuiteResult {
	var sr SuiteResult
	env := Capture()
	order := 0
	for _, n := range nSet {
		warm, timed := repCounts(n)
		batches, man := Generate(1, n)
		comp := composition(batches)
		// cold-verb: build one board, time read verbs against it.
		if fx, boardSHA, showID, err := BuildBoard(exe, 1, n); err == nil {
			for _, verb := range []string{"board", "show", "doctor"} {
				for i := 0; i < 8; i++ { // warmup 3 + timed 5 (cheap; label warmup)
					var cr ColdVerbResult
					if verb == "show" {
						cr = RunColdVerb(exe, fx, verb, showID) // show needs one id
					} else {
						cr = RunColdVerb(exe, fx, verb)
					}
					sr.Rows = append(sr.Rows, Row{
						SchemaVersion: SchemaVersion, ExperimentID: "v2.0-baseline",
						Measurement: "cold_verb", Verb: verb, N: n, RepOrdinal: i,
						ActualOrder: order, Warmup: i < 3, Seed: 1,
						GeneratorVersion: GeneratorVersion, BoardStateSHA: boardSHA,
						AttemptStatus: statusOf(cr.Status), WallNS: cr.WallNS,
						ExcludeReason: excludeIf(cr.Status), HarnessVersion: HarnessVersion,
						FixtureVersion: FixtureVersion, Env: env,
					})
					order++
				}
			}
			os.RemoveAll(fx.Root)
		}
		for i := 0; i < warm+timed; i++ {
			res, err := RunFullLoopOnce(exe, 1, n)
			row := Row{
				SchemaVersion: SchemaVersion, ExperimentID: "v2.0-baseline",
				Measurement: "full_loop", N: n, RepOrdinal: i, ActualOrder: order,
				Warmup: i < warm, Seed: 1, GeneratorVersion: GeneratorVersion,
				Topology: "fanin", WorkloadSHA: man.SHA,
				BatchSizes: comp.sizes, BatchCount: len(batches),
				ImplCount: comp.impl, IntegrationCount: comp.integration,
				HarnessVersion: HarnessVersion, FixtureVersion: FixtureVersion, Env: env,
			}
			if i < warm {
				row.WarmupReason = "cache/JIT warmup, discarded from stats"
			}
			if err != nil {
				row.AttemptStatus = "error"
				row.ErrorDetail = err.Error()
			} else if res.Status != "ok" {
				row.AttemptStatus = "error"
				row.ErrorDetail = res.Status
			} else {
				row.AttemptStatus = "ok"
				row.WallNS = res.WallNS
				row.PerTaskNSTrace = res.PerTaskNS
				row.ChildMusterNS = res.ChildMusterNS
				row.VerifierSpawns = res.VerifierSpawns
			}
			sr.Rows = append(sr.Rows, row)
			order++
		}
	}
	return sr
}

type comp struct {
	sizes       []int
	impl        int
	integration int
}

func composition(batches []Batch) comp {
	var c comp
	for _, b := range batches {
		c.sizes = append(c.sizes, len(b.Impl)+1)
		c.impl += len(b.Impl)
		c.integration++
	}
	return c
}

func statusOf(s string) string {
	if s == "ok" {
		return "ok"
	}
	return "error"
}
func excludeIf(s string) string {
	if s == "ok" {
		return ""
	}
	return s
}

// RenderTable is a human-readable dry-run summary (median wall per N).
func RenderTable(sr SuiteResult) string {
	byN := map[int][]int64{}
	for _, r := range sr.Rows {
		if r.Measurement == "full_loop" && r.AttemptStatus == "ok" && !r.Warmup {
			byN[r.N] = append(byN[r.N], r.WallNS)
		}
	}
	var ns []int
	for n := range byN {
		ns = append(ns, n)
	}
	sort.Ints(ns)
	var sb strings.Builder
	sb.WriteString("N\tmedian_ms\treps\n")
	for _, n := range ns {
		vals := byN[n]
		sort.Slice(vals, func(i, j int) bool { return vals[i] < vals[j] })
		med := vals[len(vals)/2] / 1e6
		fmt.Fprintf(&sb, "%d\t%d\t%d\n", n, med, len(vals))
	}
	return sb.String()
}

// Persist writes JSONL (append), benchfmt, artifacts, and docs/bench.md.
func Persist(repoRoot, exe string, buildJSON []byte, nSet []int, sr SuiteResult) error {
	benchDir := filepath.Join(repoRoot, "bench")
	if err := os.MkdirAll(benchDir, 0o755); err != nil {
		return err
	}
	// artifacts (gitignored): each distinct N has its own workload, so archive
	// one immutable dir per N — the N=10/100 bytes are NOT subsets of N=1000.
	artifactByN := map[int]string{}
	for _, n := range nSet {
		batches, man := Generate(1, n)
		aSHA, err := Archive(filepath.Join(benchDir, "artifacts"), ArchiveSpec{
			Exe: exe, Batches: batches, Manifest: man, BuildJSON: buildJSON,
			Invocation: []byte(fmt.Sprintf(`{"n":%d}`, n)),
		})
		if err != nil {
			return err
		}
		artifactByN[n] = aSHA
	}
	// stamp per-N artifact sha + exe info onto every row
	info, _ := ReadExeInfo(exe)
	exeSHA := ""
	if b, err := os.ReadFile(exe); err == nil {
		exeSHA = sha(b) // consolidated helper (workload.go); shaBytes removed
	}
	for i := range sr.Rows {
		sr.Rows[i].ArtifactSHA = artifactByN[sr.Rows[i].N]
		sr.Rows[i].ExeSHA256 = exeSHA
		sr.Rows[i].ExeBuildInfo = info
	}
	// JSONL append
	f, err := os.OpenFile(filepath.Join(benchDir, "results.jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	for _, r := range sr.Rows {
		if err := WriteRow(f, r); err != nil {
			return err
		}
	}
	// benchfmt
	bf, err := os.Create(filepath.Join(benchDir, "v2.0.bench.txt"))
	if err != nil {
		return err
	}
	defer bf.Close()
	if err := WriteBenchfmt(bf, sr.Rows); err != nil {
		return err
	}
	// docs/bench.md
	return os.WriteFile(filepath.Join(repoRoot, "docs", "bench.md"),
		[]byte("# MUSTER bench (descriptive)\n\n"+
			"Cross-time rows are NOT a regression verdict — that requires a same-day paired run.\n\n"+
			"```\n"+RenderTable(sr)+"```\n"), 0o644)
}
