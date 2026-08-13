---
name: shard
description: Convert an approved plan into MUSTER task files. Slash-only (/muster:shard), after approval; do not auto-trigger.
---

# muster:shard - approved plan -> task files

Input: the user names an approved plan file and a plan id (kebab-case, `[a-z0-9-]+`,
unique - refuse if `tasks/plan-<id>.md` already exists). Do all thinking NOW: executors
get zero judgment calls (D9).

## Snapshot

1. Copy the plan file verbatim to `tasks/plan-<id>.md`. Tasks quote the snapshot, never
   the live plan (D23).

## Author tasks

2. Decompose the plan into small impl tasks in DAG order; assign `seq` 01 upward.
   Every task gets the impl template (`${CLAUDE_PLUGIN_ROOT}/templates/impl-task.md`),
   every `{brace}` slot filled:
   - Context: INLINE every excerpt the executor needs. Pasting is correct; pointing
     is a lint reject (D23).
   - Steps: target-state phrasing, exact paths, exact content (D12, D9).
   - verify: network-free commands, tokenizable (no shell metacharacters), each with
     expect_exit and/or expect_contains. Needs network? Pin `harness: claude` (D16).
     Windows caveat: the verify runner spawns processes directly, so extension-less
     `.cmd`/`.bat` shims (npm, yarn, ng) fail to launch - front them with the cmd
     host, e.g. `cmd /c npm test`.
     PowerShell caveat: `powershell -Command` re-joins its trailing argv tokens
     with spaces AFTER argv parsing has consumed the double quotes, so a quoted
     multi-word argument (`-Pattern "two words"`) reaches PowerShell unquoted and
     binds as stray positional args (observed: overlap-lint-07-docs terminal
     fail, 2026-08-13). Keep every token after `-Command` single-word - for a
     multi-word regex put `\s` in place of each space (one token, no quotes).
     Wrapping the whole script as ONE quoted token also executes correctly but
     passes lint only on review/integration tasks: check 5 scans impl/fix
     tokens containing `/` against protected/commit_paths, and a whole-script
     token never matches a listed path.
   - depends_on: `[]` when empty, block list (`  - <id>` per line) otherwise -
     never a non-empty inline list (Authority deviation 3).
   - protected: every file a verify cmd reads that the task must not touch. A
     test the task itself authors and is graded by is dual-listed - here AND in
     commit_paths (D30): protected freezes it for downstream consumers,
     commit_paths lets this task create it past the scope check. A test that
     already exists and this task only runs is protected alone.
   - commit_paths: the exact stage list for the completion commit (D21) -
     include any self-authored test that is also protected.
   - tier: `any` unless the task itself needs judgment.
3. Review tasks (opt-in per impl task, D10): for each impl task worth reviewing, emit
   a review task from the review template with `reviews: <impl-id>`,
   `depends_on` as a block list holding `<impl-id>` (never the inline form - lint
   rejects it, see step 2), `tier: strong`, and the fix template pasted into its
   Steps (the reviewer never opens plugin files). Anything downstream of a reviewed
   task depends on the REVIEW id, not the impl id (D19).
4. Terminal integration task, always (D24): seq `99`, integration template,
   `tier: strong`, `depends_on` listing every other task id in the plan, full
   build + suite in verify.
5. Write ALL task files into `tasks/backlog/`.

## Gate and land

6. Lint the whole batch:
   `powershell -ExecutionPolicy Bypass -File tasks/bin/lint.ps1 tasks/backlog/<plan-id>-*.md`
   Any `LINT FAIL` = fix the task files and re-lint. Landing an unlinted batch is
   forbidden; if a finding cannot be fixed, delete the batch (the files are untracked)
   and report why.
7. On `LINT OK`: commit snapshot + batch, explicit paths, message
   `muster(<plan-id>): shard <n> tasks`.
8. Run `powershell -ExecutionPolicy Bypass -File tasks/bin/promote.ps1` - tasks with
   no dependencies move to inbox/ and get committed as `muster: promote <n>`.

## Report

9. Print: task count by type, the DAG (id -> depends_on), and the dispatch reminder
   (Sonnet 5 + `/muster:run` per impl task; Opus 4.8 + `/muster:review` when a review
   task is ready).
