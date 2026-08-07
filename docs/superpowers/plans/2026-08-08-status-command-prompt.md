# muster:status session prompt

Session prompt for adding a read-only board-status command.
Paste this into a fresh Claude Code session in this repo.

---

Add a `/muster:status` command: a read-only, one-line way for the human or
orchestrator to see board health between dispatches. Today the status block only
prints inside executor sessions (claim step 2), so outside a dispatch you have to
eyeball five folders; STALE and DEAD detection never runs. This closes that gap.
Discussed and agreed: name is `status` (matches the `MUSTER status @` header), not
`view`.

Ground everything in the repo first. Read: docs/superpowers/specs/2026-08-07-muster-v1.md
section 8.3 (status block format - already implemented, do not redesign it),
runtime/bin/promote.ps1 (the thin-wrapper pattern to copy), runtime/bin/claim.ps1
and claim.sh (how they call the status printer), and tests/MusterFixture.ps1
(fixture + MUSTER_ENGINE switch).

The print logic already exists in both engines - reuse it, never duplicate it:
- ps1: `Get-StatusBlock -RepoRoot $root -TasksRoot $tasks` in runtime/bin/_lib.ps1
- sh: `status_block "$root" "$tasks"` in runtime/bin/_lib.sh

Scope, pinned:

1. `runtime/bin/status.ps1` and `runtime/bin/status.sh` - thin wrappers in the
   promote.ps1 style: locate the repo root the way the other verbs do, call the
   lib function, print, exit 0. Strictly read-only: no promote run, no renames,
   no commits, no writes of any kind. Exit 1 with a `MUSTER refuse:` line only if
   not inside a git repo or tasks/ is missing. The empty-board line is already
   handled by the lib function.
2. `skills/status/SKILL.md` - wrapper skill in the run/review style. Frontmatter
   description must carry the same anti-trigger wording as the other five skills
   (invoked ONLY by the explicit /muster:status slash command, never auto-triggered
   by conversational mention of status, boards, or progress). Body: run
   `powershell -ExecutionPolicy Bypass -File tasks/bin/status.ps1`
   (POSIX: `sh tasks/bin/status.sh`), report the output verbatim, change nothing.
   No identity flags - the script takes none.
3. Tests: `tests/Status.Tests.ps1` using the existing fixture. Cover at least:
   empty board line; populated board shows correct counts and ids; STALE marker on
   an old claimed_at; DEAD marker on a backlog task behind a failed dependency;
   read-only guarantee (git log unchanged and worktree clean after a run). Run the
   suite under both engines (default, then MUSTER_ENGINE=sh) - all green, and the
   two engines must print identical status output for the same fixture.
4. Docs and manifests: add the command to README.md Usage (one bullet, orchestrator
   side, read-only); update the skills list in .claude-plugin/plugin.json and
   marketplace.json descriptions ("Skills: init, shard, run, review, close,
   status"); bump plugin version 0.1.0 -> 0.2.0. Note the addition in
   docs/decisions.md as a new numbered decision (post-v1, additive, read-only -
   rationale: DEAD/STALE detection is logic a human will not run by hand).

Out of scope: any change to the status block format itself, to claim's status
print, to RUNNER.md (executors never call status), or to the v1 spec document.
muster:init needs no edit - it already copies every file in runtime/bin/, so the
new scripts ship automatically.

Follow the repo's existing conventions for commits (conventional subjects, no
Co-Authored-By trailer, no agent name). Suggested shape: one feat commit for
scripts + skill + tests, one docs commit for README/decisions/manifests - or a
single feat commit if the diff stays small. Verify the full suite on both engines
before claiming done.
