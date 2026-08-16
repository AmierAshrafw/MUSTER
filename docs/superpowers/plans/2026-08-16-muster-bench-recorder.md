# MUSTER Bench Recorder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a thin, forward-compatible Go command (`cmd/musterbench`) that records a v2.0 performance baseline for MUSTER — cold-verb latency and full-loop lifecycle timing — archiving the perishable exe + byte-identical workload + build recipe, with complete self-describing observations (including failures) so a future paired-comparison engine is not boxed in.

**Architecture:** A standalone `cmd/musterbench` orchestrates an isolated `internal/bench` package: a deterministic fan-in workload generator, a copied+hardened temp-git-repo fixture, timers for cold-verb and whole-loop-replicate measurement, a batched timeout-bounded PowerShell fingerprint probe, a JSONL attempt-record writer plus a lossy benchfmt export, and a content-addressed immutable artifact archiver. No stats/pairing engine — the recorder only produces data and archives. All writes are gated behind `--record`.

**Tech Stack:** Go 1.25+ (module `muster`, pure-Go `modernc.org/sqlite`, no cgo), Windows Server 2025, git CLI, PowerShell (probed via `os/exec`). Reuses the real `internal/card` linter for workload validity and the real `muster.exe` verbs.

---

## File Structure

**New files:**
- `internal/bench/version.go` — version constants + `BatchMax` (one responsibility: pinned identifiers).
- `internal/bench/workload.go` — deterministic fan-in card generator + manifest.
- `internal/bench/workload_test.go` — determinism, golden manifest, Parse/Lint validity, batching math.
- `internal/bench/fixture.go` — temp-git-repo + hardened GIT_CONFIG + exe build with buildvcs assertion + autocrlf guard.
- `internal/bench/fixture_test.go` — build succeeds, autocrlf round-trip.
- `internal/bench/fingerprint.go` — batched PowerShell probe, tri-state, box tag.
- `internal/bench/fingerprint_test.go` — fault-tolerance with stubbed probe.
- `internal/bench/record.go` — JSONL attempt-record + run_id + benchfmt export.
- `internal/bench/record_test.go` — round-trip, run_id determinism/collision, benchfmt parse-back.
- `internal/bench/archive.go` — content-addressed artifact dir + build.json + buildinfo read.
- `internal/bench/archive_test.go` — artifact_sha stability, immutability.
- `internal/bench/measure.go` — cold-verb + full-loop timers, warmup, per-task trace.
- `internal/bench/measure_test.go` — timer-boundary structure (unit-level).
- `internal/bench/smoke_test.go` — gated (`//go:build benchsmoke`) real N=3 end-to-end.
- `cmd/musterbench/main.go` — flag parsing, orchestration, dry-run vs record, dirty-tree policy, docs/bench.md gen.
- `cmd/musterbench/main_test.go` — flag parsing, dirty-tree refusal.
- `bench/README.md` — operator note (artifacts/ is the irreplaceable asset).
- `bench/.gitignore` — ignore `artifacts/`.

**Modified files:** none in existing MUSTER code.

**Shared types** (defined in Task 1–2, referenced throughout):

```go
// Card is one generated task card plus what the executor must do for it.
type Card struct {
	ID         string // e.g. "benchb0-01-t000001"
	Path       string // repo-relative, e.g. ".muster/cards/benchb0-01-t000001.md"
	Bytes      []byte // exact card file bytes (LF), hashed for the manifest
	Type       string // "impl" | "integration"
	CommitPath string // impl only: repo-relative file the executor writes, e.g. "src/benchb0-01-t000001.txt"
}

// Batch is one ingest unit: impl tasks + exactly one seq-99 integration task.
type Batch struct {
	Plan        string
	Impl        []Card
	Integration Card
}

// ManifestEntry / Manifest pin the workload identity.
type ManifestEntry struct {
	Index int    `json:"index"`
	ID    string `json:"id"`
	SHA   string `json:"sha256"`
}
type Manifest struct {
	Entries []ManifestEntry `json:"entries"`
	SHA     string          `json:"manifest_sha256"`
}
```

---

## Task 1: Package scaffold + version constants

**Files:**
- Create: `internal/bench/version.go`
- Test: `internal/bench/version_test.go`

- [ ] **Step 1: Write the failing test**

```go
// internal/bench/version_test.go
package bench

import "testing"

func TestVersionConstantsPresent(t *testing.T) {
	if SchemaVersion != 2 {
		t.Fatalf("SchemaVersion = %d, want 2", SchemaVersion)
	}
	if BatchMax < 100 || BatchMax > 280 {
		t.Fatalf("BatchMax = %d, want a size-cap-safe value in [100,280]", BatchMax)
	}
	for name, v := range map[string]string{
		"HarnessVersion": HarnessVersion, "FixtureVersion": FixtureVersion,
		"GeneratorVersion": GeneratorVersion,
	} {
		if v == "" {
			t.Fatalf("%s is empty", name)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/bench/ -run TestVersionConstantsPresent`
Expected: FAIL — `undefined: SchemaVersion`.

- [ ] **Step 3: Write minimal implementation**

```go
// internal/bench/version.go
// Package bench is the MUSTER v2.0 performance-baseline recorder. It measures
// board mechanics against the real muster.exe in temp git repos and records
// self-describing observations. See docs/superpowers/specs/2026-08-16-muster-bench-recorder-design.md.
package bench

const (
	// SchemaVersion is the JSONL row schema. Bumped to 3 when the paired runner
	// adds arm/pair/block columns.
	SchemaVersion = 2

	// HarnessVersion / FixtureVersion / GeneratorVersion pin the measurement
	// apparatus; every row records them so drift is detectable.
	HarnessVersion   = "1"
	FixtureVersion   = "1"
	GeneratorVersion = "1"

	// BatchMax is the max tasks per ingest batch. The real cap is the 300-line /
	// 16 KB card size limit (lint rule 6): the integration card lists every
	// sibling in depends_on, one line each. Pinned by TestBatchMaxUnderSizeCap.
	BatchMax = 250
)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/bench/ -run TestVersionConstantsPresent`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/bench/version.go internal/bench/version_test.go
git commit -m "feat(bench): package scaffold + version constants"
```

---

## Task 2: Deterministic fan-in workload generator

**Files:**
- Create: `internal/bench/workload.go`
- Test: `internal/bench/workload_test.go`

The generator emits batches of `BatchMax`-capped fan-in units. Card templates must satisfy `internal/card` Parse + Lint (Full mode) exactly: impl cards carry non-empty `commit_paths` and `protected: []`; the integration card **omits `commit_paths` entirely** and lists every sibling in `depends_on`; **no `seq` key is ever emitted** (it is derived from the `-NN-` id field); body headings are `# … ## Context ## Steps ## Acceptance` in order; verify is `git --version` with `expect_exit: 0` (no path tokens, passes rule 5).

- [ ] **Step 1: Write the failing test**

```go
// internal/bench/workload_test.go
package bench

import (
	"strings"
	"testing"
)

func TestGenerateDeterministic(t *testing.T) {
	_, m1 := Generate(1, 100)
	_, m2 := Generate(1, 100)
	if m1.SHA != m2.SHA {
		t.Fatalf("manifest SHA not deterministic: %s vs %s", m1.SHA, m2.SHA)
	}
	if len(m1.Entries) != 100 {
		t.Fatalf("manifest has %d entries, want 100", len(m1.Entries))
	}
}

func TestGenerateGoldenManifest(t *testing.T) {
	_, m := Generate(1, 10)
	// GOLDEN: regenerate intentionally if the template changes on purpose.
	const golden = "" // filled in Step 4 after first run
	if golden != "" && m.SHA != golden {
		t.Fatalf("manifest SHA changed: got %s, want golden %s", m.SHA, golden)
	}
}

func TestGenerateFanInTopology(t *testing.T) {
	batches, _ := Generate(1, 10)
	if len(batches) != 1 {
		t.Fatalf("N=10 should be one batch, got %d", len(batches))
	}
	b := batches[0]
	if len(b.Impl) != 9 {
		t.Fatalf("want 9 impl, got %d", len(b.Impl))
	}
	if b.Integration.Type != "integration" {
		t.Fatalf("integration task type = %q", b.Integration.Type)
	}
	if !strings.Contains(b.Integration.ID, "-99-") {
		t.Fatalf("integration id %q must carry seq 99", b.Integration.ID)
	}
	if b.Integration.CommitPath != "" {
		t.Fatalf("integration must have no commit path")
	}
	// Integration depends on every impl in the batch.
	body := string(b.Integration.Bytes)
	for _, im := range b.Impl {
		if !strings.Contains(body, "- "+im.ID) {
			t.Fatalf("integration depends_on missing %s", im.ID)
		}
	}
}

func TestGenerateNoSeqKey(t *testing.T) {
	batches, _ := Generate(1, 10)
	for _, b := range batches {
		all := append(append([]Card{}, b.Impl...), b.Integration)
		for _, c := range all {
			// A "seq:" frontmatter line is an unknown-key Parse error.
			for _, line := range strings.Split(string(c.Bytes), "\n") {
				if strings.HasPrefix(strings.TrimSpace(line), "seq:") {
					t.Fatalf("card %s emits forbidden seq key", c.ID)
				}
			}
		}
	}
}

func TestBatchCountAndSizes(t *testing.T) {
	// N just over one batch splits into two.
	batches, _ := Generate(1, BatchMax+1)
	if len(batches) != 2 {
		t.Fatalf("N=BatchMax+1 should be 2 batches, got %d", len(batches))
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/bench/ -run TestGenerate`
Expected: FAIL — `undefined: Generate`.

