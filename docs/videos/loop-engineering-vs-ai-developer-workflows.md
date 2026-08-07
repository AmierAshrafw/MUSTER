# Loop Engineering vs AI Developer Workflows (IndyDevDan)

Reference summary of the IndyDevDan video arguing against the term "loop engineering".
Written so future agents can use this file instead of watching the video.

## Core thesis

"Loop engineering" is a bad rebrand of the software development life cycle.
The correct mental model: build **AI Developer Workflows (ADWs)** inside a **software factory**.
Prompts go into the factory, a specific workflow runs (code + agents), results come out.

If loops deserved their own "engineering" label, so would every control-flow construct:
condition engineering, function engineering, exception engineering. It never ends.
A loop is one small piece of a workflow, not the whole picture.

## The three actors of value creation

1. **Engineers** - plan and review. Show up at the start (prompting/planning) and the end (reviewing/validation).
2. **Agents** - execute work. Least reliable of the three.
3. **Code** - deterministic steps. Fast, runs the same way every time, costs zero tokens, no hallucination.

Reliability order: code > engineers > agents.
Code is the unsung hero. Knowing when and where to place each actor is the whole game of agentic engineering.

## Workflow progression (simple to factory)

Each stage builds on the last. Start simple, scale up.

1. **Baseline**: engineer prompts an agent, engineer reviews the result. Foundation of everything.
2. **Add deterministic code**: a linter with a pass/fail condition. Fail routes output back into the build agent. This condition + route-back is the "loop".
3. **More code nodes**: formatter, type checker, tests. All route failures back to the build agent until everything passes, then engineer reviews.
4. **Test agent**: collapse all validation (lint, types, tests) into one dedicated test agent. "Scale your compute to scale your impact. Add compute to add confidence."
5. **Add planning**: plan, build, test, review, ship. Same steps engineers always did by hand, now with AI in the nodes.
6. **Git worktrees**: isolation + parallelism so agents don't trip over each other. A deterministic script spins up worktrees from a prompt, agents run in parallel. "A great place to start, not a great place to end."
7. **Agent sandboxes**: the upgrade over worktrees. Every agent gets its own computer/environment. Full isolation. Engineer can jump into the sandbox to inspect work, then merge and ship. Prediction: agent sandboxes will be the majority of computers.
8. **Kanban queue**: tickets from support, product, engineering flow in. Code moves the ticket through states. Scout agent gathers code/docs/prior specs, hands off to a plan agent, then build agent, then test agent, then CI/CD (fail routes back to build), then engineer review, then ship. Advanced teams skip the engineer-translates-ticket-into-prompt step if tickets are written well.
9. **Hotfix ADW** (production-down scenario): support ticket hits Slack/Teams, engineer prompts a scout agent that routes into a specialized hotfix agent. The hotfix agent is an "agent expert" - templated engineering, prioritized for speed over elegance. Human approves or rejects the proposed fix. On approval, multiple sandboxes race the fix in parallel; first passing solution wins. Engineer validates, ships.
10. **Software factory**: a routing system dispatches tickets to specialized ADWs (chore, bug, feature, hotfix). A factory router agent (or plain code) intakes the ticket, inspects the codebase, picks the right workflow at the right price/performance/speed. Cheap workhorse models for chores; state-of-the-art models for scouts and planners so nothing gets missed. Best teams eventually drop engineer review for trusted workflows (zero-touch engineering).

## Agentic layer vs app layer

- The **app layer** is for agents. The **agentic layer** (agents, prompts, skills, system prompts wrapping the application) is where engineers focus.
- Best teams do meta work: "build the system that builds the system."
- Contrast with vibe coding: vibe coding is not knowing how the system works. Agentic engineering is knowing your system works so well you don't have to look.
- Your expertise is your most valuable asset. Template it into ADWs and a repeatable workflow delivers consistent results hundreds or thousands of times.

## How to build great ADWs (his three recommendations)

1. **Keep it simple.** Start with the simplest workflow: build agent + linter. Use an agent SDK: run the build agent, run the linter as code, on failure pass results back to the build agent with the same session ID. Do NOT bury `run lint` at the bottom of a skill - that is still the agent running code, not separation of concerns. Separate agents and code all the way through. Skill-based all-in-one workflows are fine for starting, but productionizing requires pulling code out of skills (testing and validation of a 100-node skill is a nightmare).
2. **Do the work yourself first.** Before automating a workflow, run it end to end manually (agent-assisted is fine). Step into each node, run each condition, do the review, do the ship. Then write it down as a diagram (he uses mermaid) before building.
3. **Use agents AND code, not just agents.** Move skill work into code as you approach production. Not only for token cost: code wins on performance, reliability, speed. Classic engineering patterns matter more than ever (isolatable, decoupled, single interface) because every node transition (plan-to-build, build-to-test, fail routing) must be testable. Agents + code beats either alone.

## Key terms

- **ADW (AI Developer Workflow)**: a workflow combining engineers, agents, and code to push engineering work end to end.
- **Software factory**: routing system + collection of specialized ADWs that operates the application, ideally better than the engineering team alone.
- **Agentic layer**: the prompts, agents, skills, and system prompts wrapping the app. Where engineering effort goes.
- **Agent expert**: a specialized agent with templated domain expertise (e.g. the hotfix agent), outperforming out-of-the-box agents.
- **Two constraints of agentic engineering**: planning (prompting) at the start, reviewing (validation) at the end. Engineers own both.
- **Scale compute to scale impact**: add agents/parallelism to add confidence and throughput.

## Source

- Video: "forget loop engineering" style essay by Dan Eisler (IndyDevDan), ~34 min.
- Context: response to "loop engineering" framing from AI engineers at Anthropic/OpenAI.
- Related: his course Tactical Agentic Coding (agenticengineer.com), blog post "Thinking in Threads".
