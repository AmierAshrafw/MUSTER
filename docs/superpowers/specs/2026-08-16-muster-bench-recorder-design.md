# MUSTER bench recorder — design spec

Status: design agreed 2026-08-16. Supersedes the harness-methodology portion of
`docs/bench-design.md` (that doc's "append a row per version, compare down the
column" premise is rejected here as temporally confounded — see §0).

Scope: a **thin, forward-compatible benchmark recorder** that captures a v2.0
performance baseline. It records data; it does not compute a regression verdict.
The paired-comparison stats engine is deferred until a v2.1 candidate exists to
exercise and validate it.

Provenance: this design followed `superpowers:brainstorming` with four external
adversarial reviews (Codex gpt-5.6-sol), one independent `solution-auditor` pass,
and two code-grounded subagent audits (fidelity + Windows feasibility). Code
claims below were verified against source at the cited lines; feasibility claims
were tested on the target box.

## 0. Why a recorder, not a comparison dashboard

The original `docs/bench-design.md` framed the benchmark as an append-only table:
first row v2.0, later versions append rows, compare down the column. That design
is **temporally confounded** — a v2.0 number recorded today versus a v2.1 number
recorded months later cannot separate a code regression from Windows Defender
definition updates, OS patches, thermal state, or machine drift. No choice of
statistic repairs a confounded experiment.

The correct regression protocol is a **same-day paired run**: archive the v2.0
binary; when a candidate lands, run archived-v2.0 and the candidate side by side
on the same box, same day, in matched AB/BA blocks, and compare within-block.
The design doc anticipated this as a fallback ("Known limits: re-run the old
tagged version side by side… same day"); this spec promotes it to **the** method.

Consequence for scope: the only **perishable, non-recreatable** assets are (a)
the v2.0 binary, (b) a byte-identical materialized workload, (c) the harness /
fixture / build recipe that defines the measurement, and (d) today's box
fingerprint (descriptive only). Capture those now. The pairing/stats engine is
untestable today (no second binary to pair against — a v2.0-vs-identical-v2.0
negative control is possible but out of scope), so it is deferred. The recorder's
job is to produce **complete, self-describing observations** — including failed
ones — so the deferred engine is not boxed in.

**Note on "pairing-native schema" (revised):** an earlier design draft carried
always-null `arm`/`pair_id`/`block_id`/`planned_order` columns "for the future
paired engine." That is dropped. Today's v2.0 rows will never be members of a
future same-day pair (v2.1 reruns the *archived* exe), so those columns add
schema surface with no baseline value. What genuinely must be captured now is the
**attempt record** (every run's outcome, including failures — else survivorship
bias silently drops slow/crashing runs), the **workload composition**, a
**board-state hash**, and the **archived harness + build recipe**. The paired
columns are added via a `schema_version` bump when the paired runner is built.

## 1. Architecture & command surface

New, isolated packages; no existing MUSTER code is modified.

```
cmd/musterbench/main.go        flag parsing, orchestration, output
internal/bench/
  fixture.go       temp-git-repo + hardened GIT_CONFIG (copied from test/process,
                   NOT imported — see §1.2; autocrlf guard widened, see §2.4)
  workload.go      ordered-slice deterministic card generator + manifest
  measure.go       cold-verb + full-loop timers, warmup, rep loop
  record.go        JSONL writer (canonical) + benchfmt .txt writer (lossy)
  fingerprint.go   env/Defender capture (batched PowerShell, timeout-bounded)
  archive.go       build/copy exe + materialized workload + build recipe → artifact dir
bench/
  results.jsonl                 canonical, append-only (COMMITTED)
  artifacts/<artifact_sha>/     immutable per-run artifacts (GITIGNORED — see §4.3)
  <session>.bench.txt           benchfmt export (COMMITTED)
  README.md                     operator note: artifacts/ is the irreplaceable asset
docs/bench.md                   generated descriptive table (COMMITTED)
```

### 1.1 Command surface (thin — no stats engine)

```
musterbench                  dry run: print table to stdout, write no PERSISTENT
                             results (still creates temp repos + temp commits, all
                             cleaned up). Default, safe.
musterbench --record         run suite, append JSONL + benchfmt + archive +
                             regen docs/bench.md
musterbench --n 10,100       override scaling set (default 10,100,1000)
musterbench --archive-exe P  benchmark + archive a prebuilt exe (the SAFE default
                             for an official baseline). If omitted, build from the
                             current tree (see dirty-tree policy below).
musterbench --allow-dirty    permit --record from a dirty working tree; stamps
                             vcs_modified=true loudly into build.json and the rows.
```

- All persistent writes gated behind `--record` (writing files from a plain exe
  is otherwise accident-prone).
- "Writes nothing" is imprecise — the default still spawns temp repos and thousands
  of temp commits (in temp dirs, cleaned up). It writes **no persistent benchmark
  results**.
- **Dirty-tree policy:** `go build` compiles the working *tree*, not HEAD. A dirty
  tree poisons baseline provenance (`exe_sha256` matches no commit; buildinfo
  stamps `vcs.modified=true`). So `--record` with a build-from-tree **refuses on a
  dirty tree** unless `--allow-dirty` is given. `--archive-exe` (an explicitly
  built, known-clean exe) is the recommended path for the official baseline.
- Lives under `cmd/`, so `go build ./...` compiles it — accepted. It is never
  linked into `muster.exe` (Go links only imported packages) and `go build` does
  not execute it.

**Not in scope:** no paired A/B runner, no permutation/sign test, no log-ratio, no
benchstat invocation. The recorder only produces complete observations + archives.

### 1.2 Fixture: copy, do not share

The `test/process` fixture (temp-git-repo + GIT_CONFIG pinning) is copied into
`internal/bench`, not imported and not extracted to a shared package.
`test/process` is `//go:build process` test-only and its helpers are coupled to
`testing.T`/`TestMain`; a neutral shared package would need a refactor that buys
little; and **benchmark fixture stability is part of the measurement definition**
— it must resist incidental change that test ergonomics would otherwise impose.

Guard against silent drift: the copied fixture carries an explicit
`fixture_version`, recorded on every row, with an invariants test (§6). The
harness source itself is content-hashed (`harness_sha`) and archived (§4.3), since
the harness is part of what defines a comparable measurement.

## 2. Workload generator & determinism

`Generate(seed, n) -> ([]Batch, Manifest)` — a pure function. Ordered slice, never
a Go map (map iteration would make ingest/insertion order nondeterministic; task
ids derive from filenames so ids themselves are stable, but ingest order and event
sequencing are not — an ordered slice pins both).

### 2.1 Card schema — verified against `internal/card/card.go` + `lint.go`

Unknown frontmatter keys are a **hard Parse error** (card.go:127), so the generator
must emit exactly the required keys and **must not** emit derived ones.

Required vs forbidden per type (card.go:40-46, 206-269; lint.go):
- **All types:** `id`, `plan`, `type`, `tier`, `depends_on` (may be `[]`), `verify`
  (each entry: `cmd` + `expect_exit` and/or `expect_contains`; integer exits).
  Body must be `# <title>` → `## Context` → `## Steps` → `## Acceptance`, in order.
- **impl:** additionally `protected` (may be `[]`) and `commit_paths` (present
  **and non-empty** — lint rule 13, lint.go:191).
- **integration:** `commit_paths` **must be omitted entirely** — even
  `commit_paths: []` is rejected (card.go:250). This resolves the prior open item.
- **DERIVED — never emitted as frontmatter:** `seq` (parsed from the id's `-NN-`
  field, card.go:36,183) — emitting `seq:` fails Parse with "unknown frontmatter
  key". The integration task gets seq 99 by being *named* `…-99-…`.
- **Optional:** `harness` (∈ {claude, codex}) — omitted by the generator.

### 2.2 Topology & batching — verified against `lint.go`

Ingest lints in **Full** mode (ingest.go:46). The workload must pass with zero
findings. Constraints (all verified):
- **Filename/id** `^[a-z0-9-]+-\d{2}-[a-z0-9-]+$`; `id == filename stem`
  (lint.go:20,90,97). Uniqueness rides the **suffix**, so a fixed 2-digit sequence
  (e.g. `01`) with a varying suffix is legal: `bench-01-t000001`, `bench-01-t000002`.
  The 2-digit sequence is **not** a batch-size cap.
- **Rule 11:** exactly one integration task per batch — seq 99, tier strong,
  `depends_on` every other batch id (lint.go:200-227).
- **Rule 6:** ≤300 lines / 16 KB per card, measured on raw text (lint.go:155). The
  integration card lists every sibling in `depends_on`, one line each (card.go:139),
  so the **batch ceiling ≈ 250-280 tasks** — the real cap is card size, not
  sequence space. `BATCH_MAX` is pinned by the §6 size-cap test (target ~250).

**Topology = fan-in per batch**: (batch_size − 1) impl tasks + one seq-99
integration depending on all of them. `batchCount(N) = ceil(N / BATCH_MAX)`.

**Scaling framing (revised).** N=10/100/1000 do **not** isolate board-size — they
covary board size, batch count, and the integration:impl ratio simultaneously. So
the estimand is explicitly **"performance of these prescribed composite
workloads" (a regression tripwire)**, NOT "pure board-size scaling." Each row
records its full composition (`batch_sizes`, `impl_count`, `integration_count`) so
the mix is never ambiguous. A clean constant-batch scaling series (e.g. N=250/500/
1000 with fixed 250-task batches) can be added later if a SQL-scaling question
demands it; it is out of scope for the v2.0 baseline.

### 2.3 Verifier & the task lifecycle

Verify command = `git --version` / `expect_exit: 0`. Git is a hard dependency,
spawned directly without a shell (verify.go:83, tokenized by `SplitCmdLine`), needs
no executor-created input, has no path tokens (passes rule 5, which only runs on
impl/fix anyway), and is already the integration-fixture verifier in `test/process`.

The real single-task cycle (verified against loop_test.go, RUNNER.md, and source):
`materialize cards → ingest → commit cards (external; ingest does NOT commit,
ingest.go:80) → [promote] → claim → write commit_paths file → verify → done`.
- `claim` self-promotes (claim.go:116), so the explicit `promote` step is optional
  (kept for realism; harmless). `claim`/`promote` mutate the **DB only**, never git.
- `verify` logs a SQLite attempt event then spawns the card command. `done` does
  **not** require a prior passing verify — it re-runs the verify block itself as
  "done-check" (done.go:189). So the full loop incurs **two verifier spawns per
  task**.
- Only `init` and `done` create git commits (verified: commit/add call sites are
  exactly initcmd.go + done.go + donefail.go; claim/verify/ingest/promote have
  none). The earlier premise "every board transition commits" was false.

**Integration-task completion is special-cased.** An integration task has no
`commit_paths` (nothing to write) and its `done` requires a verdict plus a notes
file (done.go:166). The full-loop's per-batch tail therefore completes the
integration task via its own path (`done pass` + notes sidecar, tier strong), not
the impl path. Metric name is honest: **"MUSTER lifecycle with minimal external
verifier"**, not "pure board mechanics."

### 2.4 Determinism, manifest, and the autocrlf guard

- Fixed template, only the index substituted, LF line endings. No timestamps/
  UUIDs/clock reads in card bytes. Seed fixed (default 1), recorded.
- Manifest = ordered `[{index, id, sha256(card-bytes)}]` + top-level
  `manifest_sha256` over the concatenation, on every row. **Determinism is not at
  risk from git**: the manifest is hashed over the bytes the harness writes to disk
  *before* git touches them.
- **autocrlf guard (widened — tested on box).** System gitconfig has
  `core.autocrlf=true`; the `test/process` fixture overrides only
  `GIT_CONFIG_GLOBAL`, not `GIT_CONFIG_SYSTEM`, and temp repos do not inherit
  MUSTER's `.gitattributes`. So LF cards would be CRLF-mangled on git operations.
  The fixture must therefore, per temp repo, either write a `.gitattributes`
  (`* -text` / `* text eol=lf`) at init, **and/or** apply `-c core.autocrlf=false`
  on every conversion-touching git call the harness itself makes (add/commit/
  status — the last used for the `git_commit_count` diagnostic). Also set
  `-c safe.directory=*` (as the fixture already does).
- `--record` writes the **materialized card bytes** to the artifact dir (§4.3), not
  merely the hash — a hash proves identity but cannot reconstruct bytes.
- Generator version string recorded so generator drift is detectable.

## 3. Measurement modes, timing, per-cycle breakdown

### 3.1 Cold-verb latency (read-mostly)

Verbs `board`, `show`, `doctor` against a pre-built board (built once, outside
timing). Verified read-only (board.go, doctor.go issue only reads; no commits).
`claim`/`promote` mutate and are excluded here (measured only in the full-loop).

**Board-size is a confound and must be recorded.** `doctor` iterates tasks and
scans card files; `board` materializes and joins task-id collections — latency
scales with board size. So each cold-verb row records the **board size and a
board-state hash**, and the case name encodes the size (`board/n=100`,
`doctor/n=100`, `show/n=100/task=impl-middle`). A single size is a
**single-workload tripwire**, labeled as such — not "general cold-verb latency."
Default captures the same sizes as the scaling set where cheap; `show` targets a
fixed deterministic task (middle impl) so its per-card cost is stable.

30-50 timed runs after 3-5 warmup runs, fresh process each (spawn included).

### 3.2 Full-loop (whole-loop replicate)

Per repetition: build a fresh board **outside** the timer, then
`[start] for each batch { ingest → commit cards → [promote] }; for each task {
claim → write commit_paths file → verify → done }; complete integration per batch
[stop]`.

- The statistical sample is one whole-loop `total_elapsed`. Per-task timings within
  one loop are **dependent** (git history + event chain grow, WAL checkpoints,
  position-dependent cost) and must **not** be pooled as repeated measures — that
  is pseudoreplication. They are kept only as a positional diagnostic trace.
- Headline = **median** across reps; total wall-time primary, tasks/sec beside it
  (with the caveat that integration tasks run a different completion path, so
  tasks/sec is a composite-workload rate, not a uniform unit). Minimum is a labeled
  best-observed diagnostic only, never the headline. p95 is descriptive only where
  reps are cheap and is **omitted** at the largest N (reliable tails need ~100+
  reps).
- Reps tiered by per-rep cost: N=10 → 20-30, N=100 → 10-15, N=1000 → 3-5 (labeled
  **preliminary** — a 3-5-rep median is "a few measurements", not a stable
  estimate). Raw per-rep timings always stored so statistics can be recomputed.

  **Owner-approved deviation (2026-08-16), recorded v2.0 baseline:** the full
  sample overruns the one-time descriptive-baseline budget (~1.5-2h) on this
  spawn-bound box (~1.9s/task; one N=1000 loop ≈ 30 min, and N=1000 dominates
  wall-time). Actual counts recorded: N=10 → 2 warmup + 25 timed, N=100 → 0 warmup
  + 9 timed, N=1000 → 0 warmup + 3 timed. Full-loop warmups are dropped at N≥100
  because a large-N warmup buys ~nothing on a no-JIT fresh-process-per-verb
  workload (the exe+git are already page-cached by the N=10 phase) while costing
  ~30 min at N=1000. Timed counts are kept odd so the RenderTable median is a true
  middle observation rather than the upper-of-two an even count yields. Rationale
  lives beside the code at `internal/bench/suite.go` (`repCounts`).

### 3.3 Per-cycle child-invocation breakdown (diagnostics)

Each timed rep also records, as diagnostics (not headline): sum of `muster.exe`
child wall-times, the two verifier spawns per task, git-commit count, and
executor file-write time. Do **not** subtract the file-write from the headline —
its existence also changes later `git status`, staging, hashing, Defender
scanning, and commit cost.

### 3.4 Timer boundaries & warmup

Outside timer: board construction, card materialization, git-config setup. Inside
timer: everything an agent triggers (ingest → … → done, including the
contract-forced file-write). Timing uses Go monotonic `time.Now()` deltas around
`cmd.Start()`/`cmd.Wait()` — the only valid source of a spawned process's
parent-observed wall time (verified: `ProcessState` exposes CPU time only, not
wall). `time.Time` values are `Sub`-tracted in-process, never marshaled first
(marshaling strips the monotonic reading). Warmup: 3-5 for cold-verb; 1-2 whole
loops for N=100/1000. Warmup rows carry `warmup:true` + reason — never silently
dropped.

## 4. Data schema, benchfmt export, immutable artifacts

### 4.1 Canonical record — `bench/results.jsonl`

Append-only, one JSON object per **attempt** (not just per success — a failed or
timed-out run still writes a row, so slow/crashing runs cannot vanish into
survivorship bias):

```jsonc
{
  "schema_version": 2,
  "run_id": "<stable hash over (experiment_id, measurement, verb, n, seed,
              generator_version, rep_ordinal, warmup) — no clock/random>",
  "experiment_id": "v2.0-baseline",
  "session_id": "<per-invocation id>",
  "actual_order_index": 0,          // execution order within the session
  // --- attempt outcome (always present) ---
  "attempt_status": "ok",           // "ok" | "error" | "timeout" | "crash" | "cancelled"
  "exit_code": 0,
  "error_detail": null,
  "warmup": false,
  "excluded": false,
  "exclude_reason": null,
  "warmup_reason": null,            // distinct from exclude_reason
  // --- measurement stratum ---
  "measurement": "full_loop",       // | "cold_verb"
  "verb": null,                     // cold_verb only
  "n": 100,
  "rep_ordinal": 3,
  // --- workload identity + composition ---
  "seed": 1,
  "generator_version": "1",
  "topology": "fanin",
  "workload_manifest_sha256": "...",
  "batch_sizes": [100],             // full composition, not just a count
  "batch_count": 1,
  "impl_count": 99,
  "integration_count": 1,
  "board_state_sha256": "...",      // board state at timer start (cold_verb + loop)
  // --- timing (monotonic ns) ---
  "wall_ns": 1234567890,            // whole-loop total, or verb latency
  "per_task_ns_trace": [ ],         // positional diagnostic — DEPENDENT, not samples
  "child_muster_ns_sum": 0,
  "verifier_spawns": 2,             // per task (verify + done-check)
  "git_commit_count": 0,
  "executor_write_ns": 0,
  "started_utc": "…Z",              // provenance only, NOT used for timing
  "ended_utc": "…Z",
  // --- provenance / measurement apparatus ---
  "exe_sha256": "...",
  "exe_buildinfo": { "go_version": "<actual, read from binary>",
                     "vcs_revision": "...", "vcs_modified": false },
  "build_recipe_sha256": "...",     // hash of build command + flags + toolchain
  "harness_version": "1",
  "harness_sha256": "...",          // harness source content hash
  "fixture_version": "1",
  "artifact_sha": "<content-addressed dir under bench/artifacts/>",
  "env": { }                        // §5
}
```

Rules: an attempt row is written even on failure; `warmup`/`excluded` carry their
own reasons; `per_task_ns_trace` is explicitly dependent/diagnostic; timing is
monotonic `wall_ns`, `started_utc` is provenance only. The speculative paired
columns (`arm`/`pair_id`/`block_id`/`planned_order`) are intentionally absent and
added at `schema_version` 3 when the paired runner exists.

### 4.2 Lossy benchfmt export — `bench/<session>.bench.txt`

Go benchmark format (design 14313) for later `benchstat` convenience only:

```
goos: windows
goarch: amd64
pkg: muster-bench
BenchmarkFullLoop/n=100 1 1234567890 ns/op
```

- **Only stable comparison dimensions** in the benchmark name (`FullLoop/n=100`).
  Binary SHA, timestamps, per-rep fingerprint stay out — they would fragment
  benchstat grouping into singletons.
- One line per successful rep, `iters=1`, `ns/op` = the whole loop (labeled
  elsewhere as **not** per-task). Failed attempts are omitted from the benchfmt
  export (they live in the JSONL).
- benchstat is a **descriptive convenience**, NOT the authoritative verdict: its
  Mann-Whitney U is unpaired and discards matched-block structure; within-block
  correlation can make its p-value invalid, not merely conservative. When the
  paired runner is built, the export becomes arm-separable (separate old/new files
  or a config dimension); the authoritative test is within-block paired ratios,
  deferred to v2.1.

### 4.3 Immutable content-addressed artifacts — `bench/artifacts/<artifact_sha>/`

```
bench/artifacts/<sha>/
  muster.exe        the archived v2.0 binary
  workload/         materialized card bytes (not just the hash)
  invocation.json   exact flags, N set, seed, HEAD sha
  build.json        build command + flags + full toolchain (go version, GOOS/ARCH,
                    env) + vcs_modified — the reproducible build contract
  harness/          harness source snapshot (or a harness_sha manifest)
```

- `<artifact_sha>` = hash over (exe bytes + workload bytes + build recipe +
  invocation params). JSONL rows reference it. **Immutable**: a later `--record`
  writes a *new* sha-dir; it can never mutate artifacts backing earlier rows.
- **Real bytes archived, not hashes** — a manifest SHA only proves a future
  reconstruction is *wrong*; it cannot rebuild it.
- **Build provenance robustness** (tested): build with `cmd.Dir` = the real repo
  root (never a copy), pass `-buildvcs=true`, and **assert `vcs.revision` is
  present** in the built exe's buildinfo — else `go build`'s VCS stamping silently
  omits and provenance collapses to go_version. `go_version` is read from the
  binary, never hard-coded.
- **Git hygiene (decision):** `bench/artifacts/` is **gitignored** — a 10-20 MB
  binary per baseline would bloat history permanently, against the grain of the
  repo already ignoring the root `muster.exe`. Git tracks only `results.jsonl`,
  the benchfmt export, `build.json`/manifest metadata, and `bench/README.md`. That
  README states plainly: **`bench/artifacts/` holds the irreplaceable perishable
  assets — the operator must preserve/back it up out-of-band.** (git-lfs is the
  alternative if in-repo storage is later preferred.)

### 4.4 Build-toolchain treatment (the biggest longevity risk)

Same-day AB/BA removes machine drift but **not** compiler/runtime drift baked into
the two binaries: the archived exe is frozen with today's Go toolchain + flags,
while a future candidate built fresh may use a newer toolchain. The v2.0 treatment
is defined now as **"MUSTER source changes, holding toolchain constant"**: when
v2.1 is compared, both the archived-v2.0 and the candidate should be built with
the **same pinned toolchain + flags** (the archived exe is retained as recovery
evidence, and its `build.json` records exactly how it was produced so the pin is
enforceable). If a future comparison instead wants "whole release artifact"
semantics, that must be stated explicitly as a different estimand. `build.json`
carries the exact command, flags, and toolchain to make either choice auditable.

### 4.5 `docs/bench.md`

Generated descriptive table: version, date, box tag, defender state, N, median
wall, range, tasks/sec. Explicitly labeled **descriptive; cross-time rows are not
a regression verdict — that requires a same-day paired run.**

## 5. Environment fingerprint

Capture is **descriptive** provenance, not causal explanation. Tier-1 gates
"baseline recorded"; everything else is best-effort → `"unknown"`, never blocking.

**Tier 1 — must-have** (cheap):
- `os` (`runtime.GOOS/GOARCH`, Windows build), `cpu` (model, physical+logical
  cores), `ram_total_bytes`
- `go_version` (from the binary), `git_version`
- `defender_realtime`: tri-state true / false / **"unknown"** (query failure →
  "unknown", never "false")
- `defender_exclusions_cover_benchdir`: true / false / "unknown"
- `bench_temp_dir_volume`, `box_tag` (`<short-cpu>-<hostname>`; comparisons valid
  only within one tag)

**Cheap per-rep pair-invalidators** (recorded per session, re-checked if cheap):
Defender-state change, AC/battery transition, reboot/session identity, free-space
threshold. These are the facts that can actually invalidate a future pair.

**Cut from scope (was Tier 2 — over-engineered):** BitLocker, NTFS compression,
write-cache policy, CPU-frequency policy, Controlled Folder Access, per-process
Defender-exclusion detail, and disk **MediaType** (tested: returns `"Unspecified"`
on this virtualized box regardless of effort). These add substantial
Windows/PowerShell surface without making cross-time rows causal; deferred until
evidence shows a recurring unexplained effect.

**Mechanics (tested):** all probes batched into **one**
`powershell.exe -NoProfile -NonInteractive` call (pay ~200-800 ms interpreter
startup once, not per probe), wrapped in `exec.CommandContext` with a ~5-10 s
timeout (WMI/CIM can hang indefinitely; `Get-MpComputerStatus` may need
elevation → `"unknown"` on access-denied). A failed probe writes `"unknown"` plus
the probe error, never aborts, never fabricates. No fingerprint code exists in
MUSTER today — all built here.

## 6. Testing the harness

Fast unit tests (plain `go test`, sub-second, no build tag) plus one gated smoke.
Tests assert structure, determinism, validity, fault-tolerance — never absolute
timing (inherently noisy; that is the premise).

1. **Determinism**: `Generate(1,100)` byte-identical across two calls; a golden
   `manifest_sha256` constant catches accidental generator changes.
2. **Lint-validity**: generated cards pass the real `card.Lint(…, Full)` with zero
   findings — invoked **once per ingest batch** (a single `Lint(Full)` over
   multiple batches trips rule 11: ≥2 integration tasks). Cases: N=10 (one batch),
   N=BATCH_MAX and N=BATCH_MAX+1 (boundary), N=1000 (multi-batch, per-batch lint).
   `Lint` reads files from disk, so the test materializes cards to a temp dir and
   passes paths; `exists` is stubbed `func(string) bool { return false }`.
3. **Parse-validity**: generated cards pass `card.Parse` with no unknown-key
   errors — specifically asserts the generator emits no `seq` key and no
   `commit_paths` on integration tasks.
4. **Batching math**: `batchCount(N)` respects the size cap; the largest
   integration card stays under 300 lines / 16 KB (pins `BATCH_MAX`).
5. **Schema**: a JSONL row round-trips; `attempt_status` present on every row;
   `excluded`/`warmup` always paired with their reason.
6. **Fingerprint fault-tolerance**: a stubbed failing probe yields `"unknown"` +
   error, never panics, never fabricates.
7. **autocrlf**: a card written + committed in a temp repo round-trips
   byte-identically (guards the `GIT_CONFIG_SYSTEM=autocrlf` trap).
8. **benchfmt export** parses back; only stable dims in names.

**Gated smoke** (`//go:build benchsmoke` or `-short`-skipped): one real N=3
full-loop against a freshly built exe in a temp repo — proves the whole pipeline
(ingest→commit→promote→claim→verify→done, incl. integration completion) runs end
to end on this box. Opt-in.

## 7. Open items deferred to implementation / v2.1

- Exact `BATCH_MAX` value (pinned by the §6 size-cap test).
- The integration task's `done pass` notes-sidecar exact shape (done.go:166) —
  confirm the minimal valid notes file at implementation.
- The paired-A/B comparison engine (archived-v2.0 vs candidate, matched AB/BA with
  order randomization, within-block paired log-ratio + CI + threshold, paired
  permutation / sign test), built with pinned toolchain per §4.4 and validated via
  a v2.0-vs-identical-v2.0 negative control. Adds `schema_version` 3 paired columns.
- Recording the actual v2.0 baseline is a **run of the finished recorder**, not
  part of building it.

## 8. Non-goals

- Not a CI gate (Windows timing is too noisy to fail builds).
- Not a v1-vs-v2 comparison (v1 is retired).
- No absolute-latency SLAs or thresholds in this phase.
- Not pure board-size scaling (the N series is composite workloads — §2.2).
- Does not modify any existing MUSTER code.
