# Decision ledger

Settled direction with rationale. Open to challenge, but reopening one means re-arguing its "why".
D15+ came out of the adversarial review panel (4 subagents, 2026-08-07) and the apps-only constraint.

## D1. Requirement = delegate-and-forget agentic flow

Fresh-context executors, harness-agnostic, manual dispatch v1, automation end-state.
Fresh context and multi-harness both matter, but durability + delegation is the core driver.
Why: context rot makes one-session whole-plan execution degrade; copy-paste dispatch is the pain being killed.
Amended by D16: automation end-state is blocked until a CLI harness exists on the box.
Further amended by D31: the dispatch *loop* is automated intra-session by `muster:auto` (subagents, not new app instances); the cross-app automation end-state stays D16-blocked.

## D2. Two-plane architecture

Data plane = task files in the target repo. Control plane = ASP.NET + SQL Server app, later, read-side only.
Why: files are the only interface every harness speaks with zero config.
The app must never sit in the agent critical path - app down must not stop agents.

## D3. Agents touch files only, never DB/HTTP

Why: Codex sandbox blocks network by default (localhost SQL and HTTP included; the app's config override has a known ignored-bug).
Files are git-versioned, atomic-rename claimable, and human-inspectable.

Re-challenged and re-rejected: "MUSTER as ASP.NET app with agents querying API/MCP".
Fails on critical path (app must be up for any agent to work), bootstrap paradox (the pipeline would depend on an app the pipeline is supposed to build), and sandbox friction.
Everything wanted from the app survives as a read-side mirror fed FROM files.

## D4. Ride superpowers, don't replace it

Planning stays 100% existing superpowers (brainstorming, writing-plans, plan-reviewer, yagni-guardian gates).
MUSTER adds one new final step: `muster:shard` converts an approved plan into task files.
Why: planning quality tooling already exists and works; replacing it means rebuilding it worse.
Amended by D23: executor-facing context is INLINED into tasks as excerpts; the plan is snapshotted at shard time. "Reference, don't duplicate" holds for humans and the orchestrator, not for executors - a pointer makes a weak session eat the whole plan.

## D5. MUSTER plugin = thin layer, not a fork

Plugin contains only muster-specific skills (init / shard / run / review / close). Zero superpowers files copied or modified.
Why: forks drift; superpowers updates would rot a copy.
Opt-in comes free: small tasks use the normal path; MUSTER engages only when its skills are invoked.

## D6. Canonical executor contract = tasks/RUNNER.md

Logic lives in one plain file in the target repo. Skill wrappers per harness are thin pointers that also declare harness identity.
Why: executor logic in plugin-only would silently break the other harness.
No symlinks - unreliable on Windows + git. Thin pointer files instead.
Amended by D17: RUNNER.md describes five verbs and points at bin/ scripts; the protocol itself is code.

## D7. Promotion is scripted and runs at claim time AND completion time

`bin/promote` moves any backlog task whose depends_on are all in done/ or archive/** into inbox/. Invoked by `bin/claim` (start of every session) and `bin/done`.
Why (amended): completion-only promotion had a permanent-deadlock window - the last finisher crashes or forgets the epilogue, backlog holds ready work forever, and "empty inbox" reads as healthy. Claim-time promotion makes every new dispatch self-heal the previous session's drop.
Original rationale stands: completion is the natural unblocking event; races are safe because rename is atomic.

## D8. Executors open inside the target repo

cwd = project. The executor reads ./tasks/ and nothing else. No registry lookup executor-side.
Why: sandbox-safe, zero path resolution, git ops natural.
Consequence: registry.json is demoted to orchestrator/app concern, out of the v1 critical path.

## D9. Weak-executor principle

The orchestrator (strong model) does ALL thinking at shard time: explicit steps, exact paths, acceptance criteria, verify commands.
Executors get zero judgment calls.
Why: keeps execution cheap and small sharp tasks survive weaker long-context handling. Still holds with the higher app-tier floor (D16) - it is what makes execution outsourceable at all.

## D10. Two-tier verification

Tier 0: deterministic verify block, mandatory on every task, run BY THE VERIFY SCRIPT (D17/D20), capped at 3 attempts.
Tier 1: agent review as a NEW TASK (not a status), pre-written at shard time (D19), pinned to a strong tier, checking only what code cannot test.
Hard rule: no task without a machine-testable end condition; un-checkable work gets weak verify + forced review.
Why: reliability order is code > engineers > agents - applied to the checks AND (post-review-panel) to who runs the protocol.

## D11. Redo flow = capped loop

Review fail = reviewer authors a fix task pointing at findings; fix carries review again.
Amended: generation counter in frontmatter; generation 3 refuses to spawn and drops to failed/ for the human. Cap = 2 review cycles in v1.
Why: uncapped ping-pong is a money pump on the most expensive model, and "visible in folders" only brakes it if the human happens to look. Two independent reviewers converged on capping now, not in v2.

## D12. Stale doing/ = automated detection, human recovery

Detection moved out of the executor: the dispatch-time status print (wrapper + claim script) lists stale claims AND dead-blocked backlog tasks (ready work stuck behind failed/ dependencies).
Recovery stays manual: check git state, move the file back to inbox/ or to failed/. No auto-reclaim.
Why: auto-reclaim's failure mode is two executors interleaving work on a dirty tree - corrupting. Manual recovery's failure mode is delay - boring. Choose the design whose failure is boring.
Recovery is idempotent by construction: on re-dispatch `bin/claim` probes the verify block before execution; already green = a crashed predecessor finished the work - file it as done without re-executing steps.
Amended: the probe is gated on two conditions that must BOTH hold (spec 4.1.9) - `type` is `impl` or `fix`, AND git history already shows a claim commit for that id. Ungated it would auto-file every review and integration task, whose verify is green before the judgment work happens.

## D13. Multiple task lists per project

One project can hold several sharded plans, possibly concurrent.
Flat status folders stay; the `plan` frontmatter field groups tasks; filenames embed the plan id (D23) so nothing collides.
No folder-per-plan (folder explosion).

## D14. Sequencing

v1 file convention + bin/ scripts + plugin, zero app build. v2 ASP.NET viewer built through the pipeline (dogfood). v3 richer app workflow; programmatic dispatch only if a CLI ever lands on the box.
Why: v1 must exist before the app can be built BY it.

## D15. Plan closeout and archive

When a plan's board is empty except done/, move its cards in one batch to `tasks/archive/<plan-id>/` (manual or `muster:close`).
Why: done/ pileup slows and confuses the promote scan; small done/ keeps promotion trivially cheap.
Rule: a dependency on an archived task counts as satisfied (archived = done by definition).

## D16. Executors are the two desktop apps only (v1 constraint)

Claude Code app + Codex app. No CLI harnesses; Kimi-class CLIs -> KIV.

**PoC sub-constraint (2026-08-07): Codex is not installed yet.** The PoC runs entirely on Claude Code desktop: Fable 5 orchestrates and reviews, Sonnet 5 executes. Tier pinning ships now (it separates Sonnet executors from Fable reviewers); the Codex wrapper and network-free-verify enforcement stay designed but dormant. Codex arrival gate: install -> smoke test (scripts, rename, commit, .agents/skills discovery) -> D26 measurement -> route bulk execution there.
Consequences:
- "Cheap execution" = quota arbitrage between two flat-rate subscriptions: Codex absorbs execution, Claude quota is reserved for judgment (shard, review). This is the strongest multi-harness argument - the "just use Claude subagents" alternative burns the exact quota being protected.
- Capability floor rises to GPT-5-Codex-class / Claude-class; catastrophic weak-model scenarios become tail risk. Scripts stay anyway (D17).
- No headless mode in the apps: programmatic dispatch is dead until a CLI is installed. Manual dispatch is the ceiling.
- Codex app sandbox network-deny is hard: verify blocks must be network-free; tasks needing package restore carry `harness: claude` (D25).

## D17. State transitions are scripts, not prompts

`tasks/bin/` (installed by muster:init, ps1 + sh): `claim`, `verify`, `done`, `promote`.
Scripts stamp claimed_at, validate frontmatter, write the verify transcript, own the attempt counter, perform the failed/ move, assemble result sidecars from git (`log`, `diff --name-only`), and commit transitions.
Executor contract shrinks to five verbs: claim, do the steps, verify until it says stop, done, write one paragraph of surprises.
Why: the review panel's convergent finding (3 of 4 agents) - the design put protocol mechanics in prose for the weakest reader, violating its own D10. Mechanics in code is testable, honest, and drop-proof. Zero portability cost: every harness must already run shell commands for tier 0.
Consequence: the task file is READ-ONLY to executors; all executor output goes to sidecars (`<id>.result.md`, `<id>.verify.log`).
Amended: `lint` (spec 2.6) and `status` (spec 8.3) also ship in `tasks/bin/`, six script pairs in total. Neither is a RUNNER verb - humans and the orchestrator call them, executors never do (spec 4.0).

## D18. One active executor per checkout

Claim atomicity protects the task file, not the working tree. Two sessions in one checkout produce chimera commits and cross-contaminated verify runs.
v1 hard rule: one executor per checkout at a time. Concurrent execution requires a git worktree per executor - KIV.

## D19. Review tasks are pre-written at shard time and gate the DAG

The orchestrator writes review tasks into backlog/ at shard time with `depends_on: [impl-task]`; the promote script releases them when the implementation lands. Executors never author task files.
Anything depending on a reviewed task depends on the REVIEW task's id - downstream work cannot start on unreviewed code.
Why: (a) executor-generated review tasks were the one artifact a weak model produced for a strong consumer, gated behind a conditional flag weak models drop; (b) without DAG rewiring, review was advisory theater - dependents promoted before the review ran.

## D20. Verify integrity

The verify script reads the verify block from the git-committed task version (executor edits inert).
Transcript sidecar is script-written; a done/ task without a matching log is by definition unverified.
Files named in verify commands are listed as `protected:` in frontmatter; `bin/done` refuses if git diff touches a protected file.
Amended: lint checks 5b/14 (M2) narrow this - a verify-named file need only be listed in `protected` or `commit_paths`; only test-shaped paths and test-runner invocations must be `protected` specifically, not every file named in verify.
Amended by D30: the protected check is tracked-diff-only, so a task may create the test it grades (protected AND commit_paths); the guard freezes it for downstream consumers, and review - not the guard - gates a self-authored test's quality.
Why: models under RL pressure claim passes without running, weaken tests, or edit the verify itself. Every one of those becomes mechanically detectable.

## D21. Git protocol

All task-state transitions on one designated branch (main) in v1; feature-branch flows out of scope until v2.
Claim = its own small commit. Completion = ONE commit: code + sidecars + task move + promotions.
Amended by D28: up to three attempt-marker commits now sit between claim and completion; the two-commit shape is no longer exact.
Never `git add -A`; explicit paths only (shard writes them into the task).
Why: uncommitted moves are destroyed by stash/checkout (silent un-claim); split commits leave done/ describing commits that don't exist. Git-atomic transitions make the durability claim true.

## D22. Shard-lint

`muster:shard`'s last step is a deterministic lint of its own output: frontmatter schema-valid, verify block parseable + network-free + machine-diffable expectations (exit codes or exact strings), size under cap, steps idempotent-phrased (target-state, not actions), no placeholders, no un-inlined references.
Why: the weak-executor principle was a vow with no mechanism - one un-lintable shard voids every downstream guarantee. Reject the shard output, not the executor's mess.

## D23. Ids, snapshots, inlining

Filenames embed the plan id: `<plan-id>-<seq>-slug.md`; shard refuses filename collisions anywhere under tasks/.
The plan is snapshotted to `tasks/plan-<id>.md` at shard time; tasks reference the snapshot; the live plan may drift.
Executor-critical context is inlined as excerpts, never pointed at.
Why: cross-plan filename collisions made the dependency scan false-positive; post-shard plan edits silently contradicted in-flight tasks; pointers make weak sessions eat whole documents.

## D24. Terminal integration task, mandatory per plan

Shard always emits a final task depending on all others: full build + test suite, strong-model review of the combined diff against the plan snapshot.
Why: tier 0 verifies tasks in isolation; tier 1 reviews one task; nothing else catches cross-task drift from isolated sessions that never saw each other's diffs.

## D25. Pinning is enforced by the claim script

Frontmatter `tier:` (strong/any) and optional `harness:` (claude/codex). Wrapper skills declare their identity; `bin/claim` refuses a mismatched claim.
Why: prose pinning relied on a cheap model voluntarily declining work - the exact judgment it doesn't have. Also routes network-needing verify (dotnet restore, npm install) away from the Codex sandbox.

## D26. Measurement gate before trusting the execution tier

Before routing bulk work to a newly added harness/tier, run ~10 real tasks through it manually and measure the verify pass rate.
Why: the cost story depends on a success rate nobody has measured. One number decides how much work routes there.
Timing: deferred to Codex arrival (see D16 PoC sub-constraint). Sonnet-on-Claude needs no gate - capability is not in question.

## D27. The board is protocol surface - scripts refuse executor edits under tasks/

The scope checks (claim step 7, done step 4) exempt only the executor-writable set under tasks/: `doing/*.notes.md`, `doing/*.verify.log`, `staging/*.md`. Any other changed path under tasks/ - bin/ scripts, RUNNER.md, task cards, done//failed/ history - refuses, same messages as any out-of-scope stray.
Why: the original checks blanket-exempted tasks/, so an executor could edit bin/verify.ps1 (neuter the grader), RUNNER.md, or a queued card and no script would notice - dirt under tasks/ survived every claim. RUNNER prose forbade it; nothing enforced it, violating D17's own thesis. Adopted from SSSF's "no agent may edit the machinery that grades it" - their permissions module records a builder running `git checkout` on the quality check about to judge it, so the confused-executor case is real, not hypothetical. Detection-oriented: catches the honest mistake at the next script run; a truly adversarial executor is out of scope (it could edit the scripts before they run - human reviews failed/ either way).

## D28. Attempts are marker commits, not log content

Before running any verify command, `bin/verify` commits the attempt header with
message `muster(<plan>): attempt <n> <id>`; the counter is
`git rev-list --count <claimCommit>..HEAD` grepping that exact message shape. The
marker commit is exit-code-checked - if it fails, verify refuses rather than run
an unaccounted attempt. It is the ONLY per-attempt commit: each next marker
re-commits the whole log, and the terminal move (done/fail) commits the final
output, so a separate transcript commit bought nothing except when a session dies
after the last attempt - and RECOVERY already preserves the working tree there.
The `plan` field is schema-validated to `[a-z0-9-]+` (same as `id`) because both
are embedded in the marker grep.
Why: the cap lived in a file both claim's dirty check and done's scope check let
the executor write - truncate the log, attempts reset to 0, retry forever. Prose
forbade it; nothing enforced it (the exact failure class D17 exists to kill).
Counting content in a committed blob was the first design and still resettable:
delete the log before every run and each commit re-truncates HEAD. Commits are
append-only without history rewrite; burning the marker BEFORE the run means a
killed verify still counts; and a redo resets naturally because the range starts
at the new claim commit.
Amends D21: claim-to-completion is no longer exactly two commits - up to three
attempt markers sit between them.
Source: adversarial review 2026-08-08, finding M1; plan reviews 2026-08-09 (B2/W4,
then B1/B3/W2 of the second pass).

## D29. A fail verdict files even when the done-check is red

`bin/done <fail>` on review/integration tasks records a failing done-check in the log
and proceeds; only pass verdicts (and impl/fix dones) gate on it.
Why: the done-check gate ran before the verdict branch, so the one verdict integration
exists to deliver - "the suite is broken" - could never be filed; the task sat in
doing/ until a human cleared it. A red check plus a fail verdict is consistent
evidence, not stale-pass risk.
The mechanism is deliberately verdict-shaped, not type-shaped: a review `done fail`
with a red check also files (covers a build broken mid-review, and crash recovery).
RUNNER step 3 is the routing layer on top: integration verify failures go to
`done fail`; review executors are told to stop on a broken environment because a
fix task authored against one is noise - the script permits, the protocol guides.
Source: adversarial review 2026-08-08, findings M4 + M3.

## D30. Self-authored tests: create-then-freeze

A task may create the very test its own verify grades against, and list that test in
BOTH `protected` and `commit_paths`. The done protected-check keys off the diff arm
only - `git diff --name-only <claim_commit>` - so a newly-created (untracked) protected
path passes at authoring time, while the commit_paths membership carries it through the
scope check. Once committed, the file is tracked; every downstream consumer sees it at
its own claim commit, so the same protected-check freezes it - create once, frozen for
the rest of the plan.
Why: greenfield plans seed no source into the baseline - the executor is the only writer
of repo source - so every test is self-authored at first touch. The M2 anti-cheat
(`protected` = hands-off grader) is aimed at a PRE-EXISTING test an impl task could weaken
to pass; against a test the same task authors, a mechanical guard is illusory (a weak
`assert True` could go in at creation). Self-authored test quality is gated by the review
task (D10/D19) reading the diff, not by the protected guard.
Correction: this realigns the implementation to spec 4.3 pre-3, which already defined the
protected check as tracked-diff-only. `Get-ChangedPaths` had merged the untracked arm
(`ls-files --others`) into the set feeding both the protected AND scope checks; correct
for scope (a stray new file is out of scope), over-broad for protected (it refused every
newly-created protected path, making the sanctioned self-authoring shape impossible). The
scope check still spans both arms; only the protected check narrows to the diff arm.
Amends D20: the M2 "test paths must be protected" rule now means "protected AND, when the
task authors it, also commit_paths" - the dual-listing is the create-then-freeze signal.
Source: executor deadlock report 2026-08-10 (geometry-ops-mini-01), root-caused this session.

## D31. Subagent-orchestrated dispatch (muster:auto)

A new orchestrator-side skill, `muster:auto`, loops dispatching one Claude-Code
Agent-tool subagent per claimable task (strictly sequential, one checkout,
D18) until a plan's board settles, then performs `muster:close`'s steps
itself. Each dispatch is a genuinely fresh subagent - zero parent context - so
the fresh-context guarantee (D1) holds exactly as it does for a human-opened
session; review/integration tasks are always their own separate subagent
call, never a resumed conversation, keeping review structurally independent
of the diff it grades. Run-tier subagents are dispatched on Sonnet 5,
review-tier on Fable 5 - preserving the quota-arbitrage economics (D16)
rather than burning strong-tier quota on execution.
Why: manual per-task dispatch (D1's v1 baseline) was pure human
window-management with zero judgment content once a status block already
says what to type next (board-visibility feature, 2026-08-08). Draining
multiple tasks into one orchestrating session's own context ("drain mode")
was considered and rejected: it dilutes D1's fresh-context guarantee and
makes review self-review if the same context that wrote a diff also grades
it. Subagent dispatch avoids both, because the subagent - not the
orchestrator's own context - does the work, and needs none of D16's
CLI-harness gate, since it is an intra-session primitive, not headless app
dispatch.
Source: brainstorm session 2026-08-10 (subagent-orchestration design +
plan-reviewer pass).

## D32. Shard-lint flags unordered commit_path overlap

Two `impl`/`fix` tasks may name the same `commit_path` with no `depends_on` edge
between them. Nothing detected it: `Test-LintChecks` read `commit_paths` per-task
only (checks 5, 13); the batch checks were just integration-count (11) and review
wiring (12). Execution is serial (D18) so there is no git race, but the second
same-file task's Steps are frozen at shard time against a view of the file that
predates the first task's committed edits. Non-additive Steps then silently
overwrite the first task's work at HEAD, caught only if a later verify or the
integration suite re-covers the clobbered code. Additive appends (MUSTER's own
`_lib.ps1` was built this way) are fine, but a lint cannot tell additive from
destructive - a shared path is a risk signal, not a proven defect.

New batch check (15): FAIL when two `impl`/`fix` tasks share a `commit_path`
(prefix-aware) with no transitive, either-direction `depends_on` ordering between
them. The author adds an edge (`Add-DependsOn`-shaped, one line) or reshards. The
forced edge costs nothing under D18's serial execution and stays correct under
future worktree concurrency (you cannot safely parallel-edit one file).
Reachability is transitive so the D19 `A -> review-A -> B` chain does not
false-positive.

Boundary: the check is full-batch only. Reviewer-authored fix tasks are linted
solo via lint-lite (no batch), so they are out of scope - acceptable because a
fix task is authored against the impl's real committed diff, not a stale plan
view, so it is the one same-file case without stale-Steps risk.

Rejected alternatives (solution-auditor pass, 2026-08-12):
- Done-time clobber detection: opposes D22 (reject shard output, not executor
  mess), fires after a burned session, fuzzy attribution. Parked as KIV; revisit
  only if fix-task overlap is seen in practice.
- `overlap_ack:` frontmatter marker: unbacked self-attestation (cf. D30), adds
  schema surface for a false positive D18 already makes harmless.
- WARN severity tier: breaks the binary LINT grammar for weaker enforcement.
- FAIL only when the shared path is not also `protected`: unsafe - `protected`
  does not make a write additive, and D30 dual-lists self-authored tests in both
  lists, so the predicate would wave through the exact clobber shape.

Source: analysis session 2026-08-12 + solution-auditor.

## Rejected (do not reopen without new facts)

- **A2A protocol** - enterprise HTTP mesh; harness apps don't speak it.
- **DB-as-store / webapp-as-store** - split-brain, sandbox friction, critical-path and bootstrap failures (see D3).
- **Folder-per-status-explosion** (review folders, per-plan folders) - coarse status = folder, fine status = control plane later.
- **Fork superpowers into the plugin** - drift, double maintenance (see D5).
- **Auto-reclaim stale tasks by timeout** - corrupting failure mode (see D12).
- **Symlinked skills across harnesses** - Windows + git symlink reliability (see D6).
- **Protocol-as-prose in RUNNER.md** - superseded by D17 after the review panel; violated our own D10.
- **Executor-authored review tasks** - superseded by D19; weak model writing for a strong consumer behind a droppable conditional.
- **Uncapped review loop** - superseded by D11 amendment; money pump.
- **Drain mode (in-session task draining)** - dilutes the fresh-context
  guarantee and makes review self-review; superseded by subagent-per-task
  dispatch (D31).

## KIV (revisit later, do not delete)

- CLI harnesses (claude -p / codex exec, Kimi-class CLIs) and programmatic dispatch - blocked by D16 until a CLI exists on the box.
- Git worktree per executor for true concurrency (D18).
- Vibe Kanban (too heavy), beads (git-backed issue DB) as prior art.
- App-backed MCP for human/orchestrator queries (v2+).
- External code-node verification with session-ID route-back (v3, requires programmatic dispatch).
- Done-time / executor-stage commit_path clobber detection (D32 alternative) - only if fix-task overlap is observed in practice.

## Sources

- Context rot: https://research.trychroma.com/context-rot
- Claude Code plugins: https://code.claude.com/docs/en/plugins
- Codex skills discovery (.agents/skills): https://learn.chatgpt.com/docs/build-skills
- Codex sandbox network default-deny: https://developers.openai.com/codex/agent-approvals-security
- Evaluator-optimizer pattern: https://www.anthropic.com/engineering/building-effective-agents
- ADW / code-over-agents framing: docs/videos/loop-engineering-vs-ai-developer-workflows.md
- Adversarial review panel findings: session 2026-08-07 (4 subagents: solution-audit, mechanics red-team, weak-executor attack, economics skeptic)
