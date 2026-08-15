# MUSTER v2 design — Go + SQLite, git-as-log

**Status:** validated design, 2026-08-15. Brainstormed with adversarial review at every gate
(three opus adversarial passes, one solution-auditor pass, one independent Codex survey,
web research per open question). Supersedes `docs/muster-v2-redesign-exploration.md` where
they conflict (notably: v2 root is `.muster/`, not `tasks/`; language is Go, not C#).

## 1. Why v2 exists

The test-speed consolidation work (`docs/test-speed-consolidation-plan.md`, phases 0-4,
complete) measured that v1's cost floor is architectural, not linguistic: git subprocesses
plus fixture disk I/O account for F_low = 103.2 s of a 166 s test loop, and the interpreter
residual (A_high = 64.7 s) accounts for most of the rest. Git-as-a-database makes every
state transition a subprocess parade and every test a throwaway git repo. No language fixes
that; moving hot-path state out of git fixes it for every language.

Selection criteria, in order:

1. **FAST** — instant CLI startup, full test suite in seconds, snappy transitions.
2. **ROBUST** — atomic claims (two executors can never grab one task), crash-safe state,
   no service that can be down, simple recovery.
3. Hobby-maintainable by one person with coding agents; Windows-first.

## 2. Decisions (all adversarially reviewed)

### D-v2-1. Single machine forever

No cross-machine executors planned. Embedded storage (SQLite). A thin repository-style
seam keeps a hypothetical later SQL Server swap contained; nothing else is built for it.
SQL Server flip condition (multi-machine board) recorded and parked.

### D-v2-2. Metadata split ("B-prime"): file owns what a task IS, DB owns what HAPPENED

- **Card file** (`.muster/cards/<plan>-<seq>-slug.md`, git-tracked, immutable after
  ingest): YAML frontmatter — `id`, `type`, `tier`, `harness`, `depends_on`,
  `commit_paths`, `protected`, `verify` — plus prose (context, steps, acceptance).
  The card is the executor's prompt, exactly as v1.
- **DB** (`.muster/muster.db`, gitignored): status, claimed_at, claimed_by, attempts,
  generation, verdicts, events, head_at_claim, plus a **sha256 of the card frontmatter**
  taken at ingest.
- Ingest parses frontmatter once, stores the denormalized copy + hash. Scripts trust the
  DB thereafter. Hash mismatch on a later read = **warning event** (not a board halt);
  deliberate edits go through `muster reimport <id>` which re-lints and re-hashes.
- Hot-decision card reads come from `git show HEAD:<card>` so executor edits to their own
  card stay inert (v1 semantics preserved without the git-commit cost).
- Mutable state never lives in frontmatter. This fixes a v1 wart: `generation` was
  regex-injected into card frontmatter by `done fail`; in v2 it is a DB column.

Rejected: DB-owns-everything/pure-prose cards (option A — killed by adversarial review:
breaks reviewer-authored fix cards, creates hidden authority where the file an agent reads
is not the file that governs, makes the board unrebuildable, and its cited precedents
actually argue for the split — modern CI keeps definition-in-file/state-in-DB);
frontmatter-authoritative with DB index (no atomic claims); full-DB no files
(agents read markdown natively).

### D-v2-3. Clean cut from v1; v2 lives in `.muster/`

- **Own root.** `.muster/` (cards, plans, db, RUNNER.md), not inside `tasks/`. v1 has four
  unscoped recursive `*.md` scans over `tasks/` that would ingest v2 cards, and SQLite
  WAL sidecars inside `tasks/` would trip v1's dirty-tree gate and brick claims. Separate
  roots let both boards run side by side during the dogfood build.
- **No import tooling.** v1's attempt counter is commit-message archaeology (D28); a
  faithful import would reimplement the git dependency v2 deletes, an unfaithful one
  resets attempt budgets (the exact gaming pressure v1 blocks). Finish in-flight v1 plans
  on v1, then cut. Current board is empty except archive — cost is nil.
- **Init guardrail.** `muster init` refuses on a live v1 tree using v1's own task-file
  semantics (`*.md` minus `*.result.md`/`*.notes.md` in inbox/backlog/doing/staging/failed,
  plus `tasks/plan-*.md` snapshots at the tasks root). Refusal names the exact live files
  and the remedy. `.gitkeep`s and orphaned verify.log/notes.md do not false-positive.
- **Decommission, not just check.** At cutover, init stubs `tasks/bin/*` with a refusal
  message and rewrites the CLAUDE.md pointer — closes the stale-dispatch window where v1
  scripts run weeks later against a board v2 owns.
- v2 ingest **fails closed** on unknown `depends_on` ids. If archived-v1 ids must ever
  satisfy deps, that is a one-time seed INSERT, not a compat layer.
- Before v1 code is deleted, one synthetic v1 board tree (cards in every folder + the
  claim/attempt commit sequence) is frozen as a test fixture — the only thing that rots
  if `muster adopt` is ever revived.

### D-v2-4. Git-as-log: zero git writes on the hot path, one commit per task

Measured reality: v1's slowness is per-transition commits amplified by ~120 test fixtures,
not the cost of one commit (~0.9-1.0 s measured for the full done sequence on this
machine, Defender-dominated). Zero-git was adversarially killed on mechanism: review tasks
read the completion commit's diff, the integration task reconstructs the combined diff
from per-task commits, and the D30 create-then-freeze anti-gaming guard only works because
the authored test becomes tracked at done.

- **Hot path (claim, verify, promote): zero git writes.** Reads only: `git show HEAD:`
  card reads at verify/done, `git rev-parse` at claim.
- **`done` = the one commit per task**: code + sidecars, explicit paths only, message
  grammar kept (`muster(<plan>): done <id>`).
- **Commit-first ordering; `status=done` is derived.** done runs: git commit → DB flip →
  promote. A crash between commit and flip is healed by a claim-time reconciler that finds
  the done commit by message grammar. No two-domain write can disagree permanently.
- **`head_at_claim`** recorded at claim; done refuses if HEAD is not a descendant; all
  scope/protected diffs run `head_at_claim..HEAD` (replaces the claim-commit baseline).
- **Attempts = append-only events**, hash-chained (`sha256(prev_hash || payload)`),
  UPDATE/DELETE blocked by trigger; the chain head is written into the result sidecar so
  the done commit anchors the audit trail in git. (Threat model unchanged from D27: the
  confused executor, not the adversarial one; the anchor restores the forensic trace that
  leaving git would otherwise delete.)
- **Hooks are honored, never silently bypassed.** Init detects hooks and sets policy; if
  a hook mutates the tree, done re-checks scope and re-stages. (A tree-mutating pre-commit
  hook otherwise leaves permanent dirt that would refuse every subsequent claim.)
- **DB backup:** `VACUUM INTO .muster/backup.db` at each done. Survives `git clean -fdx`
  (measured: `-fdx` deletes a gitignored db; `-fd` spares it).
- Defender exclusion for the repo documented in init preflight output.

### D-v2-5. Reviewer flow re-homed unchanged

Industry survey (verifier pattern, iteration-cap consensus of 2-3, Gerrit's
mechanical-vs-judgment label split) validates v1's protocol point-for-point; the storage
move changes mechanics only.

- Shard pre-writes review tasks; `depends_on` gates downstream work on the REVIEW task id.
- Verdict = `muster done pass|fail` on the review task → `verdicts` row; **reason required
  on fail** (queryable, replaces archaeology).
- Fail → reviewer authors ONE fix card into `.muster/staging/`; `done fail` lint-validates
  and ingests it through the same path as shard; generation counter (DB) increments;
  generation 3 refuses and drops to failed for the human. Cap: 2 review cycles.
- At most one staged fix; claim refuses while one is pending (DB check, not folder scan).
- Review sessions stay structurally independent (fresh dispatch, reads the completion
  commit's diff — preserved by D-v2-4).
- Tier pinning unchanged: wrappers declare identity; claim enforces.

### D-v2-6. Stack: Go + modernc.org/sqlite, single static exe

Three independent passes (Codex GPT-5.6 survey, own web research, opus solution-auditor)
ranked Go #1 / C# Native AOT #2, narrow margin. Owner picked Go 2026-08-15.

Deciding factors: tested-artifact = shipped-artifact (no JIT-test/AOT-ship split; C#'s
trim/native-asset faults surface only at publish), sub-second `go test` loop vs
seconds-per-run `dotnet test` host, one-step toolchain install on a fresh box (C# AOT
needs .NET SDK + multi-GB MSVC C++ workload for the linker), no CGO/no DLL with the
pure-Go driver (production-proven: 2+ years CI, gogs/GoToSocial migrations), Go 1.x
stability. C#'s remaining cards — owner fluency, canonical SQLite engine, compiler-checked
exhaustive switch — judged not worth the toolchain costs; the dashboard future does not
constrain the choice because the SQLite file is the interface (a later ASP.NET viewer
reads the same db; WAL supports concurrent readers).

Rejected: Rust (slowest loop, weakest owner fallback), PowerShell + in-process SQLite
(A_high 64.7 s interpreter residual + 200-400 ms host startup fail FAST — measured),
Bun/Python (runtime/distribution), LMDB (hand-rolled indexes/migrations), redb/BadgerDB
(exclusive process lock — needs a daemon), SQL Server/Postgres (service dependency +
heavy test fixtures; single-machine ruled the flip condition out), flat-file+LockFileEx
(the crash matrix becomes a hand-rolled database).

## 3. Layout

```
TARGET REPO
├── .muster/
│   ├── muster.db            SQLite WAL — all mutable state (gitignored: muster.db*)
│   ├── backup.db            VACUUM INTO target, refreshed at each done (gitignored)
│   ├── .gitignore           ships with init (db globs)
│   ├── .gitattributes       *.db binary -text (self-contained per target repo)
│   ├── cards/               immutable definitions + sidecars, git-tracked
│   │   ├── <plan>-<seq>-slug.md
│   │   ├── <id>.result.md   written at done
│   │   ├── <id>.notes.md    executor notes
│   │   └── <id>.verify.log  verify transcript (size-capped)
│   ├── staging/             at most one reviewer-authored fix card (transient)
│   ├── plans/<plan-id>.md   sharded plan snapshots
│   └── RUNNER.md            executor contract (near-verbatim v1)
├── muster.exe               or on PATH — single Go binary
└── tasks/                   v1 tree, untouched until cutover, then bin/ stubbed
```

## 4. Schema (minimum)

```sql
tasks(id TEXT PK, plan TEXT, seq INTEGER, type TEXT, tier TEXT, harness TEXT,
      status TEXT, card_path TEXT, frontmatter_sha TEXT, head_at_claim TEXT,
      claimed_at TEXT, claimed_by TEXT, generation INTEGER DEFAULT 0)
deps(task_id TEXT, depends_on TEXT)            -- fail closed on unknown ids at ingest
events(id INTEGER PK, task_id TEXT, actor TEXT, verb TEXT, detail TEXT,
       created_at TEXT, prev_hash TEXT, hash TEXT)   -- append-only; triggers block UPDATE/DELETE
verdicts(task_id TEXT, reviewer TEXT, verdict TEXT, reason TEXT, created_at TEXT)
schema_version(version INTEGER)
```

Pragmas: `journal_mode=WAL`, `synchronous=FULL`, `busy_timeout` 2-5 s, `foreign_keys=ON`.
Migrations run inside transactions. Explicit retry on `SQLITE_BUSY`.

Atomic claim:

```
BEGIN IMMEDIATE
  SELECT next eligible task (status=inbox, tier/harness match, ordered)
  UPDATE ... SET status='doing', claimed_at, claimed_by, head_at_claim WHERE still eligible
  INSERT claim event
COMMIT
```

Nothing slow (git, filesystem walks, subprocesses) inside the transaction.

## 5. CLI surface

| Verb | Role |
|---|---|
| `muster init` | Preflight (git repo, identity, sync-root warning, hook detection/policy, v1-liveness refusal); creates `.muster/`; at cutover decommissions v1 (stubs `tasks/bin/*`, rewrites CLAUDE.md pointer) |
| `muster ingest <files...>` | Shard handoff: lint (ported v1 checks incl. prose checks — placeholders, un-inlined refs, judgment language, size cap, verify network-free), hash frontmatter, insert rows + deps (fail closed), one transaction per batch |
| `muster claim -tier X -harness Y` | Runs promote, prints status block (pending / stale doing / dead-blocked), recovery probe (gates kept: type impl|fix AND prior claim event), atomic claim |
| `muster verify` | Verify block read from `git show HEAD:` card; runs commands; writes verify.log; attempt = event row; attempt 3 fail = terminal → failed |
| `muster done [pass\|fail]` | Impl: sidecar assembly (files from `head_at_claim..HEAD` diff), scope/protected checks, git commit (commit-first), DB flip, promote. Review: verdict row (reason required on fail); `fail` validates + ingests the staged fix card, generation+1, cap 2 |
| `muster promote` | Deps-satisfied backlog → inbox; idempotent; auto-runs at claim and done |
| `muster board` / `muster show <id>` | Rendered board / full task view (replaces lost grep-ability) |
| `muster redo <id>` / `muster fail <id>` | Human recovery verbs (replace v1's file-move ritual); redo grants fresh attempts |
| `muster reimport <id>` | Deliberate card edit: re-lint, re-hash |
| `muster doctor` | Chain verification, orphaned claims, missing cards, db-vs-git drift, integrity check |

## 6. Protocol contracts

**RUNNER.md v2** — same five verbs (CLAIM, DO, VERIFY, REPORT, DONE), same hard rules
(no git writes by executors, one task per session, refusal = report and stop, `Session
over.` is the only stop signal). Changes: invocations become `muster <verb>` (no ps1/sh
split), notes sidecar path moves to `.muster/cards/`, recovery section shrinks to the new
verbs. Everything else survives near-verbatim.

**Wrapper skills** (muster:init/shard/run/review/close/auto) survive; they repoint from
`tasks/bin/*.ps1` to `muster` verbs. Shard's authoring contract is unchanged: it writes
card files, then calls `muster ingest`. muster:auto stays strictly sequential (D18).

## 7. Failure matrix

| Failure | v2 behavior |
|---|---|
| Executor crash mid-task | Stale claim shows in every status print; human: `muster redo` (dirt left for probe) or `muster fail`; probe auto-files finished work |
| Crash between done's commit and DB flip | Claim-time reconciler finds the done commit, heals the row (derived status) |
| done's git commit fails (hook reject, index.lock) | DB untouched (commit-first) — clean retry |
| Verify attempt 3 fails | Terminal: status failed, card + sidecars + dirt remain as evidence |
| DB lost/corrupt | `backup.db` (last done); worst case: re-ingest cards from git, done state recoverable from commits, in-flight redone |
| Two executors race a claim | SQLite `BEGIN IMMEDIATE` — loser waits or takes next task |
| Confused executor edits its card | Inert (HEAD reads); hash-mismatch warning event |
| Confused executor touches the DB | Hash chain breaks → doctor/done detects against sidecar-anchored chain head |
| Board wedged, human at 2am | `muster doctor`, `muster board`, events table queries, git log of done commits |

## 8. Testing

- **Unit/integration (~90 %+):** pure Go, temp dir + temp SQLite **file** per test (real
  WAL semantics, not `:memory:`), zero git, zero subprocess. Target: whole tier in seconds.
- **Process tier (~10-20 tests):** real `muster.exe` against temp git fixtures — claim
  race with two real processes, done's actual commit, hook interaction, init preflight,
  crash-kill before/after the commit point (reconciler proof).
- v1's tier machinery (contract matrix, black-box inventory, growth freeze) is not
  ported; `tests/ContractMatrix.psd1` + `tests/BlackBoxInventory.psd1` serve as the
  keep/drop/re-home behavior checklist during planning, then retire.
- Frozen synthetic v1 board fixture kept (see D-v2-3).

## 9. Build sequencing (dogfood)

1. This spec → `superpowers:writing-plans` → `/muster:shard` → **v1 executes the v2
   build** on this repo. v1 untouched throughout; `.muster/` + Go module dir collide with
   nothing (Q3 layout).
2. Rough phase order: scaffold + schema/migrations → store layer (claim transaction
   first, riskiest) → core loop verbs (claim/verify/done) → ingest/promote/board →
   RUNNER.md v2 + wrapper repoint → process tier + crash tests → cutover task (init here,
   decommission v1, archive the build plan).
3. Dogfood gate: v2 must shard and run its own final integration plan before v1 dies.
4. Rough size: ~1,500-2,500 lines of Go replacing ~991 lines PS + 1,364-line sh mirror +
   lint scripts + tier machinery.

## 10. Deferred, explicitly

- Dashboard (`muster board --serve` in Go, or a separate ASP.NET reader on the same db —
  the SQLite file is the API; WAL supports concurrent readers). Not in v2 scope.
- Cross-repo board, multi-machine executors (SQL Server flip condition), `muster adopt`,
  Codex-app executor enablement (D16 gate unchanged).

## 11. Evidence trail

- Measurements: `docs/test-speed-consolidation-plan.md` (D7 gate, F_low/A_high
  decomposition), `docs/runtime-consolidation/phase4-comparison-2026-08-14.md`.
- Adversarial reviews (opus, fresh context): Q2 metadata (killed DB-owns-all, produced
  B-prime), Q3 migration (produced `.muster/` root + decommission + guardrail semantics),
  Q4 git role (produced commit-first/derived-done, head_at_claim, hash-chained events,
  hook policy, backup; measured done ≈ 0.9-1.0 s, `git clean` behavior).
- Codex survey (GPT-5.6-sol): 9-stack ranked comparison; redb/Badger disqualification;
  transaction-model and operational defaults adopted in §4.
- Solution-auditor (opus): 5 alternatives ranked, sycophancy tier NONE.
- Precedents: Taskwarrior 2→3 (flat files → SQLite, explicit cutover, loud-leftover
  lesson), modern CI definition-file/state-DB split, Aider (tool-owned commits, hook
  bypass hazard), verifier-pattern iteration caps (2-3 industry consensus), Gerrit label
  model (mechanical/judgment split — already MUSTER's tier 0/1).
