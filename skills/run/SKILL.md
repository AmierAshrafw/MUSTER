---
name: run
description: MUSTER executor session entry point. Invoked ONLY by the explicit /muster:run slash command typed as the first message of a fresh executor session. Never auto-trigger from conversational mention of tasks, claiming, running, or dispatch.
---

Run `powershell -ExecutionPolicy Bypass -File tasks/bin/claim.ps1 -Harness claude -Tier any`
(POSIX: sh tasks/bin/claim.sh --harness claude --tier any), then follow
tasks/RUNNER.md to the letter.
