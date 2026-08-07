# Plan review sidecar: 2026-08-07-muster-v1-implementation

Reviewer: plan-reviewer subagent (opus, fresh context), 2026-08-07.
Findings: 5 blockers, 8 warnings, 3 suggestions. All 16 ACCEPTED and applied inline.
The reviewer behaviorally verified git/PowerShell claims in throwaway repos on this
box before flagging (porcelain collapse, diff-vs-untracked, $Matches scoping,
StrictMode index access) - findings below marked (verified) rest on that.

## Blockers

- [B1] ACCEPT - fixture defaults `Id='demo-01-sample'`, `Plan='demo'` while 7 commit
  assertions across Tasks 8/10/11/12/14/15 expect `muster(p): ...`. Fix applied:
  defaults changed to `Id='p-01-a'`, `Plan='p'`.
- [B2] ACCEPT (verified) - `git status --porcelain` collapses untracked dirs
  (`?? src/`), so the claim scope check refused the exact D12 recovery case it must
  tolerate. Fix applied: `--untracked-files=all` in `Get-DirtyPaths`.
- [B3] ACCEPT (verified) - `git diff --name-only <commit>` omits untracked files, so
  the done scope check (D21 chimera guard) was a no-op for new files and
  `files_changed` came out empty. Fix applied: `Get-ChangedPaths` helper
  (diff union `ls-files --others --exclude-standard`), used by
  `Test-DonePreconditions` and `New-ResultSidecar`.
- [B4] ACCEPT - promote warnings on the output stream polluted the moved-ids return
  value; `Complete-Task` would have built pathspecs from warn text. Fix applied:
  warnings via `Write-Host` (still visible on child stdout for the contract test),
  return value clean.
- [B5] ACCEPT - spec self-contradiction: section 7 templates use inline flow lists
  (`depends_on: [{dep-ids}]`) that spec 2.5's parser subset forbids. Pinned: 2.5 wins;
  templates rewritten to block-list form (Task 16 Step 2b), shard fill rule updated,
  recorded as Authority deviation 3.

## Warnings

- [W1] ACCEPT - result sidecar `verify:` line lied in two flows (done-without-verify
  claimed `claim-probe`; done-fail read the log after moving it). Fix applied:
  `-Attempts` param captured before the move, `-Probe` switch for the auto-file case,
  honest `done-check only` string otherwise.
- [W2] ACCEPT - promote left `.gen*` history sidecars behind in backlog/, orphaning
  them against spec 3 "move with the task". Fix applied: `Move-TaskSidecars`
  relocated to Task 7 and called from `Invoke-Promote`; `Complete-Task` folds
  promoted-task sidecar paths into the completion pathspec.
- [W3] ACCEPT - lint check-10/13 tests asserted only exit 1, which check 11 already
  forces. Fix applied: check-specific substring assertions.
- [W4] ACCEPT - `/muster:run` namespace assumed, never verified; official
  example-plugin docs show bare command names. Fix applied: Task 19 gains a
  slash-command registration verification step with a stop-and-flag contingency.
- [W5] ACCEPT - nonexistent commit_paths entries aborted the completion commit and no
  git exit was checked. Fix applied: existing-paths-only pathspec + `$LASTEXITCODE`
  check with loud refusal after the completion commit.
- [W6] ACCEPT - brace placeholder pattern missed multi-word slots (`{...}`,
  `{inlined plan snapshot summary: ...}`). Fix applied: added `\{\.\.\.\}` and
  `\{[a-z][a-z0-9 ,:.-]*\}` with the false-positive tradeoff documented.
- [W7] ACCEPT - `Split-CmdLine` throw crashed lint on unbalanced quotes instead of
  emitting a finding. Fix applied: try/catch emitting
  `verify cmd unparseable (unbalanced quote)`.
- [W8] ACCEPT - `Process.Start` cannot launch extension-less `.cmd`/`.bat` shims
  (npm, yarn, ng); a `spawn failed` is indistinguishable from a test failure. Fix
  applied: shard skill verify guidance pins `cmd /c npm test` fronting.

## Suggestions

- [S1] ACCEPT - hardcoded sh.exe path in the test harness. Fix applied: resolve via
  `Get-Command sh` fallback with a clear error.
- [S2] ACCEPT - claim validates before pin-filtering (spec orders select-then-
  validate). Deliberate: unparseable files cannot be pin-filtered. Recorded as
  Authority deviation 4.
- [S3] ACCEPT - full-mode lint collision self-exemption (spec describes it for
  lint-lite only). Required because shard lints the batch after writing it to
  backlog/. Recorded as Authority deviation 5.
