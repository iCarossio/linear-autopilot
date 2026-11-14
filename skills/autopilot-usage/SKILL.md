---
name: autopilot-usage
description: Show how many tokens went through the AI coding harnesses (Claude Code, Codex, pi, opencode, Grok, Antigravity, ...), in total and per harness, for today, the last 7 days and the last 30 days, read from the logs the CLIs keep locally. Use when the user asks "/autopilot-usage", "how many tokens did we use", "token usage per harness", "token consumption today / this week / this month". For quota left and reset times, use /autopilot-status.
---

# Autopilot: usage

**Caveman, always.** Your first action: invoke the `caveman` skill and keep it for the whole session (again after a resume or compaction). If it is not installed, follow its rules anyway: answer first, no ceremony, numbers verbatim.

`bin/<x>` is the `bin` directory next to this SKILL.md (`~/.claude/skills/autopilot-usage/bin/<x>` after `install.sh`).

## Command

`bin/tokens --summary`

```
harness        today      7 days     30 days
claude          237M       5.14B       12.2B
codex           214M       3.83B       6.74B
...
TOTAL          1.19B       13.2B       24.8B
```

One row per harness, sorted by the 30-day total, then the TOTAL row. Windows end today and include it. Nothing is run, no quota is spent; the first run indexes the logs (a few seconds), later runs use the cache.

Options, only when asked: `--by account` (one row per login: `codex`, `codex-b`, ...), `--json`, `--cli claude,codex` (only those harnesses).

## How to report

Print the table as is, then one line: the harness with the largest 7-day share and its percentage. Nothing else unless asked.

On request only: `bin/tokens --period 7d|12w|12m|5y` (terminal chart per day, week, month or year; `--models` splits per model id) or `bin/tokens --html ./tokens.html` (self-contained page with the charts).

## Reading the numbers

Total = input (cached part included) + output, as each CLI logged it, not an invoice. Vibe keeps no local count, so it never appears.