- [ ] **Step 3: Write minimal implementation**

```go
// internal/bench/workload.go
package bench

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
)

type Card struct {
	ID         string
	Path       string
	Bytes      []byte
	Type       string
	CommitPath string
}

type Batch struct {
	Plan        string
	Impl        []Card
	Integration Card
}

type ManifestEntry struct {
	Index int    `json:"index"`
	ID    string `json:"id"`
	SHA   string `json:"sha256"`
}
type Manifest struct {
	Entries []ManifestEntry `json:"entries"`
	SHA     string          `json:"manifest_sha256"`
}

const implTemplate = `---
id: %[1]s
plan: %[2]s
type: impl
tier: any
depends_on: []
protected: []
commit_paths:
  - %[3]s
verify:
  - cmd: git --version
    expect_exit: 0
---
# %[1]s: bench impl task

## Context
Synthetic benchmark task. Fixed template; only the id varies.

## Steps
1. Create %[3]s containing the single line bench.

## Acceptance
- The commit path file exists.
`

const integrationTemplate = `---
id: %[1]s
plan: %[2]s
type: integration
tier: strong
depends_on:
%[3]s
verify:
  - cmd: git --version
    expect_exit: 0
---
# %[1]s: bench integration task

## Context
Synthetic benchmark integration task. Fixed template; only the id and deps vary.

## Steps
1. Confirm the batch is green.

## Acceptance
- git is present.
`

// Generate produces the fan-in workload for n tasks with the given seed. The
// seed is recorded but the workload is a pure function of (seed, n); no clock or
// randomness enters card bytes, so bytes are identical across versions.
func Generate(seed int64, n int) ([]Batch, Manifest) {
	var batches []Batch
	var entries []ManifestEntry
	idx := 0
	remaining := n
	batchNo := 0
	for remaining > 0 {
		size := remaining
		if size > BatchMax {
			size = BatchMax
		}
		plan := fmt.Sprintf("benchb%d", batchNo)
		implN := size - 1 // one slot reserved for the integration task
		var impl []Card
		var depLines []string
		for i := 0; i < implN; i++ {
			id := fmt.Sprintf("%s-01-t%06d", plan, idx)
			commitPath := "src/" + id + ".txt"
			bytes := []byte(fmt.Sprintf(implTemplate, id, plan, commitPath))
			c := Card{ID: id, Path: ".muster/cards/" + id + ".md", Bytes: bytes, Type: "impl", CommitPath: commitPath}
			impl = append(impl, c)
			depLines = append(depLines, "  - "+id)
			entries = append(entries, ManifestEntry{Index: idx, ID: id, SHA: sha(bytes)})
			idx++
		}
		intID := fmt.Sprintf("%s-99-integration", plan)
		intBytes := []byte(fmt.Sprintf(integrationTemplate, intID, plan, strings.Join(depLines, "\n")))
		integration := Card{ID: intID, Path: ".muster/cards/" + intID + ".md", Bytes: intBytes, Type: "integration"}
		entries = append(entries, ManifestEntry{Index: idx, ID: intID, SHA: sha(intBytes)})
		idx++
		batches = append(batches, Batch{Plan: plan, Impl: impl, Integration: integration})
		remaining -= size
		batchNo++
	}
	return batches, Manifest{Entries: entries, SHA: manifestSHA(entries)}
}

func sha(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

func manifestSHA(entries []ManifestEntry) string {
	h := sha256.New()
	for _, e := range entries {
		fmt.Fprintf(h, "%d\x00%s\x00%s\n", e.Index, e.ID, e.SHA)
	}
	return hex.EncodeToString(h.Sum(nil))
}
```

- [ ] **Step 4: Run tests; fill the golden constant**

Run: `go test ./internal/bench/ -run TestGenerate -v`
Expected: all PASS except `TestGenerateGoldenManifest` prints nothing (golden empty ⇒ skipped assertion). Capture the real N=10 SHA:

Run: `go test ./internal/bench/ -run TestGenerateDeterministic -v` then add a temporary `t.Log(m1.SHA)` if needed, or compute once. Paste the N=10 manifest SHA into `golden` in `TestGenerateGoldenManifest` and re-run:
Run: `go test ./internal/bench/ -run TestGenerateGoldenManifest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/bench/workload.go internal/bench/workload_test.go
git commit -m "feat(bench): deterministic fan-in workload generator"
```

---

## Task 3: Workload passes the real card linter (per batch)

**Files:**
- Modify: `internal/bench/workload_test.go`

Validates the topology against production `internal/card`. A single `Lint(Full)` over multiple batches trips rule 11 (≥2 integration tasks), so **each batch is linted independently**, mirroring per-batch ingest.

- [ ] **Step 1: Write the failing test**

```go
// append to internal/bench/workload_test.go
import (
	"os"
	"path/filepath"

	"muster/internal/card"
)

// lintBatch materializes one batch to a temp dir and lints it in Full mode.
func lintBatch(t *testing.T, b Batch) []string {
	t.Helper()
	dir := t.TempDir()
	var paths []string
	all := append(append([]Card{}, b.Impl...), b.Integration)
	for _, c := range all {
		p := filepath.Join(dir, filepath.Base(c.Path))
		if err := os.WriteFile(p, c.Bytes, 0o644); err != nil {
			t.Fatal(err)
		}
		paths = append(paths, p)
	}
	return card.Lint(paths, func(string) bool { return false }, card.Full)
}

func TestWorkloadLintsClean(t *testing.T) {
	for _, n := range []int{10, BatchMax, BatchMax + 1, 1000} {
		batches, _ := Generate(1, n)
		for bi, b := range batches {
			if findings := lintBatch(t, b); len(findings) > 0 {
				t.Fatalf("N=%d batch %d lint findings: %v", n, bi, findings)
			}
		}
	}
}

func TestWorkloadParsesClean(t *testing.T) {
	batches, _ := Generate(1, 10)
	all := append(append([]Card{}, batches[0].Impl...), batches[0].Integration)
	for _, c := range all {
		if _, errs := card.Parse(string(c.Bytes), false); len(errs) > 0 {
			t.Fatalf("card %s Parse errors: %v", c.ID, errs)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails or reveals a template bug**

Run: `go test ./internal/bench/ -run "TestWorkloadLints|TestWorkloadParses" -v`
Expected: initially may FAIL if the template violates a lint/parse rule (e.g. body heading order, an unknown key). Read each finding and fix `implTemplate`/`integrationTemplate` in `workload.go` until zero findings. Common fixes: ensure exact heading order, ensure `expect_exit` is an integer, ensure no trailing placeholder tokens.

- [ ] **Step 3: (implementation already in Task 2; only template edits here if needed)**

Adjust the templates in `workload.go` as the findings dictate. Re-run until green.

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/bench/ -run "TestWorkloadLints|TestWorkloadParses"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/bench/workload.go internal/bench/workload_test.go
git commit -m "test(bench): workload passes real card lint per batch"
```

---

## Task 4: BatchMax stays under the card size cap

**Files:**
- Modify: `internal/bench/workload_test.go`

- [ ] **Step 1: Write the failing test**

```go
// append to internal/bench/workload_test.go
import "strings" // already imported; keep single import

func TestBatchMaxUnderSizeCap(t *testing.T) {
	// The integration card at a full batch must stay under 300 lines / 16 KB
	// (lint rule 6). This pins BatchMax.
	batches, _ := Generate(1, BatchMax) // exactly one full batch
	if len(batches) != 1 {
		t.Fatalf("N=BatchMax should be one batch, got %d", len(batches))
	}
	b := batches[0]
	lines := strings.Count(string(b.Integration.Bytes), "\n") + 1
	if lines > 300 {
		t.Fatalf("integration card is %d lines (>300) at BatchMax=%d; lower BatchMax", lines, BatchMax)
	}
	if len(b.Integration.Bytes) > 16*1024 {
		t.Fatalf("integration card is %d bytes (>16KB) at BatchMax=%d; lower BatchMax", len(b.Integration.Bytes), BatchMax)
	}
}
```

- [ ] **Step 2: Run test to verify it fails or passes**

Run: `go test ./internal/bench/ -run TestBatchMaxUnderSizeCap`
Expected: PASS at `BatchMax=250` (integration card ≈ 249 dep lines + ~15 header/body lines ≈ 264 lines). If it FAILS, lower `BatchMax` in `version.go` until it passes, then re-run Task 3's `TestWorkloadLintsClean`.

