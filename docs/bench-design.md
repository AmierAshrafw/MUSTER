# MUSTER v2 benchmark - design notes

Status: shipped as `musterbench` (`cmd/musterbench`). These are the original
design notes; the built recorder is specified in the
[bench recorder design](superpowers/specs/2026-08-16-muster-bench-recorder-design.md),
run via `musterbench` (see [bench/README.md](../bench/README.md) and the generated
[bench.md](bench.md)).

## Purpose

Regression baseline for the v2 binary, tracked across future versions (v2.1,
v2.2, ...). NOT a v1 comparison - v1 is being retired and a one-shot shootout
has no ongoing value. First baseline row = v2.0; every later version appends a
row against the identical workload.

## What to measure (board mechanics only - agent time excluded)

- Cold verb latency, process spawn included (what agents feel):
  `muster board`, `show`, `claim`, `promote`, `doctor` against a synthetic
  board.
- Full loop: ingest N cards, then claim-verify-done x N in a temp git repo -
  wall time per task. The number that matters for `/muster:auto`.
- Scaling: same metrics at N=10, N=100, N=1000 tasks - catches SQL
  regressions (missing index, table scan) that small boards hide.
- Optional isolate: done-commit latency alone (git + Defender bound; noisy
  but the dominant term of the loop).

## Methodology

- Go harness in-repo, reusing the process-tier fixture machinery
  (temp git repos, real muster.exe) so the environment is controlled.
- Fixed seeded synthetic-board generator - workload must be byte-identical
  across versions or comparisons are meaningless.
- Warmup runs, then median of ~10; report median + p95, never mean.
- Dashboard, not a gate: no CI thresholds - Windows timing is too noisy to
  fail builds on.

## Environment fingerprint (auto-captured per run, never hand-typed)

- CPU model, physical/logical cores
- RAM total
- Disk type behind the bench temp dir (NVMe/SSD/HDD) - SQLite
  synchronous=FULL and git are fsync-bound
- OS version/build
- Windows Defender exclusion active for the bench dir: yes/no - single
  biggest swing factor; a first-class column, not a footnote
- Go version that built the binary + muster commit SHA/version
- Power plan / AC vs battery when on a laptop
- Box tag: stable short name derived from CPU + hostname (e.g.
  `win2025-xeon-nvme`) - comparisons are only ever valid within one tag

## Result format

- Harness appends one JSON object per run ({env, results}) to a committed
  JSONL file (e.g. `bench/results.jsonl`) - full fidelity.
- `docs/bench.md` table generated from the JSONL: version, date, box tag,
  defender on/off, per-metric medians. Human-readable summary only.

## Known limits

- Same-box validity only. OS/Defender updates shift baselines; when in doubt,
  re-run the old tagged version side by side with the new one on the same day
  (checkout tag, build, run both).
- Cross-box rows are never compared.

## When to build

Any time - the harness uses temp repos and does not touch this repo's board.
Natural slot: alongside the first v2.x hardening plan, with the v2.0 baseline
row recorded before those changes land.
