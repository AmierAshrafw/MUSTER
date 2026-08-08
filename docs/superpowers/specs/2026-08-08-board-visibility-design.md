# Board Visibility Design

**Date:** 2026-08-08
**Status:** approved (brainstorm session, solution-auditor consulted)
**Amends:** docs/superpowers/specs/2026-08-07-muster-v1.md sections 1, 4.3, 8.3

## Problem

Board state lives in `tasks/` status folders. The status block (spec 8.3) prints only
inside `bin/claim` — so only executor/reviewer sessions see it, only at claim time.
Between dispatches a human inspects folders directly, but `ls` cannot compute STALE
(claimed_at age) or DEAD (backlog behind failed work), and the raw inbox count cannot
answer the human's actual dispatch question: **which of the two dispatch lines do I
type next — `/muster:run` or `/muster:review`?**

The split is well-defined by construction: `bin/claim` enforces a strict two-way tier
match (`claim.ps1` — a `tier: strong` task is claimable only by `-Tier strong`, a
`tier: any` task only by `-Tier any`). Inbox therefore partitions exactly into
run-claimable and review-claimable. The status block just doesn't show it.

Confirmed usage fact this design serves: the operator reads the executor session's
final output before dispatching the next session.

## Decision

Three pieces, all reusing the existing `Get-StatusBlock` / `status_block` function
(`runtime/bin/_lib.ps1`, `runtime/bin/_lib.sh`). No new display logic is designed;
one format amendment, two new call sites.

### 1. Status block gains a dispatch split (spec 8.3 amendment)

The inbox line adds a parenthesized split, labeled by dispatch verb (not by tier
jargon), before the id list:

```
MUSTER status @ <repo-name> (<branch>)
  inbox    <n> ready      (run <n>, review <n>) [<ids, filename order>]
  doing    <n>            [<id> claimed <age>]        <- STALE if age > 24h
  backlog  <n> blocked    (<n> DEAD: <id> behind failed <dep-id>)
  failed   <n>            [<ids>]
  done     <n>
```

- `run <n>` = inbox tasks with `tier: any`; `review <n>` = inbox tasks with
  `tier: strong` (review tasks and the terminal integration task both carry
  `tier: strong`, so `review >= 1` literally means `/muster:review` will claim
  something).
- The split is always printed, including zeros.
- Inbox files with unparseable frontmatter count toward the total `<n>` and toward
  neither bucket; when any exist, append `, invalid <n>` to the split so the
  discrepancy is named rather than silent.
- The harness axis (claude/codex) is deliberately not split. PoC is Claude-only
  (D16). When Codex activates, the split may need a harness dimension — noted here,
  out of scope now.
- Every caller inherits the change: the existing claim-time print, and the two new
  call sites below.

### 2. `bin/status` — on-demand board print

`status.ps1` + `status.sh`, ~6 lines each: locate repo root, dot-source `_lib`,
print the status block, exit 0 (including on an empty board). No parameters.

- Header comment marks it **not part of the RUNNER contract** — the same precedent
  as `lint`, so D17's four-executor-verb contract is untouched. Executors are never
  told about it; RUNNER.md does not change.
- Runs from a bare terminal (no session needed), an orchestrator session, or any
  other context. This is what makes STALE/DEAD detection reachable between
  dispatches instead of only at claim time.
- Installed by `muster:init` alongside the other bin/ scripts (spec section 1
  listing gains `status`).

### 3. Counts-only board line in `bin/done` output (spec 4.3 amendment)

On the success path, `done` prints one board line immediately before the terminal
line, which stays literally last:

```
Board: run 2 | review 1 | backlog 2 (1 DEAD) | failed 1 | done 4
Done: <id>. Promoted: none. Do not claim another task. Session over.
```

- Counts only, labeled by dispatch verb — **no task ids**. Ids are the one
  temptation-shaped payload for a model that has just been told to stop; counts are
  strictly milder than the `Promoted: <ids>` list the done line already emits.
- Same invalid-frontmatter rule as the status block: when unparseable inbox files
  exist, `invalid <n>` appears after `review <n>`.
- Success path only. The `done fail` path (review verdict fail) keeps its existing
  output: it already ends with its own next-step instruction, and the staged fix
  task's promotion state is in flux at that moment.
- `DEAD` and `failed` nonzero mean "recover before dispatching". All zeros except
  `done` mean the plan is finished (`/muster:close`).
- Computed via the same `_lib` helpers as the status block (same tier split, same
  DEAD scan). STALE is omitted: the completing claim just emptied `doing/`, and
  other checkouts are out of v1 scope (D18).
- The session-tail read then answers the dispatch question directly, serving the
  confirmed operator habit without a terminal round-trip.

## Deliberately excluded

- **`/muster:status` skill wrapper.** Strictly more surface (sixth skill, manifest
  entry, anti-trigger prose per spec 8.2) than the bare script for zero extra reach.
  Defer until the script proves annoying to invoke.
- **Full folder-content dump at end of `done`.** Late-plan `done/` gets long, noise
  drowns the terminal instruction, and id lists are the risky payload.
- **An explicit `next: /muster:<verb>` suggestion line.** Counts labeled by command
  already answer it; encoding dispatch *policy* (e.g. review-before-run ordering)
  into scripts is new territory, and v1 keeps dispatch choice human.
- **Waiting for the v2 control-plane viewer.** Still the answer for dashboards,
  registry, and history; a one-shot CLI status print neither displaces it nor
  justifies waiting for an ASP.NET app to learn "is anything failed right now".

## Costs (accepted)

- Both pieces of new/changed script behavior land on **two engines** (ps1 + sh) with
  identical output, plus tests: split logic in `_lib` tests, board line in done
  tests, a small contract test for `status`.
- Spec 8.3 gains the amended format and a note that the block now has three callers
  (claim, status, done-summary); spec 4.3 gains the board line; spec section 1
  listing gains `status`.
- README: mention `status` in the bin/ script list and in the dispatch loop
  description.

## Error handling

- `status` on an empty board prints the existing empty-board line
  (`MUSTER: board empty - nothing sharded or all archived.`) and exits 0.
- Malformed inbox frontmatter never crashes the print: counted as `invalid`,
  skipped for bucket purposes (matching the existing DEAD scan's skip-on-error
  behavior).
- `status` outside a git repo fails with the existing repo-root refusal from `_lib`.

## Testing

- `_lib` unit tests: split counts (any/strong/invalid mixes), always-printed zeros.
- `done` tests: board line present, correct counts, terminal line still last.
- `status` contract test: prints block, exit 0, empty-board case.
- Engine parity: same fixtures through ps1 and sh, byte-identical block output
  (existing parity test pattern).
