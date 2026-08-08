# Plan review sidecar: 2026-08-08-board-visibility.md

Reviewer: plan-reviewer subagent (opus, fresh context), 2026-08-08.
Findings: 11 (1 blocker, 6 warnings, 4 suggestions). Verdicts: 11 ACCEPT, 0 DISMISS, 0 DEFER.

## Blockers

- [B1] Done test committed `p-02-b` after `Add-ClaimedImpl`, tripping the D27 scope
  guard (`_lib.ps1:602` rejects all `tasks/*` paths; hazard documented at
  `tests/Done.Tests.ps1:85-87`) — `done` would refuse, exit 1, test dead on arrival.
  **ACCEPT** — reordered: `p-02-b` committed before `Add-ClaimedImpl`; board math
  unchanged. Warning note added to Task 4 Step 5.

## Warnings

- [W1] sh dead-scan replacement described by its terminators; following literally
  orphans the outer `fi` (`_lib.sh:733-745`) — syntax error.
  **ACCEPT** — full 732-745 span now quoted verbatim as the replace target.
- [W2] Engine divergence on `invalid`: ps1 `Read-Frontmatter` rejects more defect
  classes than sh `fm_valid` (marker check, `_lib.sh:157`); half-broken files can
  bucket differently per engine, untested.
  **ACCEPT (document, not align)** — parity scoped to schema-valid boards (the only
  boards shard-lint lets exist); asymmetry pinned in plan "Pinned output formats",
  spec 8.3 amendment text, and the design doc's Testing bullet. Aligning parsers
  is cost >> benefit for a count display; recorded as out of scope.
- [W3] New `dead_scan` used `_ds_` prefix owned by `dep_satisfied` (`_lib.sh:192`),
  breaking the one-prefix-per-function invariant (`_lib.sh:146-147`).
  **ACCEPT** — renamed to `_dsc_`.
- [W4] `powershell -NoProfile -Command "$env:MUSTER_ENGINE='sh'; ..."` — parent
  shell expands `$env:` inside double quotes; command arrives mangled.
  **ACCEPT** — all test-run steps rewritten as plain PowerShell-session cmdlet
  lines with `Remove-Item Env:\MUSTER_ENGINE` cleanup; conventions note explains why.
- [W5] `status.sh` outside a git repo would print `MUSTER: board empty` and exit 0
  (`repo_root` is a bare `git rev-parse`, `_lib.sh:4`) — misleading for the one
  script marketed for bare-terminal use; ps1 side already refuses.
  **ACCEPT** — `root=$(repo_root) || refuse 'not inside a git repository.'` guard
  added to `status.sh`; rationale note in Task 3. No automated test (fixture
  harness always runs inside a repo).
- [W6] Plan lacked `## Out of scope` / `## Not yet specified` sections.
  **ACCEPT** — both added, seeded from the design spec's "Deliberately excluded"
  list and the harness-split deferral.

## Suggestions

- [S1] Spec 8.3 heading says "claim step 3" but the status print is claim step 2
  (spec 4.1 step 2; `claim.ps1:16`).
  **ACCEPT** — heading correction folded into Task 5 Step 4.
- [S2] Block-list `tier:` would make ps1 `switch` iterate the array and
  double-count, breaking `run + review + invalid == total`.
  **ACCEPT** — non-string tier now counts `invalid` before the switch, with comment.
- [S3] sh replacement snippet duplicated the `_sb_ndead=` line vs. its own
  "unchanged from here" note.
  **ACCEPT** — replacement now ends at `dead_scan` call; note names the exact first
  unchanged line.
- [S4] `Describe 'bin/done'` reference wrong; actual block is
  `Describe 'bin/done - preconditions and pass path'` (`tests/Done.Tests.ps1:3`).
  **ACCEPT** — reference corrected; helper existence confirmed by reviewer.
