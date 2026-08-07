---
name: review
description: MUSTER reviewer session entry point. Invoked ONLY by the explicit /muster:review slash command typed as the first message of a fresh reviewer session. Never auto-trigger from conversational mention of reviews, verdicts, or dispatch.
---

Run `powershell -ExecutionPolicy Bypass -File tasks/bin/claim.ps1 -Harness claude -Tier strong`
(POSIX: sh tasks/bin/claim.sh --harness claude --tier strong), then follow
tasks/RUNNER.md to the letter.
