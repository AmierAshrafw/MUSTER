# Problem

Four pains, one root: executing a whole plan in one long AI session does not scale.

## 1. Context rot

Executing a multi-step plan in a single session balloons context, and quality degrades late-plan.
[Context rot research](https://research.trychroma.com/context-rot) (Chroma, 18 frontier models) shows accuracy drops 30-50% well before documented context limits.
Claude Code auto-compacts around 167k tokens on a 200k window, which discards working state mid-plan.

Adopted rule: size each task to finish under ~50% of the context window (~100k tokens).
A fresh session per task is the only reliable way to guarantee that.

## 2. Manual prompt ferrying

The current workaround is copy-paste dispatch.
The orchestrator session writes a prompt, the human pastes it into an executor session, then pastes results back.
Tedious, error-prone, and nothing is recorded anywhere.

## 3. Model-cost tiering has no mechanism

The goal is a strong model (Fable 5) for planning and judgment, and cheap models (Kimi, other CLIs) for execution.
Those executors live in different harnesses with different capabilities.
There is no shared channel to hand work across harnesses today except a human clipboard.

## 4. Task state dies with the session

When a session ends or crashes, the state of in-flight work goes with it.
There is no durable record of what was assigned, what finished, what failed, or why.

## What MUSTER solves

- Plans are sharded into small, self-contained task files sized for fresh contexts.
- The task file IS the prompt: written once by the orchestrator, read from disk by any executor. No copy-paste.
- Files are the interface every harness speaks with zero config, so any model in any CLI can execute.
- Task state lives on disk inside the target repo: durable, git-versioned, human-inspectable.
- v1 dispatch is manual (human opens a session, types one line). Automation is the end-state, not the start.

## Non-goals (v1)

- No automated session spawning (claude -p / codex exec is a KIV branch).
- No cloud queues. Local-only.
- No app or database in the agent critical path, ever.
