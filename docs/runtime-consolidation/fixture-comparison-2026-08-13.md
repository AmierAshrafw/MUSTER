# Phase 2 fixture-strategy comparison

Machine: DAMAI-NEW, Windows PowerShell 5.1.26100.32684. No NGen or machine tuning.
Measured 2026-08-13 with tests/bench/Measure-Fixture.ps1, BEFORE any New-MusterFixture change (the init rows are the current per-test git-init path).
Config: 2 independent passes x 20 create+destroy cycles per strategy.
One-time template build (New-MusterFixture): 0.833 s - under a template-based strategy this is paid once per Pester test file (each file dot-sources its own MusterFixture.ps1 scope), i.e. ~12x per full suite run.
Every strategy was checked against Assert-FixtureContract (tests/bench/FixtureStrategies.ps1); failures disqualify from adoption but are still timed below.

## Create+destroy timings (seconds)

| Strategy | Pass | p50 | p95 | All samples |
|---|---:|---:|---:|---|
| init | 1 | 0.915 | 0.958 | 0.941, 0.918, 0.915, 0.935, 0.89, 0.97, 0.899, 0.926, 0.958, 0.904, 0.937, 0.892, 0.873, 0.888, 0.865, 0.923, 0.917, 0.95, 0.89, 0.893 |
| init | 2 | 0.908 | 0.959 | 0.931, 0.899, 0.956, 0.915, 0.898, 0.908, 0.903, 0.887, 0.926, 0.92, 0.938, 0.889, 0.896, 0.959, 0.966, 0.934, 0.891, 0.878, 0.931, 0.884 |
| copy | 1 | 0.344 | 0.371 | 0.37, 0.34, 0.34, 0.373, 0.342, 0.358, 0.35, 0.371, 0.344, 0.346, 0.337, 0.337, 0.332, 0.335, 0.334, 0.348, 0.345, 0.35, 0.34, 0.361 |
| copy | 2 | 0.356 | 0.386 | 0.317, 0.33, 0.352, 0.363, 0.347, 0.365, 0.356, 0.386, 0.358, 0.348, 0.359, 0.366, 0.355, 0.364, 0.358, 0.32, 0.45, 0.334, 0.384, 0.334 |
| clone-local | 1 | 0.851 | 0.889 | 0.814, 0.883, 0.852, 0.839, 0.861, 0.824, 0.849, 0.851, 0.889, 0.82, 0.855, 0.847, 0.902, 0.875, 0.845, 0.858, 0.869, 0.836, 0.869, 0.812 |
| clone-local | 2 | 0.856 | 0.891 | 0.846, 0.891, 0.878, 0.882, 0.875, 0.862, 0.83, 0.863, 0.816, 0.842, 0.869, 0.856, 0.919, 0.84, 0.84, 0.85, 0.878, 0.868, 0.856, 0.827 |
| worktree | 1 | 0.409 | 0.425 | 0.405, 0.401, 0.425, 0.413, 0.416, 0.402, 0.388, 0.404, 0.39, 0.417, 0.42, 0.425, 0.411, 0.41, 0.44, 0.379, 0.403, 0.386, 0.409, 0.421 |
| worktree | 2 | 0.407 | 0.427 | 0.425, 0.403, 0.394, 0.378, 0.415, 0.384, 0.403, 0.437, 0.41, 0.396, 0.407, 0.416, 0.409, 0.388, 0.404, 0.407, 0.426, 0.427, 0.421, 0.392 |

## Verdicts (rule fixed before measurement)

Material = contract passed AND both passes p50 <= 0.7x the best init pass p50 (0.908 s). Ties go to the simpler strategy: copy > clone-local > worktree.

- **copy:** MATERIAL - worst-pass p50 0.356 s = 0.39x of init best p50 0.908 s (<= 0.70 required).
- **clone-local:** not material - worst-pass p50 0.856 s = 0.94x of init best p50 0.908 s (<= 0.70 required).
- **worktree:** DISQUALIFIED (contract: contract: C:\Users\Administrator\AppData\Local\Temp\muster-fix-ecf17707 does not own its git dir (C:\Users\Administrator\AppData\Local\Temp\muster-fix-ecf17707\.git is not a directory)). Timed for the record: worst-pass p50 0.409 s (0.45x init best).