- [ ] **Step 3: (no new code unless BatchMax changed)**

- [ ] **Step 4: Re-run the lint suite**

Run: `go test ./internal/bench/ -run "TestBatchMax|TestWorkloadLints"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/bench/version.go internal/bench/workload_test.go
git commit -m "test(bench): pin BatchMax under the card size cap"
```

---

## Task 5: Temp-repo fixture with hardened git config + autocrlf guard

**Files:**
- Create: `internal/bench/fixture.go`
- Test: `internal/bench/fixture_test.go`

The fixture builds an isolated temp git repo. Critical: system gitconfig on the target box has `core.autocrlf=true` and temp repos do not inherit MUSTER's `.gitattributes`, so LF card files would be CRLF-mangled. The fixture writes a `.gitattributes` (`* -text`) into each temp repo and the harness passes `-c core.autocrlf=false` on its own git calls.

- [ ] **Step 1: Write the failing test**

```go
// internal/bench/fixture_test.go
package bench

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNewRepoRoundTripsLF(t *testing.T) {
	fx, err := NewFixture(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	// Write an LF file, add+commit via the fixture's git wrapper, then read the
	// committed blob back; it must be byte-identical (no CRLF injection).
	rel := "src/lf.txt"
	want := []byte("bench\n")
	if err := fx.WriteFile(rel, want); err != nil {
		t.Fatal(err)
	}
	if err := fx.Git("-c", "core.autocrlf=false", "add", rel); err != nil {
		t.Fatal(err)
	}
	if err := fx.Git("-c", "core.autocrlf=false", "commit", "-q", "-m", "add lf"); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(fx.Root, filepath.FromSlash(rel)))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(want) {
		t.Fatalf("round-trip mangled bytes: got %q want %q", got, want)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/bench/ -run TestNewRepoRoundTripsLF`
Expected: FAIL — `undefined: NewFixture`.

- [ ] **Step 3: Write minimal implementation**

