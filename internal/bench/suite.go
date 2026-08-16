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

// repCounts returns tiered rep counts by per-rep cost (spec §3.2).
func repCounts(n int) (warmup, timed int) {
	switch {
	case n >= 1000:
		return 1, 4
	case n >= 100:
		return 1, 12
	default:
		return 3, 25
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
