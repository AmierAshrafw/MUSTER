# MUSTER v2 redesign exploration

**Status:** idea capture, 2026-08-14. Not approved, not planned. Next step is a proper
brainstorm (solution-auditor included) if/when we decide to pursue.

**Origin:** the test-speed consolidation work (phases 0-4, `docs/test-speed-consolidation-plan.md`)
ended with a measured conclusion: the 30 s dev-loop gate is unreachable *in any language*
on the current architecture, because the cost floor is git subprocesses + fixture disk I/O
(F_low = 103.2 s of a 166 s loop; fixture I/O alone 39.8 s). That finding killed the
rewrite-for-speed idea (C# rule-1 exit, D7) — and pointed at the real culprit.

## The key insight

**Language was never the problem. Git-as-a-database is.**

Every v1 state transition is file moves + `git commit`; every test pays for a throwaway
git repo. Any rewrite that keeps that design inherits the floor. A redesign that moves
*state* out of git removes the floor for any language. Square one is a storage decision,
not a language decision.

## Proposed stack

| Concern | Choice | Why |
|---|---|---|
| Language | **C# / .NET** (AOT single binary) | Owner's day-job stack, already installed. `PublishAot` gives ~10-30 ms startup native binary — old JIT-warmup objection is dead. State machine as enums + exhaustive switch = compiler-enforced transitions (v1 needs lint scripts + RUNNER discipline for this). |
| State storage | **SQLite** (WAL mode), `tasks/muster.db` | Board lives with the repo: one file, backup = copy, no service to run, zero config. Atomic claim via `UPDATE ... WHERE status='ready' ... RETURNING` — two executors physically cannot grab the same task. `:memory:` test fixtures cost microseconds. |
| Task content | **Markdown files**, `tasks/cards/*.md` | Agents read/write markdown naturally; board content stays `ls`-able. DB owns state, files own prose — one source of truth each. |
| Audit | `events` table (task, actor, verb, timestamp, detail) | Replaces git-history-as-audit; queryable instead of archaeological. |
| Data access | One small repository class, plain ADO/Dapper, **no EF** | Keeps a later SQLite → SQL Server swap a contained change. |
| Tests | xUnit, in-process, in-memory SQLite + temp markdown dirs | Whole suite in seconds. No git in the hot path = no fixture floor, no tiers, no contract matrix, no runspace divergence. |

### SQL Server: considered, parked

Also installed, also familiar. Genuinely offers the classic multi-worker queue pattern
(`UPDATE TOP(1) ... WITH (ROWLOCK, READPAST)`) and SSMS ad-hoc querying. Rejected for
now because MUSTER uses none of its real advantages (network access, many users, big
data) while paying its costs: service dependency (service down = board dead), board
state divorced from the repo (connection strings, db-per-repo), and heavier test
fixtures (LocalDB, per-test databases at hundreds of ms).

**The flip condition:** executor sessions on *multiple machines* against one shared
board. SQLite cannot do that. If distributed executors ever becomes a real ambition,
start on SQL Server (LocalDB for tests) rather than migrate later. The repository-class
seam above is the paved exit ramp either way.

## What survives from v1 unchanged

- `RUNNER.md` executor contract — prompt engineering, language-agnostic
- The state machine itself: inbox → backlog → staging → doing → done/failed, review
  cycle, promote — proven design, just re-homed
- `/muster:shard` flow — plans become rows + card files instead of task files
- Verify-before-done discipline

## What v1 machinery becomes unnecessary

- Overlap lint, file-move choreography, "never edit tasks/ by hand" — all exist to fake
  transactions on a filesystem; SQLite provides real ones
- The entire test-tier architecture (fast tier, contract matrix, process tier,
  black-box growth freeze) — needed only because spawning PowerShell children and
  building git fixtures was expensive
- The sh mirror (1,364 lines) — one binary serves every shell

## What is lost

Git-diff history of task file edits. If wanted: `muster` can optionally auto-commit
`tasks/cards/` — decoupled from the state machine, async, never in the hot path.

## New cheap wins

- `muster board` — instant rendered board (terminal table or local HTML page)
- `muster watch` — executors poll with a query instead of directory scans
- Cross-repo later if wanted: one db, `repo` column

## CLI surface (sketch)

`muster init | shard | claim | done | verify | review | promote | board | watch`

Rough size estimate: ~500-800 lines of C# for the runtime vs v1's ps1 runtime plus
1,364-line sh mirror.

## Open questions (for the brainstorm, if pursued)

1. Multi-machine executors ever? (Decides SQLite vs SQL Server — see flip condition.)
2. Card files: how much task metadata stays in frontmatter vs moves to the DB?
3. Migration story for an in-flight v1 board, or clean-cut per repo?
4. Keep optional git auto-commit of cards, or drop entirely?
5. Does the reviewer flow (`/muster:review`) change shape when verdicts are rows?
