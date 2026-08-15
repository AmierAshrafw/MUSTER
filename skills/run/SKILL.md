---
name: run
description: MUSTER executor session entry. Slash-only (/muster:run); do not auto-trigger.
---

Board detection: if `.muster/` exists at the repo root this is a v2 board -
run `muster claim -harness claude -tier any`, then follow `.muster/RUNNER.md`
to the letter.

Otherwise (v1 board): run
`powershell -ExecutionPolicy Bypass -File tasks/bin/claim.ps1 -Harness claude -Tier any`
(POSIX: sh tasks/bin/claim.sh --harness claude --tier any), then follow
tasks/RUNNER.md to the letter.
