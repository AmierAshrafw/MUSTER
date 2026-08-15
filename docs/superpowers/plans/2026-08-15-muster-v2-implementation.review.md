# Review sidecar: 2026-08-15-muster-v2-implementation.md

**Mode deviation (owner-directed):** the owner instructed a surface review only -
no subagent dispatch, no builds, no test runs. The standard opus `plan-reviewer`
subagent was NOT dispatched. Findings below come from the main thread's inline
read-only pass (plan text + spec + v1 sources + tests/ContractMatrix.psd1).
Standalone deeper review available later by invoking `plan-reviewer` outside the
flow.

## Findings applied during authoring (self-review, already in the plan)

- [A1] Lint/ingest test fixtures used verify cmd `go test internal/w` with the
  `internal/w` token unlisted - would fail the plan's own check 5. Fixed: bare
  dir entry added to `commit_paths` in every fixture; doubles as documentation
  of the sharding-notes convention. ACCEPT (applied).
- [A2] `TestProseChecks` correlated a Go map's random iteration order with an
  indexed slice - nondeterministic failure. Fixed: struct-slice cases. ACCEPT
  (applied).
- [A3] Claim-probe auto-file printed the full done block including
  `Session over.` mid-claim - `Session over.` is the RUNNER's only stop signal
  and the session is not over. Fixed: `completePass` suppresses the board line
  and done message when `o.Probe`. ACCEPT (applied).
- [A4] First draft of `Store.migrate` double-ran migrations on a fresh file.
  Fixed: single-loop version; fresh-file case rides on migration 1 creating
  `schema_version` at 0. ACCEPT (applied).
- [A5] `gitx.Fake.AmendNoEdit` left simulated hook dirt in place forever - the
  hook re-stage cycle test could never terminate. Fixed: amend clears `Dirty`
  (mirrors real amend folding staged changes). ACCEPT (applied).
- [A6] Dead store APIs (`Store.Path()`, `Store.AddDep`) had no callers. Cut.
  ACCEPT (applied).

## Residual findings (surface pass, this review)

### Blockers

(none)

### Warnings

- [W1] Task 3 - modernc.org/sqlite DSN `_pragma=...` syntax and the asserted
  pragma echo values (`wal`, `2`) are driver-behavior assumptions not verifiable
  without running. DEFER - Task 3 is test-first, so a wrong assumption fails
  loudly inside that task; the executor fixes it in place. No plan change.
- [W2] Task 6 - `BEGIN IMMEDIATE` issued via `db.Exec` relies on
  `SetMaxOpenConns(1)` pinning every statement to one connection. The assumption
  is documented in the code comment and the Task 6 race test proves or breaks it
  deterministically. DEFER to execution - the riskiest-first ordering exists for
  exactly this.
- [W3] Task 8 - on timeout, `exec.CommandContext` + `CombinedOutput` may return
  no partial output, so a timed-out entry's transcript can lack command output.
  DISMISS as blocker (the `timeout Ns -> FAIL` line is the contract, matching
  v1's behavior where a killed process contributed no output); noted for the
  executor.
- [W4] Task 26 - `go tool bogus-no-such-tool` (verifyRedCard) assumed to exit
  nonzero without network. DEFER - if a Go version changes this, the red-card
  fixture swaps to any other deterministic nonzero command inside the task.

### Suggestions

- [S1] Sharding notes check 5 workaround (bare-dir `commit_paths` entries for
  Go package tokens) was verified against v1 `Test-PathListed`
  (tasks/bin/_lib.ps1:687-693: exact-match arm accepts a no-trailing-slash
  entry). Confirmed correct by reading; no change.
- [S2] Duplicate-symbol scan across tasks: `probe`, `doneFailReview`,
  `doneFailIntegration`, `Init` each appear as stub + real implementation; every
  pair carries an explicit replace/delete instruction (plan lines 5520, 6179,
  6206/6277, 7020/7200). Confirmed complete; no change.
- [S3] All 12 CLI verbs have Dispatch cases across Tasks 11-21 (verified by
  scan); `init` routes via main. No change.

## Verdict summary

6 self-review findings ACCEPTED and applied during authoring; 4 warnings
DEFERRED to execution (all inside test-first tasks that fail loudly), 1
dismissed as blocker with rationale; 3 suggestions confirmed-by-reading, no
plan edits required.
