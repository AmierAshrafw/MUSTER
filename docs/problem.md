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

The goal is a strong model (Fable 5, Claude Code) for planning and judgment, and the Codex app for execution.
The real economics are quota arbitrage: two flat-rate subscriptions, so execution load moves to the Codex quota and the Claude quota is reserved for judgment.
The two harnesses share no channel today except a human clipboard.

## 4. Task state dies with the session

When a session ends or crashes, the state of in-flight work goes with it.
There is no durable record of what was assigned, what finished, what failed, or why.

## What MUSTER solves

- Plans are sharded into small, self-contained task files sized for fresh contexts.
- The task file IS the prompt: written once by the orchestrator, read from disk by any executor. No copy-paste.
- Files are the interface both harnesses speak with zero config; protocol mechanics run as scripts, not prompts.
- Task state lives on disk inside the target repo: durable, git-versioned, human-inspectable.
- v1 dispatch is manual (human opens a session, types one line). Automation is the end-state, not the start.

## Constraint

Executors run only in the two desktop apps: Claude Code and Codex. No CLI harnesses on this machine.
Apps have no headless mode, so automated dispatch stays impossible until a CLI is ever installed.
PoC: Codex not installed yet - Claude Code desktop only, Fable 5 for judgment, Sonnet 5 for execution.

## Non-goals (v1)

- No automated session spawning (blocked by the apps-only constraint; KIV).
- No cloud queues. Local-only.
- No app or database in the agent critical path, ever.
