---
name: autopilot-usage
description: Check the remaining quota of every AI coding harness and account registered in the linear-autopilot roster (Codex, Claude, opencode, Grok, Gemini, ...), the cooldowns, the exact reset times, and which pools can run right now. Use at any time when the user asks "how much quota is left", "which models are available", "/autopilot-usage", "are we rate limited", or before deciding which tier to spend on a task.
---

# Autopilot: usage

`bin/<x>` below means the `bin` directory next to this SKILL.md (`~/.claude/skills/autopilot-usage/bin/<x>` after `install.sh`, `${CLAUDE_PLUGIN_ROOT}/skills/autopilot-usage/bin/<x>` as a plugin). Needs the roster from `/autopilot-init`.

## Commands

| Command | What it tells you |
|---|---|
| `bin/run-model usage` | Per harness and account: each quota window, percent used, reset time, and when the reading was observed. Read without spending model quota (Claude and Antigravity `/usage`, the rate limits Codex writes in its session logs). A harness without a probe, a failed probe or an unparsable answer shows one `unknown` window with the diagnostic: never a silent blank. |
| `bin/run-model usage --apply` | Same, and cools down every model whose window is at 100% until its exact reset, and clears a stale quota cooldown when the probe shows the account is back under quota. Run it before dispatching anything expensive and on every heartbeat of a run. |
| `bin/run-model health` | Current cooldowns: key, until, reason (quota, timeout, bad output). |
| `bin/harness list` | The roster with cost tier, account, pools and health in one table. |
| `bin/run-model wait <pool> [EXCLUDE,...]` | Blocks until a model of the pool is healthy and prints its key (background job). |
| `bin/run-model reset <key>` then `bin/run-model smoke <key>` | Clear a cooldown the user says is stale, and verify. |
| `bin/codex-reset [--account CODEX_HOME=~/.codex-x]` | Lists the Codex usage resets available on that account; `--yes` redeems one, only with the user's permission for this session and only when that account's weekly window is at 100%. |

## How to report

One table, then one line of advice:

| Harness / account | Window | Used | Resets | Pools affected |
|---|---|---|---|---|

Then: which pools have at least two healthy vendors (reviews and pre-mortems are possible), which tier is cheapest to spend right now (e.g. "implement with the free pool, review with Codex Terra on account b and Grok"), the next reset worth waiting for, and anything the probes cannot see (ask the user to read `/usage` in that CLI's interactive session once and set the cooldown with the time it shows).

## Rules

- Never guess a reset time: parse it (`usage`) or ask. A cooldown without a known reset lasts 60 min and is retried.
- Never spend a model to check whether it works when its CLI already announced a reset time: schedule a `wait` instead.
- Use every included quota to the max, never pay more. Suggest the paid tier only when the user explicitly allows it for the session.
