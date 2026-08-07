# Architecture (high level)

Two planes. Agents touch files only. The app watches; it never gates.

```
ORCHESTRATOR (strong model, Claude Code)          EXECUTOR (any harness, any model)
  superpowers: brainstorm -> plan                   open session IN target repo
  muster:shard  plan -> task files                  one line: follow tasks/RUNNER.md
        |                                                 |
        v                                                 v
  ================= DATA PLANE (target repo, files) =================
  tasks/backlog/   tasks/inbox/   tasks/doing/   tasks/done/   tasks/failed/
  ====================================================================
        ^
        | ingest (read-side, later)
  CONTROL PLANE (v2+): ASP.NET + SQL Server viewer/registry/review dashboard
```

## Data plane

Task files live inside the target project's repo under `tasks/`, in maildir-style status folders:
`backlog/` (blocked by dependencies), `inbox/` (ready to claim), `doing/`, `done/`, `failed/`.

- Claim = atomic file move (rename) into `doing/`. Empty inbox = nothing pending.
- Single writer per transition: shard writes backlog/inbox; the executor owns inbox -> doing -> done/failed.
- Executor's final act on completion: scan `backlog/`, move any task whose `depends_on` are all in `done/` into `inbox/`.
  Completion is the only event that unblocks work, so the finishing executor is the natural promoter.
- The executor appends a `## Result` section to the task file before moving it: status, files touched, commits, how verified, surprises.

## Task files

The task file is the prompt, pre-written by the orchestrator and stored on disk.

**Weak-executor principle:** the orchestrator does all thinking at shard time.
Tasks carry explicit steps, exact file paths, acceptance criteria, and verification commands.
The executor gets zero judgment calls. Cheap models are the design target.

Tasks are self-contained for the actionable part and reference the plan file for cross-task context (reference, don't duplicate).

## Verification: two tiers

Reliability order: code > engineers > agents (see docs/videos/loop-engineering-vs-ai-developer-workflows.md).

- **Tier 0 - deterministic verify (mandatory, every task).**
  Each task carries a `verify` block: runnable commands with expected results.
  The executor loops: run verify, on fail fix and rerun, capped at 3 attempts, then move to `failed/` with command output in Result.
  Hard rule for the shard skill: no task is emitted without a machine-testable end condition.
  Genuinely un-machine-checkable work gets a weak verify plus a forced review flag.
- **Tier 1 - agent review (judgment, opt-in per task).**
  The orchestrator flags `review: required` at shard time, while it still has full plan context.
  On completion the executor mechanically generates a review task from a template into `inbox/`, pointing at the done task.
  Review tasks are pinned to a strong model. The reviewer only checks what code cannot test: spec adherence, design quality, side effects.
  Fail = reviewer creates a fix task pointing at findings; the fix carries `review: required` again, so the loop continues until pass.
  This is the evaluator-optimizer pattern (Anthropic, Building Effective Agents).

## Discovery and dispatch

- Canonical executor contract = `tasks/RUNNER.md` in the target repo: claim rules, budget rule, verify loop, promotion rule, report format.
  One plain file, so it works in every harness including skill-less CLIs.
- Thin skill wrappers point at it from each harness's native location:
  Codex repo skill in `.agents/skills/` (invoked `$muster-run`), Claude plugin skill (`/muster:run`).
  Wrappers are 3 lines and never change; the logic lives only in RUNNER.md.
- Executors always open INSIDE the target repo. No path lookup, no registry on the executor side, sandbox-safe.
- `muster:run` also prints stale `doing/` entries (claimed long ago, still unfinished). Detection is automated; recovery is human.

## Plugin (orchestrator side, Claude Code)

A thin layer over superpowers. Nothing in superpowers is copied or modified.

- `muster:init` - bootstrap a target repo: tasks/ folders, RUNNER.md, wrapper skills, pointer lines in CLAUDE.md / AGENTS.md.
- `muster:shard` - approved plan -> task files in backlog/inbox.
- `muster:run` - thin wrapper: follow tasks/RUNNER.md.

The opt-in fork happens at one point: plan approved, then either `superpowers:executing-plans` (small work, normal path) or `muster:shard` (big work).
Small tasks never touch MUSTER.

## Control plane (later)

ASP.NET + SQL Server app. Read-side only: ingests file state from `done/`, holds fine-grained statuses, project registry, dashboards, review queue.
Data flows files -> app (mirror), never app -> agents.
App down = agents keep working. The mirror can rebuild from files at any time; the reverse is impossible.
An app-backed MCP for human/orchestrator queries is a v2+ convenience, never an executor interface.

## Sequencing

- **v1** - file convention + plugin (init/shard/run) + manual dispatch. Zero app build. registry.json for the orchestrator only.
- **v2** - the ASP.NET viewer app, built THROUGH the pipeline as its first real project (dogfood).
- **v3** - app takes over promotion/ingestion richness, full review workflow, possibly programmatic dispatch (KIV: claude -p / codex exec) and verification pulled out of sessions into external code nodes.

## Open items (undesigned, on purpose)

- Task file schema: field list drafted, not finalized. Includes a `plan` field for grouping multiple task lists per project.
- RUNNER.md exact text.
- Task and review-task templates.
- registry.json shape.
- Dispatch UX wording (what the human types per harness).
- Final status list for the control plane.
