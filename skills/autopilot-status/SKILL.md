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

Show the table as printed, then at most three lines: any window at 90% or more with its reset, any model with no reading (and the note), any cooldown. For the long view per role use `/autopilot-usage`.

## Rules

- Never guess a reset or a percentage: if the probe says unknown, say unknown.
- Read only: this skill changes nothing (use `/autopilot-usage` and `bin/run-model usage --apply` to apply cooldowns).
