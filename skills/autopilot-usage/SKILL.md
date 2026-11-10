---
name: autopilot-usage
description: Check the remaining quota of every AI coding harness and account registered in the linear-autopilot roster (Codex, Claude, opencode, Cursor, Grok, Gemini, Antigravity, ...), the cooldowns, the exact reset times, which pools can run right now, and the total tokens consumed per harness and account over the past days, months or years (chart in the terminal or an HTML page). Use at any time when the user asks "how much quota is left", "which models are available", "/autopilot-usage", "are we rate limited", "how many tokens did we use", "token usage per harness", or before deciding which tier to spend on a task.
---

# Autopilot: usage

`bin/<x>` below means the `bin` directory next to this SKILL.md (`~/.claude/skills/autopilot-usage/bin/<x>` after `install.sh`, `${CLAUDE_PLUGIN_ROOT}/skills/autopilot-usage/bin/<x>` as a plugin). Needs the roster from `/autopilot-init`.

## Commands

| Command | What it tells you |
|---|---|
| `bin/run-model usage` | Per harness and account: each quota window, percent used, reset time, and when the reading was observed. Read without spending model quota (Claude and Antigravity `/usage`, the rate limits Codex writes in its session logs). A harness without a probe, a failed probe or an unparsable answer shows one `unknown` window with the diagnostic: never a silent blank. |
| `bin/run-model usage --apply` | Same, and cools down every model whose window is at 100% until its exact reset, and clears a stale quota cooldown when the probe shows the account is back under quota. A Codex account whose WEEKLY window is at 100% gets its reset claimed first (see `codex-reset` below). A 100% reading observed before a successful run or smoke of the account is stale (Codex session logs keep the old numbers after a reset): it is skipped, listed in `stale_readings_skipped` and said on stderr, never re-applied. Ends with the CRITICAL check (see `bin/alert`). Run it before dispatching anything expensive and on every heartbeat of a run. |
| `bin/run-model health` | Current cooldowns: key, until, reason (quota, timeout, bad output). |
| `bin/harness list` | The roster with tier, vendor, account, subscription, roles and health in one table. `bin/harness check`: per role, the candidates with tier, account, subscription, health and credit left, then what is missing. |
| `bin/run-model wait <role> [EXCLUDE,...]` | Blocks until a model of the role's tier is healthy and prints its key (background job). `bin/run-model pool <role>` shows the current draw. |
| `bin/run-model reset <key>` then `bin/run-model smoke <key>` | Clear a cooldown the user says is stale, and verify. |
| `bin/codex-reset [--account CODEX_HOME=~/.codex-x]` | Lists the Codex usage resets available on that account; `--yes` redeems one, only when that account's weekly window is at 100% in a fresh reading. Authorized durably by the owner: `run-model` runs it by itself (`usage --apply`, or a run that hits its quota), once per account per weekly window, then smoke-tests the account and clears its cooldowns; attempts and results are in `models.json` `resets`. `"codex_auto_reset": false` in `models.json` turns that off. A 5-hour limit never spends a reset. |
| `bin/alert list` / `bin/alert ack <ID\|all>` | CRITICAL alerts: a vendor out of quota on every account once the resets were tried (none left, failed, or auto-reset disabled), or a role (implement, review, plan_review, premortem, milestone_review) with no eligible model. Each names the accounts, the reset results, the blocked pools and the earliest reset; it is also a Linear project update. Report any unacknowledged one to the user first, then `ack` it. `bin/run-model alerts` recomputes them now. |
| `bin/tokens [--period 7d\|12w\|12m\|5y\|all] [--by account\|harness] [--models] [--html PATH] [--json]` | Total tokens that went through every connected harness and account (every account found on disk, in the roster or not), from the logs the CLIs keep locally: nothing is run, no quota is spent. One stacked bar per day (7d), week (12w), month (12m) or year (5y); `all` = 7d + 12m + 5y. Each bar is split per harness and account: the accounts of one CLI share a hue (`codex`, `codex-b`, `codex-c` are three shades and three glyphs of the same blue; `claude`, `opencode`, ... have their own hues). Then the total on the period and the breakdown per account (input, of which cached, output, total, share), `--models` adds the split per model id. `--html PATH` writes a self-contained page with the three charts, hover tooltips, light and dark mode, and the tables. Codex, Claude Code, opencode, Grok, Antigravity and Gemini CLI log their counts; Cursor and Vibe do not (the sources table says so). First run indexes every log (a few seconds per GB), later runs use the cache. |

## Token report: how to read it

- `input` counts everything sent to the model, the cached part included; `cached` is that part; `output` counts everything generated, reasoning included; `total` = input + output. These are the CLIs' own counts, not an invoice: on subscriptions they measure context churn, and the cached share tells how much of it was cheap.
- Report the total on the period, the three biggest accounts with their share, and the output tokens (the number that tracks actual work), then one line on what it suggests: an account far ahead of the others is a candidate for load spreading (`/autopilot-init` adds accounts), a large uncached input share on one harness means its sessions restart too often.
- When the user wants the page: `bin/tokens --html ./tokens.html` and open it (`open` or `xdg-open ./tokens.html`); it is static, self-contained, and can be regenerated any time.

## How to report

One table, then one line of advice:

| Harness / account | Window | Used | Resets | Roles affected |
|---|---|---|---|---|

Then, per role (README, Tiers): does Tier 3 have a healthy model (implementation), Tier 2 (reviews), Tier 1 of another vendor than the coordinator (plan reviews, pre-mortems); how much credit is left on each paid subscription and when it resets (credit unused at the reset is lost: the draws already favour the accounts with the most credit left); how close the coordinator's own account is to its reserve (`coordinator_reserve`); the next reset worth waiting for, and anything the probes cannot see (ask the user to read `/usage` in that CLI's interactive session once and set the cooldown with the time it shows).

## Rules

- A CRITICAL alert (`bin/alert list`, or `CRITICAL:` lines at the top of `bin/eta`) goes first in the report, with what it blocks and the reset times.
- Never guess a reset time: parse it (`usage`) or ask. A cooldown without a known reset lasts 60 min and is retried.
- Never spend a model to check whether it works when its CLI already announced a reset time: schedule a `wait` instead.
- Use every included quota to the max, never pay more: no extra credits, no top-ups, no paid per-token ids. A tier out of quota waits for its reset; it is never replaced by another tier.