```go
// internal/bench/fixture.go
package bench

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

// Fixture is an isolated temp git repo with a hardened, benchmark-owned git
// environment. It copies the test/process pattern but widens the autocrlf guard:
// the target box's SYSTEM gitconfig sets core.autocrlf=true, which the global
// override alone does not neutralize.
type Fixture struct {
	Root string
	env  []string
}

// NewFixture initializes a git repo under root with a pinned identity, an empty
// global+system git config, and a .gitattributes disabling text conversion.
func NewFixture(root string) (*Fixture, error) {
	emptyGlobal := filepath.Join(root, ".global.gitconfig")
	if err := os.WriteFile(emptyGlobal, nil, 0o644); err != nil {
		return nil, err
	}
	emptySystem := filepath.Join(root, ".system.gitconfig")
	if err := os.WriteFile(emptySystem, nil, 0o644); err != nil {
		return nil, err
	}
	env := append(os.Environ(),
		"GIT_CONFIG_GLOBAL="+emptyGlobal,
		"GIT_CONFIG_SYSTEM="+emptySystem, // <-- closes the system core.autocrlf=true leak
		"GIT_CONFIG_COUNT=2",
		"GIT_CONFIG_KEY_0=safe.directory", "GIT_CONFIG_VALUE_0=*",
		"GIT_CONFIG_KEY_1=core.autocrlf", "GIT_CONFIG_VALUE_1=false",
	)
	fx := &Fixture{Root: root, env: env}
	// .gitattributes belongs INSIDE the repo so every git op sees it.
	if err := fx.WriteFile(".gitattributes", []byte("* -text\n")); err != nil {
		return nil, err
	}
	for _, args := range [][]string{
		{"init", "-q", "-b", "main"},
		{"config", "user.name", "bench"},
		{"config", "user.email", "bench@test.local"},
	} {
		if err := fx.Git(args...); err != nil {
			return nil, err
		}
	}
	if err := fx.WriteFile("README.md", []byte("bench fixture\n")); err != nil {
		return nil, err
	}
	if err := fx.Git("-c", "core.autocrlf=false", "add", ".gitattributes", "README.md"); err != nil {
		return nil, err
	}
	if err := fx.Git("-c", "core.autocrlf=false", "commit", "-q", "-m", "init"); err != nil {
		return nil, err
	}
	return fx, nil
}

// WriteFile writes rel (repo-relative, slash-separated) creating parents.
func (fx *Fixture) WriteFile(rel string, b []byte) error {
	p := filepath.Join(fx.Root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	return os.WriteFile(p, b, 0o644)
}

// Git runs git in the repo with the hardened env; returns combined output on error.
func (fx *Fixture) Git(args ...string) error {
	cmd := exec.Command("git", append([]string{"-C", fx.Root}, args...)...)
	cmd.Env = fx.env
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("git %v: %w\n%s", args, err, out)
	}
	return nil
}

// Env returns the hardened environment for running muster.exe in this repo.
func (fx *Fixture) Env() []string { return fx.env }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/bench/ -run TestNewRepoRoundTripsLF`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/bench/fixture.go internal/bench/fixture_test.go
git commit -m "feat(bench): hardened temp-repo fixture with autocrlf guard"
```

---

## Task 6: Build the muster exe with VCS-stamp assertion

**Files:**
- Modify: `internal/bench/fixture.go`
- Modify: `internal/bench/fixture_test.go`

`go build` stamps VCS only when built inside the repo with git reachable; a build from a copy silently drops provenance. Build with `cmd.Dir` = the real repo root, pass `-buildvcs=true`, and assert `vcs.revision` is present in the output binary via `debug/buildinfo`.

- [ ] **Step 1: Write the failing test**

```go
// append to internal/bench/fixture_test.go
func TestBuildMusterStampsVCS(t *testing.T) {
	repoRoot := repoRootForTest(t) // resolves ../.. from this package
	exe := filepath.Join(t.TempDir(), "muster.exe")
	info, err := BuildMuster(repoRoot, exe)
	if err != nil {
		t.Fatal(err)
	}
	if info.VCSRevision == "" {
		t.Fatalf("built exe has no vcs.revision; buildvcs stamping failed")
	}
	if info.GoVersion == "" {
		t.Fatalf("built exe has no go version")
	}
}
```

Add helper at the bottom of the test file:

```go
func repoRootForTest(t *testing.T) string {
	t.Helper()
	abs, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	return abs
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/bench/ -run TestBuildMusterStampsVCS`
Expected: FAIL — `undefined: BuildMuster`.

- [ ] **Step 3: Write minimal implementation**

```go
// append to internal/bench/fixture.go
import (
	"debug/buildinfo" // add to the import block
)

// ExeInfo is the provenance read back from a built binary.
type ExeInfo struct {
	GoVersion   string
	VCSRevision string
	VCSModified bool
}

// BuildMuster compiles ./cmd/muster from repoRoot into out, forcing VCS stamping,
// then reads the stamp back and fails loudly if it is absent.
func BuildMuster(repoRoot, out string) (ExeInfo, error) {
	cmd := exec.Command("go", "build", "-buildvcs=true", "-o", out, "./cmd/muster")
	cmd.Dir = repoRoot // MUST be the real repo (a copy has no .git → silent no-stamp)
	if b, err := cmd.CombinedOutput(); err != nil {
		return ExeInfo{}, fmt.Errorf("go build: %w\n%s", err, b)
	}
	return ReadExeInfo(out)
}

// ReadExeInfo extracts go version + vcs settings from a built binary.
func ReadExeInfo(path string) (ExeInfo, error) {
	bi, err := buildinfo.ReadFile(path)
	if err != nil {
		return ExeInfo{}, err
	}
	info := ExeInfo{GoVersion: bi.GoVersion}
	for _, s := range bi.Settings {
		switch s.Key {
		case "vcs.revision":
			info.VCSRevision = s.Value
		case "vcs.modified":
			info.VCSModified = s.Value == "true"
		}
	}
	return info, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/bench/ -run TestBuildMusterStampsVCS`
Expected: PASS (requires a clean git tree; if the tree is dirty, `VCSModified` is true but `VCSRevision` is still present, so the test still passes).

- [ ] **Step 5: Commit**

```bash
git add internal/bench/fixture.go internal/bench/fixture_test.go
git commit -m "feat(bench): build muster exe with enforced VCS stamping"
```

---

## Task 7: Fingerprint probe (batched PowerShell, fault-tolerant)

**Files:**
- Create: `internal/bench/fingerprint.go`
- Test: `internal/bench/fingerprint_test.go`

One batched `powershell.exe -NoProfile -NonInteractive` call, `CommandContext` timeout-bounded; any probe failure yields `"unknown"`, never a panic, never a fabricated value.

- [ ] **Step 1: Write the failing test**

```go
// internal/bench/fingerprint_test.go
package bench

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestFingerprintFaultTolerant(t *testing.T) {
	// A probe that always errors must yield tri-state "unknown", not a panic.
	fp := captureFingerprint(func(context.Context) (string, error) {
		return "", errors.New("simulated probe failure")
	})
	if fp.DefenderRealtime != "unknown" {
		t.Fatalf("DefenderRealtime = %q, want unknown on probe failure", fp.DefenderRealtime)
	}
	if fp.BoxTag == "" {
		t.Fatalf("BoxTag must be populated from Go runtime even when PS fails")
	}
	if fp.OS == "" || fp.GoArch == "" {
		t.Fatalf("runtime-derived fields must be present")
	}
}

func TestFingerprintProbeTimeoutIsUnknown(t *testing.T) {
	fp := captureFingerprint(func(ctx context.Context) (string, error) {
		<-ctx.Done() // simulate a hung WMI provider
		return "", ctx.Err()
	})
	if fp.DefenderRealtime != "unknown" {
		t.Fatalf("timed-out probe must map to unknown")
	}
	_ = time.Second
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/bench/ -run TestFingerprint`
Expected: FAIL — `undefined: captureFingerprint`.

- [ ] **Step 3: Write minimal implementation**

```go
// internal/bench/fingerprint.go
package bench

import (
	"context"
	"os"
	"runtime"
	"strings"
	"time"
)

// Fingerprint is descriptive provenance (not causal). Tri-state string fields use
// "unknown" when a probe cannot answer — never a fabricated value.
type Fingerprint struct {
	OS                 string `json:"os"`
	GoArch             string `json:"goarch"`
	GoVersion          string `json:"go_version"`
	BoxTag             string `json:"box_tag"`
	CPUModel           string `json:"cpu_model"`
	LogicalCores       int    `json:"logical_cores"`
	DefenderRealtime   string `json:"defender_realtime"` // "true"|"false"|"unknown"
	DefenderExclusion  string `json:"defender_exclusions_cover_benchdir"`
	BenchTempVolume    string `json:"bench_temp_dir_volume"`
}

// probeFunc runs the batched PowerShell probe; injectable for tests.
type probeFunc func(context.Context) (string, error)

// captureFingerprint fills a Fingerprint. Runtime-derived fields always populate;
// PowerShell-derived fields degrade to "unknown" on any probe failure/timeout.
func captureFingerprint(probe probeFunc) Fingerprint {
	fp := Fingerprint{
		OS:               runtime.GOOS,
		GoArch:           runtime.GOARCH,
		GoVersion:        runtime.Version(),
		LogicalCores:     runtime.NumCPU(),
		DefenderRealtime: "unknown",
		DefenderExclusion: "unknown",
		CPUModel:         "unknown",
		BenchTempVolume:  volumeOf(os.TempDir()),
	}
	fp.BoxTag = boxTag()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := probe(ctx)
	if err == nil {
		parseProbe(out, &fp)
	}
	return fp
}

// boxTag is a stable <hostname>-derived tag; comparisons are valid only within one tag.
func boxTag() string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		return "unknown-box"
	}
	return strings.ToLower(h)
}

func volumeOf(p string) string {
	if len(p) >= 2 && p[1] == ':' {
		return strings.ToUpper(p[:2])
	}
	return "unknown"
}

// parseProbe fills PS-derived fields from the batched probe output. Kept lenient:
// any field the probe omitted simply stays "unknown".
func parseProbe(out string, fp *Fingerprint) {
	for _, line := range strings.Split(out, "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok {
			continue
		}
		switch k {
		case "defender_realtime":
			fp.DefenderRealtime = v
		case "cpu_model":
			fp.CPUModel = v
		}
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/bench/ -run TestFingerprint`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/bench/fingerprint.go internal/bench/fingerprint_test.go
git commit -m "feat(bench): fault-tolerant fingerprint capture"
```

---

## Task 8: Real PowerShell probe (batched, timeout-bounded)

**Files:**
- Modify: `internal/bench/fingerprint.go`

- [ ] **Step 1: Write the failing test**

```go
// append to internal/bench/fingerprint_test.go
import "runtime"

func TestRealProbeDoesNotHangOrPanic(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("PowerShell probe is Windows-only")
	}
	fp := Capture() // real probe path; must return within the timeout, never panic
	if fp.BoxTag == "" {
		t.Fatalf("Capture produced empty fingerprint")
	}
	// DefenderRealtime is true/false/unknown — all acceptable; we only assert no hang.
	switch fp.DefenderRealtime {
	case "true", "false", "unknown":
	default:
		t.Fatalf("unexpected DefenderRealtime %q", fp.DefenderRealtime)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/bench/ -run TestRealProbe`
Expected: FAIL — `undefined: Capture`.

- [ ] **Step 3: Write minimal implementation**

```go
// append to internal/bench/fingerprint.go
import (
	"os/exec" // add to import block
)

// psScript batches every probe into ONE interpreter invocation (pay startup once)
// and emits key=value lines. Each probe is guarded so one failure cannot abort
// the rest; a failed probe simply omits its line (→ stays "unknown").
const psScript = `
$ErrorActionPreference='SilentlyContinue'
try { $d=(Get-MpComputerStatus).RealTimeProtectionEnabled; if($d -ne $null){ "defender_realtime=$($d.ToString().ToLower())" } } catch {}
try { $c=(Get-CimInstance Win32_Processor | Select-Object -First 1).Name; if($c){ "cpu_model=$c" } } catch {}
`

// Capture runs the real batched PowerShell probe on Windows.
func Capture() Fingerprint {
	return captureFingerprint(func(ctx context.Context) (string, error) {
		cmd := exec.CommandContext(ctx, "powershell.exe",
			"-NoProfile", "-NonInteractive", "-Command", psScript)
		out, err := cmd.Output()
		return string(out), err
	})
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/bench/ -run TestRealProbe`
Expected: PASS on Windows within ~10s (skipped elsewhere).

- [ ] **Step 5: Commit**

```bash
git add internal/bench/fingerprint.go internal/bench/fingerprint_test.go
git commit -m "feat(bench): batched timeout-bounded PowerShell probe"
```

---

## Task 9: Attempt-record schema + run_id + JSONL writer

**Files:**
- Create: `internal/bench/record.go`
- Test: `internal/bench/record_test.go`

Every attempt (incl. failures) writes one JSONL row. `run_id` is derived deterministically from the stratum keys **including `warmup`** so a warmup rep and its same-ordinal timed rep never collide.

- [ ] **Step 1: Write the failing test**

```go
// internal/bench/record_test.go
package bench

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestRunIDStableAndDistinguishesWarmup(t *testing.T) {
	base := Row{Measurement: "full_loop", N: 100, Seed: 1, GeneratorVersion: "1", RepOrdinal: 3}
	warm := base
	warm.Warmup = true
	if RunID(base) == "" {
		t.Fatal("empty run_id")
	}
	if RunID(base) == RunID(warm) {
		t.Fatal("warmup and timed rows must not share a run_id")
	}
	if RunID(base) != RunID(base) {
		t.Fatal("run_id must be deterministic")
	}
	diffN := base
	diffN.RepOrdinal = 4
	if RunID(base) == RunID(diffN) {
		t.Fatal("different rep ordinals must yield different run_ids")
	}
}

func TestWriteRowRoundTrips(t *testing.T) {
	var buf bytes.Buffer
	r := Row{
		SchemaVersion: SchemaVersion, Measurement: "full_loop", N: 10,
		AttemptStatus: "ok", WallNS: 123, RepOrdinal: 0, Seed: 1,
	}
	if err := WriteRow(&buf, r); err != nil {
		t.Fatal(err)
	}
	var back Row
	if err := json.Unmarshal(buf.Bytes(), &back); err != nil {
		t.Fatal(err)
	}
	if back.AttemptStatus != "ok" || back.WallNS != 123 || back.SchemaVersion != 2 {
		t.Fatalf("round-trip mismatch: %+v", back)
	}
}

func TestAttemptStatusAlwaysPresent(t *testing.T) {
	var buf bytes.Buffer
	// A failed attempt still records a row with a non-empty status.
	r := Row{SchemaVersion: SchemaVersion, Measurement: "full_loop", AttemptStatus: "timeout", ErrorDetail: "deadline exceeded"}
	if err := WriteRow(&buf, r); err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(buf.Bytes(), []byte(`"attempt_status":"timeout"`)) {
		t.Fatalf("attempt_status missing: %s", buf.String())
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/bench/ -run "TestRunID|TestWriteRow|TestAttemptStatus"`
Expected: FAIL — `undefined: Row`.

- [ ] **Step 3: Write minimal implementation**

```go
// internal/bench/record.go
package bench

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
)

// Row is one attempt record. Failed attempts are recorded too (no survivorship
// bias). Speculative paired columns (arm/pair/block) are intentionally absent;
// they arrive at SchemaVersion 3 with the paired runner.
type Row struct {
	SchemaVersion int    `json:"schema_version"`
	RunID         string `json:"run_id"`
	ExperimentID  string `json:"experiment_id"`
	SessionID     string `json:"session_id"`
	ActualOrder   int    `json:"actual_order_index"`

	AttemptStatus string `json:"attempt_status"` // ok|error|timeout|crash|cancelled
	ExitCode      int    `json:"exit_code"`
	ErrorDetail   string `json:"error_detail,omitempty"`
	Warmup        bool   `json:"warmup"`
	WarmupReason  string `json:"warmup_reason,omitempty"`
	Excluded      bool   `json:"excluded"`
	ExcludeReason string `json:"exclude_reason,omitempty"`

	Measurement string `json:"measurement"` // full_loop|cold_verb
	Verb        string `json:"verb,omitempty"`
	N           int    `json:"n"`
	RepOrdinal  int    `json:"rep_ordinal"`

	Seed             int64  `json:"seed"`
	GeneratorVersion string `json:"generator_version"`
	Topology         string `json:"topology"`
	WorkloadSHA      string `json:"workload_manifest_sha256"`
	BatchSizes       []int  `json:"batch_sizes"`
	BatchCount       int    `json:"batch_count"`
	ImplCount        int    `json:"impl_count"`
	IntegrationCount int    `json:"integration_count"`
	BoardStateSHA    string `json:"board_state_sha256,omitempty"`

	WallNS          int64   `json:"wall_ns"`
	PerTaskNSTrace  []int64 `json:"per_task_ns_trace,omitempty"`
	ChildMusterNS   int64   `json:"child_muster_ns_sum"`
	VerifierSpawns  int     `json:"verifier_spawns"`
	GitCommitCount  int     `json:"git_commit_count"`
	ExecutorWriteNS int64   `json:"executor_write_ns"`
	StartedUTC      string  `json:"started_utc"`
	EndedUTC        string  `json:"ended_utc"`

	ExeSHA256       string      `json:"exe_sha256"`
	ExeBuildInfo    ExeInfo     `json:"exe_buildinfo"`
	BuildRecipeSHA  string      `json:"build_recipe_sha256"`
	HarnessVersion  string      `json:"harness_version"`
	HarnessSHA256   string      `json:"harness_sha256"`
	FixtureVersion  string      `json:"fixture_version"`
	ArtifactSHA     string      `json:"artifact_sha"`
	Env             Fingerprint `json:"env"`
}

// RunID is a deterministic id over the stratum keys (no clock/random). Warmup is
// part of the key so a warmup rep and its same-ordinal timed rep never collide.
func RunID(r Row) string {
	key := fmt.Sprintf("%s\x00%s\x00%d\x00%d\x00%d\x00%s\x00%t",
		r.ExperimentID, r.Measurement+r.Verb, r.N, r.Seed, r.RepOrdinal, r.GeneratorVersion, r.Warmup)
	h := sha256.Sum256([]byte(key))
	return hex.EncodeToString(h[:16])
}

// WriteRow appends one JSON object + newline (JSONL). Fills RunID if empty.
func WriteRow(w io.Writer, r Row) error {
	if r.RunID == "" {
		r.RunID = RunID(r)
	}
	b, err := json.Marshal(r)
	if err != nil {
		return err
	}
	if _, err := w.Write(append(b, '\n')); err != nil {
		return err
	}
	return nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/bench/ -run "TestRunID|TestWriteRow|TestAttemptStatus"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/bench/record.go internal/bench/record_test.go
git commit -m "feat(bench): attempt-record schema + deterministic run_id"
```

---

## Task 10: benchfmt export

**Files:**
- Modify: `internal/bench/record.go`
- Modify: `internal/bench/record_test.go`

Lossy Go-benchmark-format export (design 14313), stable dims only, successful rows only.

- [ ] **Step 1: Write the failing test**

```go
// append to internal/bench/record_test.go
import "strings"

func TestBenchfmtExportStableDimsOnly(t *testing.T) {
	rows := []Row{
		{Measurement: "full_loop", N: 100, AttemptStatus: "ok", WallNS: 1234567890},
		{Measurement: "full_loop", N: 100, AttemptStatus: "ok", WallNS: 1231110000},
		{Measurement: "full_loop", N: 100, AttemptStatus: "timeout", WallNS: 0}, // omitted
	}
	var sb strings.Builder
	if err := WriteBenchfmt(&sb, rows); err != nil {
		t.Fatal(err)
	}
	out := sb.String()
	if strings.Count(out, "BenchmarkFullLoop/n=100") != 2 {
		t.Fatalf("expected 2 ok rows exported, got:\n%s", out)
	}
	if !strings.Contains(out, "1234567890 ns/op") {
		t.Fatalf("missing ns/op line:\n%s", out)
	}
	// No provenance/timestamps/sha in the export (would fragment benchstat grouping).
	if strings.Contains(out, "sha") || strings.Contains(out, "exe_") {
		t.Fatalf("benchfmt leaked provenance dims:\n%s", out)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/bench/ -run TestBenchfmt`
Expected: FAIL — `undefined: WriteBenchfmt`.

- [ ] **Step 3: Write minimal implementation**

```go
// append to internal/bench/record.go
import (
	"runtime" // add to import block
)

// WriteBenchfmt emits Go benchmark format (design 14313) for later benchstat
// convenience. Only successful rows; only stable comparison dims in the name.
func WriteBenchfmt(w io.Writer, rows []Row) error {
	fmt.Fprintf(w, "goos: %s\ngoarch: %s\npkg: muster-bench\n", runtime.GOOS, runtime.GOARCH)
	for _, r := range rows {
		if r.AttemptStatus != "ok" || r.Warmup {
			continue
		}
		name := benchName(r)
		if _, err := fmt.Fprintf(w, "%s 1 %d ns/op\n", name, r.WallNS); err != nil {
			return err
		}
	}
	return nil
}

func benchName(r Row) string {
	switch r.Measurement {
	case "cold_verb":
		return fmt.Sprintf("BenchmarkColdVerb/%s/n=%d", r.Verb, r.N)
	default:
		return fmt.Sprintf("BenchmarkFullLoop/n=%d", r.N)
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/bench/ -run TestBenchfmt`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/bench/record.go internal/bench/record_test.go
git commit -m "feat(bench): lossy benchfmt export, stable dims only"
```

---

## Task 11: Content-addressed artifact archiver

**Files:**
- Create: `internal/bench/archive.go`
- Test: `internal/bench/archive_test.go`

Archives the exe + materialized workload bytes + build recipe into `bench/artifacts/<sha>/`, immutable and content-addressed.

- [ ] **Step 1: Write the failing test**

```go
// internal/bench/archive_test.go
package bench

import (
	"os"
	"path/filepath"
	"testing"
)

func TestArchiveContentAddressedAndImmutable(t *testing.T) {
	dest := t.TempDir()
	exe := filepath.Join(t.TempDir(), "muster.exe")
	if err := os.WriteFile(exe, []byte("FAKE-EXE-BYTES"), 0o644); err != nil {
		t.Fatal(err)
	}
	batches, man := Generate(1, 10)
	spec := ArchiveSpec{
		Exe:        exe,
		Batches:    batches,
		Manifest:   man,
		BuildJSON:  []byte(`{"go":"go1.25.0"}`),
		Invocation: []byte(`{"n":[10]}`),
	}
	sha1, err := Archive(dest, spec)
	if err != nil {
		t.Fatal(err)
	}
	if sha1 == "" {
		t.Fatal("empty artifact sha")
	}
	// Same inputs → same sha dir (idempotent, immutable).
	sha2, err := Archive(dest, spec)
	if err != nil {
		t.Fatal(err)
	}
	if sha1 != sha2 {
		t.Fatalf("archive sha not stable: %s vs %s", sha1, sha2)
	}
	// The materialized workload bytes (not just a hash) must be on disk.
	got, err := os.ReadFile(filepath.Join(dest, sha1, "workload", filepath.Base(batches[0].Impl[0].Path)))
	if err != nil {
		t.Fatalf("materialized workload missing: %v", err)
	}
	if string(got) != string(batches[0].Impl[0].Bytes) {
		t.Fatal("archived workload bytes differ from generated")
	}
	if _, err := os.Stat(filepath.Join(dest, sha1, "muster.exe")); err != nil {
		t.Fatalf("archived exe missing: %v", err)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/bench/ -run TestArchive`
Expected: FAIL — `undefined: ArchiveSpec`.

- [ ] **Step 3: Write minimal implementation**

```go
// internal/bench/archive.go
package bench

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
)

// ArchiveSpec bundles the perishable, non-recreatable assets to preserve.
type ArchiveSpec struct {
	Exe        string
	Batches    []Batch
	Manifest   Manifest
	BuildJSON  []byte
	Invocation []byte
}

// Archive writes an immutable content-addressed dir under destRoot and returns
// its sha. Same inputs → same sha. Real bytes are stored, not just hashes.
func Archive(destRoot string, spec ArchiveSpec) (string, error) {
	exeBytes, err := os.ReadFile(spec.Exe)
	if err != nil {
		return "", err
	}
	sum := sha256.New()
	sum.Write(exeBytes)
	sum.Write([]byte(spec.Manifest.SHA))
	sum.Write(spec.BuildJSON)
	sum.Write(spec.Invocation)
	shaHex := hex.EncodeToString(sum.Sum(nil))[:32]

	dir := filepath.Join(destRoot, shaHex)
	if _, err := os.Stat(dir); err == nil {
		return shaHex, nil // immutable: already materialized, never rewrite
	}
	tmp := dir + ".tmp"
	if err := os.MkdirAll(filepath.Join(tmp, "workload"), 0o755); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(tmp, "muster.exe"), exeBytes, 0o755); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(tmp, "build.json"), spec.BuildJSON, 0o644); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(tmp, "invocation.json"), spec.Invocation, 0o644); err != nil {
		return "", err
	}
	for _, b := range spec.Batches {
		all := append(append([]Card{}, b.Impl...), b.Integration)
		for _, c := range all {
			if err := os.WriteFile(filepath.Join(tmp, "workload", filepath.Base(c.Path)), c.Bytes, 0o644); err != nil {
				return "", err
			}
		}
	}
	if err := os.Rename(tmp, dir); err != nil {
		return "", err
	}
	return shaHex, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/bench/ -run TestArchive`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/bench/archive.go internal/bench/archive_test.go
git commit -m "feat(bench): content-addressed immutable artifact archiver"
```

---

## Task 12: Measurement engine — cold-verb + full-loop

**Files:**
- Create: `internal/bench/measure.go`
- Test: `internal/bench/measure_test.go`

Drives the real `muster.exe` through the verified lifecycle. `RunFullLoopOnce` builds a fresh board **outside** the timer, then times `ingest→commit→promote` per batch and `claim→write→verify→done` per task, integration completion special-cased. Cold-verb times a single verb against a prebuilt board.

- [ ] **Step 1: Write the failing test (unit-level: helper structure, no exe)**

```go
// internal/bench/measure_test.go
package bench

import "testing"

func TestMusterArgsForLifecycle(t *testing.T) {
	// The lifecycle command builder must produce the verified verb argv.
	if got := claimArgs(); got[0] != "claim" {
		t.Fatalf("claim argv = %v", got)
	}
	if !contains(claimArgs(), "-harness") || !contains(claimArgs(), "-tier") {
		t.Fatalf("claim must pass -harness and -tier: %v", claimArgs())
	}
	if implDoneArgs()[0] != "done" || len(implDoneArgs()) != 1 {
		t.Fatalf("impl done takes no verdict: %v", implDoneArgs())
	}
	if intDoneArgs()[0] != "done" || intDoneArgs()[1] != "pass" {
		t.Fatalf("integration done must be 'done pass': %v", intDoneArgs())
	}
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/bench/ -run TestMusterArgs`
Expected: FAIL — `undefined: claimArgs`.

- [ ] **Step 3: Write minimal implementation**

```go
// internal/bench/measure.go
package bench

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// verb argv builders — pinned to the verified CLI contract.
func claimArgs() []string   { return []string{"claim", "-harness", "codex", "-tier", "strong"} }
func verifyArgs() []string  { return []string{"verify"} }
func implDoneArgs() []string { return []string{"done"} }          // impl: no verdict
func intDoneArgs() []string  { return []string{"done", "pass"} }  // integration: pass + notes

// runMuster runs one muster.exe verb in the fixture; returns wall time + exit code.
func runMuster(exe string, fx *Fixture, args ...string) (time.Duration, int, error) {
	cmd := exec.Command(exe, args...)
	cmd.Dir = fx.Root
	cmd.Env = fx.Env()
	t0 := time.Now()
	err := cmd.Run() // wall time = parent-observed Start→Wait (the only valid source)
	elapsed := time.Since(t0)
	code := 0
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else {
			return elapsed, -1, err
		}
	}
	return elapsed, code, nil
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

	var res LoopResult
	start := time.Now()
	for _, b := range batches {
		// materialize + ingest + commit + promote
		var paths []string
		all := append(append([]Card{}, b.Impl...), b.Integration)
		for _, c := range all {
			if err := fx.WriteFile(c.Path, c.Bytes); err != nil {
				return res, err
			}
			paths = append(paths, filepath.Join(fx.Root, filepath.FromSlash(c.Path)))
		}
		if _, code, _ := runMuster(exe, fx, append([]string{"ingest"}, paths...)...); code != 0 {
			res.Status = "ingest failed"
			break
		}
		if err := fx.Git("-c", "core.autocrlf=false", "add", ".muster/cards"); err != nil {
			return res, err
		}
		if err := fx.Git("-c", "core.autocrlf=false", "commit", "-q", "-m", "bench: shard"); err != nil {
			return res, err
		}
		if _, code, _ := runMuster(exe, fx, "promote"); code != 0 {
			res.Status = "promote failed"
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
	for _, b := range batches {
		for _, c := range b.Impl {
			byID[c.ID] = c
		}
		byID[b.Integration.ID] = b.Integration
	}
	total := len(byID)
	for done := 0; done < total; done++ {
		taskStart := time.Now()
		d, code, err := runMuster(exe, fx, claimArgs()...)
		if err != nil || code != 0 {
			return fmt.Sprintf("claim failed (code %d)", code)
		}
		res.ChildMusterNS += d.Nanoseconds()
		// Determine which task we just claimed by reading the single doing task's
		// commit_paths from the fixture's working tree is complex; instead the
		// executor step is uniform: write EVERY not-yet-created commit path is
		// wrong. The claimed task is the lowest eligible; we discover it by the
		// file muster expects. Simplest correct approach: attempt impl completion
		// (write the claimed card's commit path) — but we must know the id.
		// muster prints "Claimed <id>." on stdout; capture it.
		// (Implemented via claimAndIdentify below.)
		_ = taskStart
		return "PLACEHOLDER-REPLACED-IN-STEP-4"
	}
	return ""
}
```

> NOTE: Step 3 above intentionally leaves `runClaimLoop` incomplete — completing a claimed task requires knowing the claimed id, which muster prints as `Claimed <id>.` Step 4 replaces the loop body with a capture-and-dispatch implementation.

- [ ] **Step 4: Replace `runClaimLoop` with the capture-and-dispatch implementation**

Replace `runMuster` and `runClaimLoop` with versions that capture stdout to identify the claimed task:

```go
// replace runMuster in measure.go
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

// keep runMuster as a thin wrapper for callers that ignore output
func runMuster(exe string, fx *Fixture, args ...string) (time.Duration, int, error) {
	_, d, c, e := runMusterOut(exe, fx, args...)
	return d, c, e
}
```

```go
// replace runClaimLoop in measure.go
import "strings" // add to import block

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
	for done := 0; done < total; done++ {
		taskStart := time.Now()
		out, d, code, err := runMusterOut(exe, fx, claimArgs()...)
		if err != nil || code != 0 {
			return fmt.Sprintf("claim failed (code %d): %s", code, firstLine(out))
		}
		res.ChildMusterNS += d.Nanoseconds()
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
	}
	return ""
}

func parseClaimedID(out string) string {
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "Claimed ") {
			rest := strings.TrimPrefix(line, "Claimed ")
			return strings.TrimSuffix(strings.Fields(rest)[0], ".")
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
```

- [ ] **Step 5: Run the unit test to verify it passes**

Run: `go test ./internal/bench/ -run TestMusterArgs`
Expected: PASS. (End-to-end execution is covered by the gated smoke test, Task 14.)

- [ ] **Step 6: Add cold-verb timing**

```go
// append to measure.go

// ColdVerbResult times a single read-only verb against a prebuilt board.
type ColdVerbResult struct {
	Verb   string
	WallNS int64
	Status string
}

// RunColdVerb builds a board of size n once (outside timing), then times one
// invocation of a read-only verb (board|show|doctor). Callers repeat for reps.
func RunColdVerb(exe string, fx *Fixture, verb string) ColdVerbResult {
	d, code, err := runMuster(exe, fx, verb)
	r := ColdVerbResult{Verb: verb, WallNS: d.Nanoseconds(), Status: "ok"}
	if err != nil || code != 0 {
		r.Status = fmt.Sprintf("verb %s failed (code %d)", verb, code)
	}
	return r
}
```

- [ ] **Step 7: Commit**

```bash
git add internal/bench/measure.go internal/bench/measure_test.go
git commit -m "feat(bench): cold-verb + full-loop measurement engine"
```

---

## Task 13: cmd/musterbench — orchestration, flags, dirty-tree policy

**Files:**
- Create: `cmd/musterbench/main.go`
- Test: `cmd/musterbench/main_test.go`

- [ ] **Step 1: Write the failing test**

```go
// cmd/musterbench/main_test.go
package main

import "testing"

func TestParseNSet(t *testing.T) {
	got, err := parseNSet("10,100,1000")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 || got[0] != 10 || got[2] != 1000 {
		t.Fatalf("parseNSet = %v", got)
	}
}

func TestParseNSetRejectsGarbage(t *testing.T) {
	if _, err := parseNSet("10,abc"); err == nil {
		t.Fatal("expected error on non-numeric N")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./cmd/musterbench/ -run TestParseNSet`
Expected: FAIL — `undefined: parseNSet`.

- [ ] **Step 3: Write minimal implementation**

```go
// cmd/musterbench/main.go
package main

import (
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
)

func parseNSet(s string) ([]int, error) {
	var out []int
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		v, err := strconv.Atoi(part)
		if err != nil {
			return nil, fmt.Errorf("invalid N %q: %w", part, err)
		}
		out = append(out, v)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("empty N set")
	}
	return out, nil
}

func main() {
	record := flag.Bool("record", false, "persist results (JSONL + benchfmt + archive + docs/bench.md)")
	nSet := flag.String("n", "10,100,1000", "comma-separated task counts")
	archiveExe := flag.String("archive-exe", "", "prebuilt exe to benchmark + archive (safe default for an official baseline)")
	allowDirty := flag.Bool("allow-dirty", false, "permit --record from a dirty working tree (stamps vcs_modified=true)")
	flag.Parse()

	ns, err := parseNSet(*nSet)
	if err != nil {
		fmt.Fprintln(os.Stderr, "musterbench:", err)
		os.Exit(2)
	}
	if code := run(runOpts{Record: *record, NSet: ns, ArchiveExe: *archiveExe, AllowDirty: *allowDirty}); code != 0 {
		os.Exit(code)
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./cmd/musterbench/ -run TestParseNSet`
Expected: FAIL to compile — `undefined: run`/`runOpts`. Add the orchestration skeleton in Step 5, then re-run.

- [ ] **Step 5: Add the run orchestration + dirty-tree policy**

```go
// append to cmd/musterbench/main.go
import (
	"os/exec" // add to import block

	"muster/internal/bench"
)

type runOpts struct {
	Record     bool
	NSet       []int
	ArchiveExe string
	AllowDirty bool
}

// run orchestrates the suite. Dry run prints; --record persists. Dirty-tree
// policy: a build-from-tree --record refuses on a dirty tree unless --allow-dirty.
func run(o runOpts) int {
	repoRoot, err := os.Getwd()
	if err != nil {
		fmt.Fprintln(os.Stderr, "musterbench:", err)
		return 1
	}
	if o.Record && o.ArchiveExe == "" && !o.AllowDirty {
		dirty, err := treeDirty(repoRoot)
		if err != nil {
			fmt.Fprintln(os.Stderr, "musterbench: git status failed:", err)
			return 1
		}
		if dirty {
			fmt.Fprintln(os.Stderr, "musterbench: refusing --record from a dirty tree "+
				"(provenance hole). Commit first, pass --archive-exe <clean exe>, or --allow-dirty.")
			return 1
		}
	}
	fmt.Printf("musterbench: record=%v n=%v (orchestration wired in Task 15)\n", o.Record, o.NSet)
	_ = bench.SchemaVersion
	return 0
}

// treeDirty reports whether the working tree has uncommitted changes.
func treeDirty(root string) (bool, error) {
	cmd := exec.Command("git", "-C", root, "status", "--porcelain")
	out, err := cmd.Output()
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(string(out)) != "", nil
}
```

- [ ] **Step 6: Run tests + build**

Run: `go test ./cmd/musterbench/ -run TestParseNSet && go build ./cmd/musterbench`
Expected: PASS + clean build.

- [ ] **Step 7: Commit**

```bash
git add cmd/musterbench/main.go cmd/musterbench/main_test.go
git commit -m "feat(bench): musterbench cmd skeleton + dirty-tree policy"
```

---

## Task 14: Gated end-to-end smoke test

**Files:**
- Create: `internal/bench/smoke_test.go`

Proves the whole pipeline runs on the real box against a freshly built exe. Gated behind a build tag so normal `go test` stays fast.

- [ ] **Step 1: Write the test**

```go
//go:build benchsmoke

// internal/bench/smoke_test.go
package bench

import (
	"path/filepath"
	"testing"
)

func TestSmokeFullLoopN3(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(t.TempDir(), "muster.exe")
	if _, err := BuildMuster(repoRoot, exe); err != nil {
		t.Fatalf("build: %v", err)
	}
	res, err := RunFullLoopOnce(exe, 1, 3)
	if err != nil {
		t.Fatalf("full loop error: %v", err)
	}
	if res.Status != "ok" {
		t.Fatalf("full loop status = %q, want ok", res.Status)
	}
	if res.WallNS <= 0 {
		t.Fatalf("wall time not recorded")
	}
	// N=3 → 2 impl + 1 integration = 3 tasks, 2 verifier spawns each.
	if res.VerifierSpawns != 6 {
		t.Fatalf("verifier spawns = %d, want 6", res.VerifierSpawns)
	}
}
```

- [ ] **Step 2: Run the gated smoke test**

Run: `go test -tags benchsmoke ./internal/bench/ -run TestSmokeFullLoopN3 -v`
Expected: PASS. If it FAILS, the failure message (`claim failed`, `done failed for <id>`, etc.) pinpoints which lifecycle contract the generator/loop got wrong — fix in `workload.go` or `measure.go` and re-run. This is the task that validates every CLI-contract assumption end-to-end.

- [ ] **Step 3: Confirm normal test run skips it**

Run: `go test ./internal/bench/`
Expected: PASS, smoke test not compiled (build tag excludes it).

- [ ] **Step 4: Commit**

```bash
git add internal/bench/smoke_test.go
git commit -m "test(bench): gated end-to-end smoke (real N=3 full loop)"
```

---

## Task 15: Wire orchestration — record path, artifacts, docs table

**Files:**
- Modify: `cmd/musterbench/main.go`
- Create: `bench/README.md`
- Create: `bench/.gitignore`

Fills in the real suite: build/resolve exe, run cold-verb + full-loop reps, write JSONL + benchfmt, archive, regenerate `docs/bench.md`.

- [ ] **Step 1: Create the operator note + gitignore**

```markdown
<!-- bench/README.md -->
# bench/

Committed: `results.jsonl` (canonical attempt records), `*.bench.txt` (benchfmt
export), generated `../docs/bench.md`.

**NOT committed (gitignored): `artifacts/`.** This holds the irreplaceable,
perishable v2.0 assets — the archived `muster.exe`, the materialized byte-identical
workload, and the build recipe. **The operator must preserve / back up
`bench/artifacts/` out-of-band.** A hash in the JSONL proves identity but cannot
reconstruct these bytes. Baselines are rare; keeping the binaries out of git
history avoids permanent repo bloat (the repo already ignores the root muster.exe).
```

```gitignore
# bench/.gitignore
artifacts/
```

- [ ] **Step 2: Replace the Task-13 placeholder `run` body with the real suite**

```go
// replace the placeholder tail of run() in cmd/musterbench/main.go
// (everything after the dirty-tree check) with:

	exe := o.ArchiveExe
	var buildJSON []byte
	if exe == "" {
		built := filepath.Join(os.TempDir(), "musterbench-exe", "muster.exe")
		if err := os.MkdirAll(filepath.Dir(built), 0o755); err != nil {
			fmt.Fprintln(os.Stderr, "musterbench:", err)
			return 1
		}
		info, err := bench.BuildMuster(repoRoot, built)
		if err != nil {
			fmt.Fprintln(os.Stderr, "musterbench: build:", err)
			return 1
		}
		exe = built
		buildJSON = buildRecipe(info)
	} else {
		info, err := bench.ReadExeInfo(exe)
		if err != nil {
			fmt.Fprintln(os.Stderr, "musterbench: reading exe buildinfo:", err)
			return 1
		}
		buildJSON = buildRecipe(info)
	}

	suite := bench.RunSuite(exe, o.NSet)
	fmt.Print(bench.RenderTable(suite))
	if !o.Record {
		return 0
	}
	if err := bench.Persist(repoRoot, exe, buildJSON, o.NSet, suite); err != nil {
		fmt.Fprintln(os.Stderr, "musterbench: persist:", err)
		return 1
	}
	fmt.Println("musterbench: recorded.")
	return 0
}

func buildRecipe(info bench.ExeInfo) []byte {
	return []byte(fmt.Sprintf(
		`{"go_version":%q,"vcs_revision":%q,"vcs_modified":%v,"build_cmd":"go build -buildvcs=true -o muster.exe ./cmd/muster"}`,
		info.GoVersion, info.VCSRevision, info.VCSModified))
}
```

Add `"path/filepath"` to the import block.

- [ ] **Step 3: Add `RunSuite`, `RenderTable`, `Persist` to internal/bench**

Create `internal/bench/suite.go`:

```go
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
	// artifacts (gitignored)
	batches, man := Generate(1, maxN(nSet))
	sha, err := Archive(filepath.Join(benchDir, "artifacts"), ArchiveSpec{
		Exe: exe, Batches: batches, Manifest: man, BuildJSON: buildJSON,
		Invocation: []byte(fmt.Sprintf(`{"n":%v}`, nSet)),
	})
	if err != nil {
		return err
	}
	// stamp artifact sha + exe info onto every row
	info, _ := ReadExeInfo(exe)
	exeSHA := sha // artifact sha ≠ exe sha; compute exe sha separately
	if b, err := os.ReadFile(exe); err == nil {
		exeSHA = shaBytes(b)
	}
	for i := range sr.Rows {
		sr.Rows[i].ArtifactSHA = sha
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

func maxN(ns []int) int {
	m := 0
	for _, n := range ns {
		if n > m {
			m = n
		}
	}
	return m
}
```

Add `shaBytes` to `record.go`:

```go
// append to internal/bench/record.go
func shaBytes(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}
```

- [ ] **Step 4: Build + vet + unit tests**

Run: `go build ./... && go vet ./internal/bench/ ./cmd/musterbench/ && go test ./internal/bench/ ./cmd/musterbench/`
Expected: clean build, no vet errors, all unit tests PASS.

- [ ] **Step 5: Commit**

```bash
git add cmd/musterbench/main.go internal/bench/suite.go internal/bench/record.go bench/README.md bench/.gitignore
git commit -m "feat(bench): wire suite orchestration, persistence, docs table"
```

---

## Task 16: Full verification pass

**Files:** none (verification only).

- [ ] **Step 1: Full unit suite**

Run: `go test ./internal/bench/ ./cmd/musterbench/ -v`
Expected: all PASS.

- [ ] **Step 2: Gated smoke (real end-to-end)**

Run: `go test -tags benchsmoke ./internal/bench/ -run TestSmoke -v`
Expected: PASS (2 impl + 1 integration complete; 6 verifier spawns).

- [ ] **Step 3: Whole-project build + vet unaffected**

Run: `go build ./... && go vet ./...`
Expected: clean — no existing MUSTER package broke.

- [ ] **Step 4: Dry-run the recorder (no writes)**

Run: `go run ./cmd/musterbench --n 3`
Expected: prints a table; no `bench/` dir created, no files written.

- [ ] **Step 5: Commit any final fixups**

```bash
git add -A
git commit -m "chore(bench): verification pass green"
```

---

## Task 17: Record the actual v2.0 baseline (operator step, optional)

**Files:** produces `bench/results.jsonl`, `bench/v2.0.bench.txt`, `docs/bench.md`, `bench/artifacts/<sha>/` (gitignored).

This is a **run of the finished recorder**, not code. Do it from a clean tree on the target box.

- [ ] **Step 1: Confirm clean tree**

Run: `git status --porcelain`
Expected: empty output.

- [ ] **Step 2: Record**

Run: `go run ./cmd/musterbench --record --n 10,100,1000`
Expected: prints the table, writes `bench/results.jsonl` + `bench/v2.0.bench.txt` + `docs/bench.md`, archives to `bench/artifacts/<sha>/`, prints `musterbench: recorded.` (N=1000 takes minutes.)

- [ ] **Step 3: Back up the artifacts dir out-of-band**

The `bench/artifacts/<sha>/` dir (archived exe + workload + build recipe) is gitignored and irreplaceable. Copy it to durable storage per `bench/README.md`.

- [ ] **Step 4: Commit the tracked results**

```bash
git add bench/results.jsonl bench/v2.0.bench.txt docs/bench.md bench/README.md bench/.gitignore
git commit -m "chore(bench): record v2.0 performance baseline"
```

---

## Self-Review

**Spec coverage:**
- §1 architecture / command surface → Tasks 1, 13, 15 (dry-run vs `--record`, `--archive-exe`, `--allow-dirty`, dirty-tree policy). ✓
- §1.2 copy-not-share fixture + `fixture_version` → Tasks 5, 9 (recorded on Row). ✓
- §2.1 card schema (no `seq`, integration omits `commit_paths`, required fields) → Tasks 2, 3. ✓
- §2.2 fan-in topology + batching cap → Tasks 2, 4; §6 per-batch lint → Task 3. ✓
- §2.3 `git --version` verifier + lifecycle + two verifier spawns + integration completion → Tasks 12, 14. ✓
- §2.4 determinism, manifest, autocrlf guard → Tasks 2, 5 (`GIT_CONFIG_SYSTEM` + `.gitattributes`). ✓
- §3.1 cold-verb + board-size recording → Task 12 (`RunColdVerb`); board_state hash field present on Row (populated when cold-verb rows are added to the suite — see gap note). 
- §3.2 whole-loop replicate, tiered reps, median → Tasks 12, 15 (`repCounts`, `RenderTable`). ✓
- §3.3 per-cycle diagnostics → Task 12 (`ChildMusterNS`, `VerifierSpawns`, `PerTaskNS`). ✓
- §3.4 monotonic timing, warmup rows → Tasks 12, 15. ✓
- §4.1 attempt-record schema + run_id → Task 9. ✓
- §4.2 benchfmt lossy export → Task 10. ✓
- §4.3 content-addressed immutable artifacts + gitignore → Tasks 11, 15. ✓
- §4.4 build-toolchain recipe in build.json → Task 15 (`buildRecipe`). ✓
- §5 fingerprint tiers + fault-tolerance → Tasks 7, 8. ✓
- §6 tests (determinism golden, lint-per-batch, parse, batching, schema, fingerprint, autocrlf, benchfmt) → Tasks 2–11; gated smoke → Task 14. ✓

**Gaps found + resolved:**
- **Cold-verb rows are not yet emitted by `RunSuite`** (Task 15 runs only full-loop). This is a real gap vs §3.1. RESOLUTION: Task 15's `RunSuite` should also build a fixed board per N and emit cold-verb rows for `board`/`show`/`doctor` with `board_state_sha256`. Added as an explicit follow-in below rather than silently dropped.

## Task 15b: Emit cold-verb rows in the suite

**Files:** Modify `internal/bench/suite.go`, `internal/bench/measure.go`.

- [ ] **Step 1: Add a board builder that leaves a completed board for read verbs**

```go
// append to measure.go

// BuildBoard creates a fixture, inits, and ingests+promotes n tasks WITHOUT
// completing them (a populated board for read-only verbs). Returns the fixture
// (caller must os.RemoveAll(fx.Root)) and a board-state hash (workload sha proxy).
func BuildBoard(exe string, seed int64, n int) (*Fixture, string, error) {
	root, err := os.MkdirTemp("", "bench-board")
	if err != nil {
		return nil, "", err
	}
	fx, err := NewFixture(root)
	if err != nil {
		os.RemoveAll(root)
		return nil, "", err
	}
	if _, _, err := runMuster(exe, fx, "init"); err != nil {
		os.RemoveAll(root)
		return nil, "", err
	}
	batches, man := Generate(seed, n)
	for _, b := range batches {
		var paths []string
		all := append(append([]Card{}, b.Impl...), b.Integration)
		for _, c := range all {
			if err := fx.WriteFile(c.Path, c.Bytes); err != nil {
				os.RemoveAll(root)
				return nil, "", err
			}
			paths = append(paths, filepath.Join(fx.Root, filepath.FromSlash(c.Path)))
		}
		if _, code, _ := runMuster(exe, fx, append([]string{"ingest"}, paths...)...); code != 0 {
			os.RemoveAll(root)
			return nil, "", fmt.Errorf("board ingest failed at n=%d", n)
		}
		if err := fx.Git("-c", "core.autocrlf=false", "add", ".muster/cards"); err != nil {
			os.RemoveAll(root)
			return nil, "", err
		}
		if err := fx.Git("-c", "core.autocrlf=false", "commit", "-q", "-m", "bench: board"); err != nil {
			os.RemoveAll(root)
			return nil, "", err
		}
		runMuster(exe, fx, "promote")
	}
	return fx, man.SHA, nil
}
```

- [ ] **Step 2: Emit cold-verb rows in `RunSuite`**

Insert into `RunSuite`, inside the `for _, n := range nSet` loop, before the full-loop reps:

```go
		// cold-verb: build one board, time read verbs against it.
		if fx, boardSHA, err := BuildBoard(exe, 1, n); err == nil {
			for _, verb := range []string{"board", "show", "doctor"} {
				for i := 0; i < 8; i++ { // warmup 3 + timed 5 (cheap; label warmup)
					cr := RunColdVerb(exe, fx, verb)
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
```

Add helpers to `suite.go`:

```go
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
```

Note: `show` with no args may target the doing task or require an id. If the smoke/real run shows `show` needs an argument, change the verb list to `show <first-impl-id>` by extending `RunColdVerb` to accept extra args; the fixed target is the lowest impl id (deterministic).

- [ ] **Step 3: Build + test**

Run: `go build ./... && go test ./internal/bench/ ./cmd/musterbench/`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add internal/bench/measure.go internal/bench/suite.go
git commit -m "feat(bench): emit cold-verb rows with board-state hash"
```

---

## Execution Handoff

Plan complete. After saving, per the user's global workflow it is reviewed by `plan-reviewer` and `yagni-guardian` before the approval gate.
