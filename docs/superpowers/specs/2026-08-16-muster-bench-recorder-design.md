# MUSTER bench recorder — design spec

Status: design agreed 2026-08-16. Supersedes the harness-methodology portion of
`docs/bench-design.md` (that doc's "append a row per version, compare down the
column" premise is rejected here as temporally confounded — see §0).

Scope: a **thin, forward-compatible benchmark recorder** that captures a v2.0
performance baseline. It records data; it does not compute a regression verdict.
The paired-comparison stats engine is deferred until a v2.1 candidate exists to
exercise it.

## 0. Why a recorder, not a comparison dashboard

The original `docs/bench-design.md` framed the benchmark as an append-only table:
first row v2.0, later versions append rows, compare down the column. That design
is **temporally confounded**: a v2.0 number recorded today versus a v2.1 number
recorded months later cannot separate a code regression from Windows Defender
definition updates, OS patches, thermal state, or machine drift. No choice of
statistic repairs a confounded experiment.

The correct regression protocol is a **same-day paired run**: archive the v2.0
binary; when a candidate lands, run archived-v2.0 and the candidate side by side
on the same box, same day, in matched AB/BA blocks, and compare within-block.
The design doc itself anticipated this as a fallback ("Known limits: re-run the
old tagged version side by side… same day"); this spec promotes it to **the**
method.

Consequence for scope: the only **perishable, non-recreatable** assets are (a)
the v2.0 binary, (b) a byte-identical materialized workload, and (c) today's box
fingerprint. Capture those now. The pairing/stats engine is untestable today
(there is no second binary to pair against — a v2.0-vs-identical-v2.0 negative
control is possible but out of scope), so it is deferred. The recorder's job is
to produce **pairing-complete data** so the deferred engine is not boxed in.

This decision followed `superpowers:brainstorming` with three external adversarial
reviews (Codex gpt-5.6-sol) and one independent `solution-auditor` pass. Key
corrections captured below are attributed inline where they changed the design.

## 1. Architecture & command surface

New, isolated packages; no existing code is modified.

```
cmd/musterbench/main.go        flag parsing, orchestration, output
internal/bench/
  fixture.go       temp-git-repo + pinned/hardened GIT_CONFIG (copied from
                   test/process, NOT imported — see §1.2)
  workload.go      ordered-slice deterministic card generator + manifest
  measure.go       cold-verb + full-loop timers, warmup, rep loop
  record.go        JSONL writer (canonical) + benchfmt .txt writer (lossy)
  fingerprint.go   env/Defender/storage/exe/harness capture
  archive.go       copy exe + materialized workload bytes into content-addressed dir
bench/                          committed output (see §4)
  results.jsonl                 canonical, append-only
  artifacts/<artifact_sha>/     immutable per-run artifacts
  <session>.bench.txt           benchfmt export
docs/bench.md                   generated descriptive table
```

### 1.1 Command surface (thin — no stats engine)

```
musterbench                 dry run: print table to stdout, write no PERSISTENT
                            results (still creates temp repos + temp commits, all
                            cleaned up). Default, safe.
musterbench --record        run suite, append JSONL + benchfmt + archive +
                            regen docs/bench.md
musterbench --n 10,100      override scaling set (default 10,100,1000)
musterbench --archive-exe P  exe to benchmark + archive (default: build fresh from HEAD)
```

- All persistent writes gated behind `--record` (writing files from a plain exe
  is otherwise accident-prone).
- "Writes nothing" is imprecise — the default still spawns temp repos and thousands
  of temp commits. It writes **no persistent benchmark results**.
- Lives under `cmd/`, so `go build ./...` compiles it — accepted. It is never
  linked into `muster.exe` (Go links only imported packages) and `go build` does
  not execute it. A build-tag/`_test.go` shape would make invocation, archival,
  and reproducibility awkward.

**Not in scope:** no paired A/B runner, no permutation/sign test, no log-ratio, no
benchstat invocation. The recorder only produces pairing-complete data.

### 1.2 Fixture: copy, do not share

The `test/process` fixture (temp-git-repo + GIT_CONFIG pinning) is copied into
`internal/bench`, not imported and not extracted to a shared package. Reasons:
`test/process` is `//go:build process` test-only and its helpers are coupled to
`testing.T`/`TestMain`; a neutral shared package would need a refactor that buys
little; and **benchmark fixture stability is part of the measurement definition**
— it must resist incidental change that test ergonomics would otherwise impose.

Guard against silent drift: the copied fixture carries an explicit
`fixture_version`, recorded on every row, with an invariants test (§6).

## 2. Workload generator & determinism

`Generate(seed, n) -> ([]Card, Manifest)` — a pure function. Ordered slice, never
a Go map (the process fixture iterates a map, which would make ingest order and
row IDs nondeterministic).

### 2.1 Topology — verified against `internal/card/lint.go`

Ingest lints in `Full` mode. The generated workload must pass with **zero
findings**. Verified constraints:

- **Filename/id** `^[a-z0-9-]+-\d{2}-[a-z0-9-]+$`; `id == filename stem`
  (lint.go:90,97). Uniqueness rides the **suffix**, so a fixed 2-digit sequence
  (e.g. `01`) with a varying suffix is legal: `bench-01-t000001`,
  `bench-01-t000002`, … The 2-digit sequence is **not** a batch-size cap.
- **Rule 11**: exactly **one** integration task per batch — **seq 99, tier
  strong, depends_on every other batch id** (lint.go:200-227).
- **Rule 13**: impl/fix must have **non-empty commit_paths** (lint.go:191). The
  executor step therefore must create the commit_paths file; `done` stages and
  commits it. This file-write cannot be elided.
- **Rule 5**: verify path-tokens (containing `/`) must be in protected/commit_paths.
- **Rules 4, 7-10**: no shell metacharacters; no TBD/TODO/FIXME/`{brace}`/dotted
  steps/judgment language; body headings `# … ## Context … ## Steps ##
  Acceptance` in order.

**Topology = fan-in**: N−1 independent impl tasks + one seq-99 integration task
depending on all of them. This is the app's real batch shape and stresses
dependency-resolution SQL repeatedly (claim and done both invoke promotion). An
all-independent flat set is **invalid** (no integration task → rule 11 fails); a
synthetic DAG adds a confounding variable with no tripwire benefit.

### 2.2 Batching — the real cap is card size, not sequence space

**Rule 6: ≤300 lines / 16 KB per card.** The integration task lists every other
task in `depends_on` (one YAML line each), so at large N the integration card
exceeds the 300-line cap. The batch ceiling is therefore ≈ **250-280 tasks**
(300 lines minus integration header), not ~98 (sequence space) and not unlimited.

- N=10, N=100 → one ingest batch each.
- N=1000 → ~4 ingest batches, each with its own seq-99 integration depending on
  its ~250 siblings.

`batchCount(N) = ceil(N / BATCH_MAX)` where `BATCH_MAX` is chosen so the largest
integration card stays under 300 lines / 16 KB (target ~250; exact value pinned
by the size-cap test in §6).

### 2.3 Verifier

Verify command = `git --version` with `expect_exit: 0`. Git is already a hard
dependency, is spawned directly without a shell, needs no executor-created input,
has no path tokens (passes rule 5), and is already the integration-fixture
verifier in `test/process`. This replaces the originally-planned `findstr`, which
was Windows-only and required a token file for the verify step itself.

The real `muster verify` spawns the card command via `exec.CommandContext`
(verify.go:36) — this spawn is part of the real verify path, not removable noise.
`done` re-runs the verify block as its own "done-check" (done.go:176), so the
full loop incurs **two verifier spawns per task**. The metric is therefore named
honestly: **"MUSTER lifecycle with minimal external verifier"**, not "pure board
mechanics".

### 2.4 Determinism & manifest

- Fixed template, only the index substituted, LF line endings pinned. No
  timestamps/UUIDs/clock reads leak into card bytes. Seed fixed (default 1),
  recorded.
- Manifest = ordered `[{index, id, sha256(card-bytes)}]` + top-level
  `manifest_sha256` over the concatenation, recorded on every JSONL row.
- `--record` writes the **materialized card bytes** to the artifact dir (§4), not
  merely the hash — a hash proves identity but cannot reconstruct bytes.
- Generator version string recorded so generator drift is detectable.

### 2.5 Corrected premise

The mental model "every board state transition = git commit + SQLite write" is
**false**. Only `init` and `done` create git commits (plus the external card
commit the harness makes between ingest and promote). `claim`, `verify`,
`ingest`, `promote` do **not** commit. The full single-task cycle is:
materialize → ingest → commit cards (external) → promote → claim → write
commit_paths file → verify → done.

## 3. Measurement modes, timing boundaries, per-cycle breakdown

### 3.1 Cold-verb latency (read-mostly)

Verbs `board`, `show`, `doctor` against a pre-built fixed board (built once,
outside timing). Each run = a fresh `muster.exe` process, spawn included. 30-50
timed runs after 3-5 warmup runs. `claim`/`promote` are **excluded** here (they
mutate — not repeatable against a static board); they are measured only inside
the full-loop.

### 3.2 Full-loop (whole-loop replicate)

Per repetition: build a fresh board **outside** the timer, then
`[start] for each batch { ingest → commit cards → promote }; for each task {
claim → write commit_paths file → verify → done } [stop]`.

- The statistical sample is one whole-loop `total_elapsed`. Per-task timings
  within one loop are **dependent** (git history and event chain grow, SQLite WAL
  checkpoints, position-dependent cost) and must **not** be pooled as repeated
  measures — that is pseudoreplication. They are kept only as a positional
  diagnostic trace.
- Headline = **median** across reps; total wall-time is primary, tasks/sec shown
  beside it. Minimum is a labeled best-observed diagnostic only, never the
  headline (min-vs-min compares the luckiest run each day, not "did it get
  slower"). p95 is descriptive only where reps are cheap and is **omitted** at
  N=1000; reliable tail estimation needs ~100+ reps.
- Reps tiered by per-rep cost: N=10 → 20-30, N=100 → 10-15, N=1000 → 3-5 (labeled
  **preliminary**; a 3-5-rep median is "a few measurements", not a stable
  estimate). Raw per-rep timings are always stored so statistics can be
  recomputed if rep counts grow later.

### 3.3 Per-cycle child-invocation breakdown (diagnostics)

Each timed rep also records, as diagnostics (not headline): sum of `muster.exe`
child wall-times, the two verifier spawns per task, git-commit count, and
fake-executor file-write time. Do **not** subtract the file-write from the
headline after the fact — its existence also changes later `git status`, staging,
hashing, Defender scanning, and commit cost.

### 3.4 Timer boundaries

Outside timer: board construction, card materialization, git-config setup.
Inside timer: everything an agent triggers (ingest → promote → claim → verify →
done, including the contract-forced file-write). Timing uses monotonic ns, never
wall-clock deltas.

### 3.5 Warmup

3-5 runs for cold-verb; 1-2 whole loops for N=100/1000. Warmup records are marked
`warmup:true` with a reason — never silently dropped.

## 4. Data schema, benchfmt export, immutable artifacts

### 4.1 Canonical record — `bench/results.jsonl`

Append-only, one JSON object per rep, pairing-native from day one (arm/pair fields
null for the solo v2.0 run):

```jsonc
{
  "schema_version": 1,
  "run_id": "<stable id derived from run params+seq — no clock/random>",
  "experiment_id": "v2.0-baseline",
  "session_id": "<per-invocation id>",
  "arm": null,                 // "old" | "new" when paired
  "pair_id": null,
  "block_id": null,
  "planned_order": null,       // "AB" | "BA"
  "actual_order_index": 0,
  "measurement": "full_loop",  // | "cold_verb"
  "verb": null,                // cold_verb only
  "n": 100,
  "rep_ordinal": 3,
  "warmup": false,
  "excluded": false,
  "exclude_reason": null,      // never silently drop — reason or null
  "seed": 1,
  "generator_version": "1",
  "workload_manifest_sha256": "...",
  "batch_count": 1,
  "topology": "fanin",
  "wall_ns": 1234567890,       // whole-loop total (monotonic)
  "per_task_ns_trace": [ ],    // positional diagnostic — DEPENDENT, not samples
  "child_muster_ns_sum": 0,
  "verifier_spawns": 2,        // per task (verify + done-check)
  "git_commit_count": 0,
  "executor_write_ns": 0,
  "started_utc": "…Z",         // provenance only, NOT used for timing
  "ended_utc": "…Z",
  "exe_sha256": "...",
  "exe_buildinfo": { "go_version": "go1.25.0", "vcs_revision": "...", "vcs_modified": false },
  "harness_version": "1",
  "fixture_version": "1",
  "artifact_sha": "<content-addressed dir under bench/artifacts/>",
  "env": { }                   // §5
}
```

Rules baked in: never silently drop a sample (warmup/excluded always carry a
reason); `per_task_ns_trace` is explicitly dependent/diagnostic; timing is
monotonic `wall_ns`, `started_utc` is provenance only.

### 4.2 Lossy benchfmt export — `bench/<session>.bench.txt`

Go benchmark format (design 14313) for later `benchstat` convenience only:

```
goos: windows
goarch: amd64
pkg: muster-bench
BenchmarkFullLoop/n=100 1 1234567890 ns/op
BenchmarkFullLoop/n=100 1 1231110000 ns/op
```

- **Only stable comparison dimensions** in the benchmark name (`FullLoop/n=100`).
  Binary SHA, timestamps, and per-rep fingerprint stay **out** — putting them in
  config/name lines fragments benchstat grouping into singletons.
- One line per rep, `iters=1`, `ns/op` = the whole loop (labeled elsewhere as
  **not** per-task).
- benchstat is a **descriptive convenience** consumer. It is **not** the
  authoritative regression verdict: its Mann-Whitney U is unpaired and discards
  the matched-block structure; same-day interleaving reduces bias but does not
  create independence, and within-block correlation can make its p-value invalid
  rather than merely conservative. The authoritative test (within-block paired
  candidate/control ratios) is deferred to v2.1; the schema preserves blocks so it
  can be built then.

### 4.3 Immutable content-addressed artifacts — `bench/artifacts/<artifact_sha>/`

```
bench/artifacts/<sha>/
  muster.exe        the archived v2.0 binary
  workload/         materialized card bytes (not just the hash)
  invocation.json   exact flags, N set, seed, HEAD sha, go version
  build.json        reproducible build info for the exe
```

- `<artifact_sha>` = hash over (exe bytes + workload bytes + invocation params);
  JSONL rows reference it.
- **Immutable**: a later `--record` from a different HEAD/N writes a *new* sha-dir
  and can never mutate artifacts backing earlier rows.
- **Real bytes archived, not hashes** — the guard against the most likely
  six-month failure (a manifest SHA proves a future reconstruction is wrong but
  cannot rebuild it). The reusable asset is the archived binary plus a
  byte-preserved, re-runnable workload.

### 4.4 `docs/bench.md`

Generated descriptive table: version, date, box tag, defender state, N, median
wall, range, tasks/sec. Explicitly labeled **descriptive; cross-time rows are not
a regression verdict — that requires a same-day paired run.**

## 5. Environment fingerprint

Capture is **descriptive** provenance, not causal explanation (a months-old
fingerprint cannot explain a diff — same-day paired runs do that). Tiered so the
baseline records without gold-plating.

**Tier 1 — must-have** (cheap, blocks nothing):
- `os`: `runtime.GOOS/GOARCH`, Windows build
- `cpu`: model, physical + logical cores
- `ram_total_bytes`
- `go_version`, `git_version`
- `defender_realtime`: tri-state true / false / **"unknown"** (query failure →
  "unknown", never "false")
- `defender_exclusions_cover_benchdir`: true / false / "unknown"
- `bench_temp_dir_volume`
- `box_tag`: stable `<short-cpu>-<hostname>` (comparisons valid only within one tag)

**Tier 2 — nice-to-have** (record if the probe is cheap + reliable; else
"unknown", never block): disk media type (NVMe/SSD/HDD) + free space behind the
bench dir; BitLocker / NTFS-compression / write-cache; power plan / AC-vs-battery
/ CPU freq policy; Controlled Folder Access + per-process Defender exclusion detail.

**Mechanics**: Go shells to PowerShell (`Get-MpComputerStatus`,
`Get-PhysicalDisk`, `Get-CimInstance Win32_Processor`). Each probe is isolated and
failure-tolerant — a failed probe writes `"unknown"` plus the probe error, never
aborts the run and never fabricates a value. Fingerprint is captured once per
session and stamped on every row; per-rep environment changes get a lightweight
re-check flag.

Tier 1 is the gate for "baseline recorded". Tier 2 is best-effort.

## 6. Testing the harness

Fast unit tests (plain `go test`, sub-second, no build tag) plus one gated smoke.
Tests assert structure, determinism, validity, and fault-tolerance — never
absolute timing (that is inherently noisy, which is the whole premise).

1. **Determinism**: `Generate(1,100)` byte-identical across two calls; a golden
   `manifest_sha256` constant catches any accidental generator change.
2. **Lint-validity**: generated cards pass the real `card.Lint(…, Full)` with
   zero findings at N=10, N=300 (batch boundary), N=1000 (multi-batch). Imports
   the production linter so the workload cannot silently drift out of contract.
3. **Batching math**: `batchCount(N)` respects the size cap; the largest
   integration card stays under 300 lines / 16 KB.
4. **Schema**: a JSONL row round-trips; required fields non-empty; `excluded`
   always paired with a reason.
5. **Fingerprint fault-tolerance**: a stubbed failing probe yields "unknown" +
   error, never panics, never fabricates.
6. **benchfmt export** parses back; only stable dims in names.

**Gated smoke** (`//go:build benchsmoke` or `-short`-skipped): one real N=3
full-loop against a freshly built exe in a temp repo — proves the whole pipeline
runs end to end on this box. Opt-in, not run in normal `go test`.

## 7. Open items deferred to implementation / v2.1

- Exact `BATCH_MAX` value (pinned by the §6 size-cap test).
- Whether the integration task's own `commit_paths` may be empty (type
  integration, so rule 13 does not apply) or needs a trivial file — resolve
  against lint at implementation.
- The paired-A/B comparison engine (archived-v2.0 vs candidate, matched AB/BA,
  within-block paired log-ratio + CI + threshold, paired permutation / sign test,
  order randomization). Built when a v2.1 candidate exists to exercise and
  validate it (v2.0-vs-identical-v2.0 negative control).
- Recording the actual v2.0 baseline row is a **run of the finished recorder**,
  not part of building it.

## 8. Non-goals

- Not a CI gate (Windows timing is too noisy to fail builds).
- Not a v1-vs-v2 comparison (v1 is retired).
- No absolute-latency SLAs or thresholds in this phase.
- Does not modify any existing MUSTER code.
