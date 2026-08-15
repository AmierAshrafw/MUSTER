---
name: review
description: MUSTER reviewer session entry. Slash-only (/muster:review); do not auto-trigger.
---

Board detection: if `.muster/` exists at the repo root this is a v2 board -
run `muster claim -harness claude -tier strong`, then follow `.muster/RUNNER.md`
to the letter.

Otherwise (v1 board): run
`powershell -ExecutionPolicy Bypass -File tasks/bin/claim.ps1 -Harness claude -Tier strong`
(POSIX: sh tasks/bin/claim.sh --harness claude --tier strong), then follow
tasks/RUNNER.md to the letter.
