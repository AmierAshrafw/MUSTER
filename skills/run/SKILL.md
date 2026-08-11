---
name: run
description: MUSTER executor session entry. Slash-only (/muster:run); do not auto-trigger.
---

Run `powershell -ExecutionPolicy Bypass -File tasks/bin/claim.ps1 -Harness claude -Tier any`
(POSIX: sh tasks/bin/claim.sh --harness claude --tier any), then follow
tasks/RUNNER.md to the letter.
