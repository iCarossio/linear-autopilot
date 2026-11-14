---
name: autopilot-status
description: Show every model configured in the linear-autopilot roster with its subscription and the share of quota already consumed, per window (short-term 5h/session, weekly, monthly) and when each window resets, for every supported harness (Claude Code, Codex, pi, opencode, Grok, Antigravity, Vibe). Use when the user asks "/autopilot-status", "which models are configured", "how much quota is used per model", "when does it reset", "what subscription is each model on".
---

# Autopilot: status

**Caveman, always.** Your first action: invoke the `caveman` skill and keep it for the whole session (again after a resume or compaction). If it is not installed, follow its rules anyway: answer first, no ceremony, commands, paths, numbers and errors verbatim.

`bin/<x>` is the `bin` directory next to this SKILL.md (`~/.claude/skills/autopilot-status/bin/<x>` after `install.sh`). Needs the roster from `/autopilot-init`.

## Command

`bin/run-model status` (add `--json` for machine reading). One row per configured model: key, harness, account and plan, subscription (`paid`, `free`, `reserved`, ...), then three columns: short-term window (5 h / session / rolling), weekly window, monthly window, each as `percent used -> reset time (in Xd Yh)`. `-` = this plan has no such window. Probes spend no model quota (Claude and Antigravity `/usage`, Codex session logs, OpenCode Go limits for opencode and pi, Mistral billing for Vibe). A harness whose probe fails shows a `note:` line with the diagnostic, never a blank; `STALE` marks a 100% reading older than a successful run; a model in cooldown shows `COOLDOWN until ...`.

Accounts of the same CLI and models of the same account share their windows (every OpenCode Go model reads the same allowance; Claude has per-family weekly windows, shown under `also:`).

## How to report

Show the table as printed, then at most three lines: any window at 90% or more with its reset, any model with no reading (and the note), any cooldown. Token consumption is `/autopilot-usage`.

## Other quota commands (on request)

| Command | Does |
|---|---|
| `bin/run-model usage --apply` | Reads every probe, cools down each model whose window is at 100% until its exact reset, clears stale cooldowns, claims a free Codex weekly reset when one is due (`codex_auto_reset`), ends with the CRITICAL check. Run by `/autopilot-run` on every heartbeat. |
| `bin/run-model health` | Current cooldowns: key, until, reason. `bin/run-model reset <key>` then `smoke <key>` clears one the user says is stale. |
| `bin/harness check` | Per role: candidates with tier, account, subscription, health, credit left; then what is missing. |
| `bin/alert list` / `ack <ID\|all>` | CRITICAL alerts (a vendor out of quota everywhere, a role with no eligible model). Report any unacknowledged one first. |

## Rules

- Never guess a reset or a percentage: if the probe says unknown, say unknown.
- `bin/run-model status` is read only; only `usage --apply` and `reset` change state, and only when the user asks.
- Never buy credits or top up: a tier out of quota waits for its reset.
