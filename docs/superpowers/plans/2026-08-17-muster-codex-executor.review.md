# Plan review - codex-executor mode

Reviewer: plan-reviewer subagent (opus, fresh context), 2026-08-17.
Plan: `2026-08-17-muster-codex-executor.md`. All findings verified against source.

| # | Sev | Finding | Verdict | Action |
|---|-----|---------|---------|--------|
| B1 | Blocker | Task 1 test INSERT omits `card_path`/`frontmatter_sha` (TEXT NOT NULL, no default - schema.go:14-15); setup fails before assertions | ACCEPT | Added both columns to `fpBoard` INSERT + a mirror-the-working-seed note; switched to real helper `open(t)` |
| W1 | Warning | Assumed test helpers wrong: store `openTestStore`→`open(t)`; cli `newTestApp`(2 rets)→`newApp(t)`(3 rets, incl `*gitx.Fake`); `seedTask(id,status)`→`seed(t,a,id,typ,tier,status,...)` | ACCEPT | Pinned real names/signatures in Task 1 + Task 2 |
| W2 | Warning | In-repo `GOCACHE`/`GOTMPDIR` (`.muster-codex-cache/`) = untracked files → `muster done` refuses via out-of-commit_paths check (done.go:51-59); breaks the happy-path triad | ACCEPT (via S2) | Moved caches to system temp dir (`%TEMP%`, in sandbox allow-list, outside tree) - eliminates the dirty-tree coupling. Updated plan Task 3/4/5 + spec section 7 |
| S1 | Suggestion | Routing key truncated; real refusal is `nothing to claim for codex/any.` (claim.go:143, asserted bench/measure.go:154) | ACCEPT | Full `codex/any.` form in plan Task 4 + spec 5.2 |
| S2 | Suggestion | Point caches at `$TMPDIR` (allow-list) to sidestep W2 entirely | ACCEPT | Adopted as the W2 fix (system temp dir) |
| S3 | Suggestion | Fingerprint checked once, not per verify-retry; a tamper during a retry escapes the equality check (real-env verify/done still guard) | ACCEPT | Re-fingerprint before each verify in the triad loop (plan Task 4 step 3) |

Confirmed sound (no change): Fingerprint SQL columns all exist (schema.go:6-49); Dispatch insertion point correct (app.go:66-68); fingerprint ordering correct (FP_CLAIM after claim writes DB, before verify's attempt-event write, verify.go:68); `done` operates on the sole `doing` row (occupant, done.go:15-32); verify attempt cap `>=3` (verify.go:60).

Residual carried to Task 5 / needs-testing: confirm a temp-dir `GOCACHE` builds inside the sandbox (micro-probe validated an in-repo path; `%TEMP%` is allow-listed but unconfirmed).
