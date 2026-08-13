# Phase 1 prototype comparison

Machine: DAMAI-NEW, Windows PowerShell 5.1. No NGen or machine tuning applied.
Measured 2026-08-13 with `tests/fast/InProcHarness.ps1` (in-process, fresh runspace per
call, 20-iteration average after a JIT warm-up) versus the child-process tier
(`Invoke-Muster` / `Invoke-MusterLint`, 5-iteration average). Lint target is the 3-file
good batch (impl + review + integration) - a lone impl file fails lint check 11, so a
failing batch would not compare like with like.

## In-process vs child-process (seconds per call)

| Verb   | In-process (runspace) | Child process (powershell.exe -File) | Speedup |
|--------|----------------------:|-------------------------------------:|--------:|
| status |                 0.225 |                                0.900 |   4.0x  |
| lint   |                 0.184 |                                0.961 |   5.2x  |

**Speedup factor: 4.0x (status) / 5.2x (lint); ~4.6x mean.** In-process is unambiguously
faster on both verbs. The ratio is below the ~5x+ the review probe anticipated because
this box spawns `powershell.exe` far cheaper than the reference machine (child spawn p50
~0.29 s and a full child `status` verb ~0.66 s here, per `baseline-2026-08-13.md`, vs the
~1.8 s the probe assumed) - the in-process floor is similar, so the smaller child overhead
compresses the ratio. Absolute in-process cost is ~0.2 s per call either way.

## Known in-process limitation (feeds the Phase 4 contract matrix)

The runspace harness has a native-stderr divergence from the child-process tier (see the
header comment in `tests/fast/InProcHarness.ps1`): under the library's
`$ErrorActionPreference='Stop'`, a FAILING native command's stderr becomes a terminating
`NativeCommandError` inside a hosted runspace. So a refusal that follows a failing git
call - e.g. `Get-RepoRoot` outside a git repository - surfaces as `Invoke()` throwing
rather than as a refusal `CommandResult`. A `powershell.exe -File` child does not behave
this way. Such cases must be routed to the retained process tier; this constraint is an
input to the Phase 4 contract matrix that decides which verbs can run in-process.
