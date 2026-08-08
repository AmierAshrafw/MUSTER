# Board-visibility discussion prompt

Session prompt for discussing (not building) how a human sees MUSTER board state.
Paste this into a fresh Claude Code session in this repo. This is a discussion
starter, not approval to build anything.

---

Discussion topic: how does a human know what is on the MUSTER board?

The observation, neutrally stated: board state lives in the `tasks/` status
folders, and the status block (spec section 8.3 - counts per folder, STALE marker
on old claims, DEAD marker on backlog stuck behind failed work) prints only inside
executor sessions, as part of claim. Between dispatches, a human or orchestrator
session inspects folders directly. Whether that is a problem worth solving, and if
so how, is exactly what this session is for - it was raised as a question, not a
requirement.

Ground yourself first: read docs/problem.md, docs/architecture.md (including the
control-plane section), docs/superpowers/specs/2026-08-07-muster-v1.md sections 1,
4, and 8, and skim how the existing scripts and skills are put together.

Then run this as an open discussion with the user (superpowers:brainstorming fits).
Things the discussion should genuinely weigh, without a predetermined answer:

- Is folder inspection actually insufficient? For whom, and in which moments?
- The full option space, including at least: do nothing (ls + git log is enough);
  documentation only (teach the inspection patterns in README or RUNNER-adjacent
  docs); a script; a skill; wait for the v2 control-plane viewer which was always
  the designed answer to visibility; or something not listed here.
- Costs as well as benefits: every added command is surface to maintain, test on
  two engines, and guard against auto-triggering; v1 just shipped and its scope
  was deliberately tight.
- If a new mechanism does come out on top: what it should be called, what exactly
  it shows, and where its logic should live are design questions to settle in the
  discussion, not assumptions to inherit.

Do not write code or task files in this session. The end state is a recommendation
the user has explicitly agreed with - which may well be "change nothing" - and, only
if the user says so, a follow-up plan through the normal superpowers flow.
