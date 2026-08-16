# bench/

Committed: `results.jsonl` (canonical attempt records), `*.bench.txt` (benchfmt
export), generated `../docs/bench.md`.

**NOT committed (gitignored): `artifacts/`.** This holds the irreplaceable,
perishable v2.0 assets — the archived `muster.exe`, the materialized byte-identical
workload, and the build recipe. **The operator must preserve / back up
`bench/artifacts/` out-of-band.** A hash in the JSONL proves identity but cannot
reconstruct these bytes. Baselines are rare; keeping the binaries out of git
history avoids permanent repo bloat (the repo already ignores the root muster.exe).
