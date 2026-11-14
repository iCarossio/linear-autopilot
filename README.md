# linear-autopilot

Plan a software project adversarially, create it in Linear, then let a fleet of models implement it ticket by ticket, reviewed by other models, unattended, on the AI coding subscriptions you already pay for.

## Skills

Skills for Claude Code (or any harness that reads `~/.claude/skills`):

| Skill | When | What it does |
|---|---|---|
| `/autopilot-init` | once per machine | finds your CLIs and their accounts, asks which subscriptions you pay for, gives every model its tier, smoke-tests them, prints what each role can use and what is missing |
| `/autopilot-plan` | once per project | your plan and KPIs, a pre-mortem by a flagship of another vendor, guardrails, then the Linear project with milestones, tickets and dependencies |
| `/autopilot-milestone` | when the project grows | the same treatment for a new milestone of an existing project, from new scope or from parked ideas |
| `/autopilot-run` | per project, for hours | runs the tickets: plan, review the plan, implement, review the code, repeat until approved, one commit per ticket, Linear kept up to date |
| `/autopilot-continue` | after a session ends | resumes a run where it stopped, without setup questions |
| `/autopilot-idea` | any time | parks your quick ideas, verbatim, in an "Ideas (unscheduled)" milestone, out of every ETA, until you promote them |
| `/autopilot-status` | any time | every configured model, its subscription, the share of its 5-hour, weekly and monthly quota used, and when each resets |
| `/autopilot-usage` | any time | tokens consumed, in total and per harness, today, over the last 7 days and the last 30 days |

## Methodology

The autopilot exists because cheap models write good code when the work is planned well, cut small and checked by someone else, and because most subscriptions expire unused. Each rule below answers a way long agent runs fail.

- **Planning with the brain.** Thinking is done by the strongest models; typing by cheaper ones. A Tier 1 flagship (the coordinator) plans the project and writes every ticket's brief; Tier 2 models implement and review it. The brain never writes code, the hands never decide scope.
- **KPIs.** No plan starts without measurable expectations: each KPI has a target and a way to measure it (a command, a query, a count, a date). "Works well" is refused.
- **Definition of done.** Every ticket carries its acceptance criteria and its checks (`CHECKS:` line). Done means the checks pass, a reviewer approved with no blocking finding, and the work is one commit on the project branch.
- **Deadlines.** Every plan and milestone has a date. The ETA is a schedule of the remaining tickets (stages that run in parallel, one after the other), shown as one progress bar per milestone and mirrored on Linear.
- **Pre-mortem.** Before any ticket exists, a flagship of another vendor is told "we are at the deadline and the project failed: why?". Each reason becomes a guardrail: a KPI, a check, a ticket or a rule.
- **Adversarial review.** No model reviews its own work: the implementer of a ticket never reviews it, and the planner's vendor never reviews the plan. Enforced in code.
- **Measurable and atomic tickets.** One ticket is one concern, about 400 changed lines at most, one commit, with the files it touches declared so parallel tickets never collide. Bigger is split, tiny is grouped.
- **Model convergence.** A ticket loops implement → review → fix until the reviewer approves. After round 3 the implementer is escalated (a fresh Tier 2 model, or one tier up for a project pinned to Tier 3) instead of looping on the same mistakes. A review counts only if it parses, did not touch the code, and an "approve" carries no blocking finding.
- **Long autonomous sessions.** A run lasts hours with you away. State lives on disk and in Linear, not in the conversation, so a new or compacted session resumes exactly (`/autopilot-continue`). Every change of plan is logged with its source (`bin/decision`). You are interrupted only for a CRITICAL alert.
- **Spend what you pay for, never more.** Inside a tier, models are drawn by the credit left on each subscription, so every plan is used before its reset. Quota resets are reused the minute they happen; credits are never bought.

## Tiers

The owner's tier table (`DEFAULT_TIER_TABLE` in `bin/autopilot_lib.py`, overridable in `models.json`) gives every model a level:

| Tier | Examples | Role |
|---|---|---|
| 0 frontier | Claude Fable, GPT-6 Astra, Gemini 4 Carbon | never automatic; only with `--allow-tier0` |
| 1 flagship | Claude Opus, GPT-6.1 Sol, Gemini 4 Argon, GLM-5.3, Kimi K3 | coordination, plan reviews, pre-mortems, milestone reviews; backup code reviewer |
| 2 balanced | Claude Sonnet, GPT-6.1 Terra, Gemini 3.8 Flash, Grok 4.7, DeepSeek V4.1 Flash | implement and review tickets (never the same model on one ticket) |
| 3 fast | Claude Haiku, GPT-6 Luna, Gemini 3.5 Flash-Lite | implementation, only in a project pinned to it |
| 4 small | Mistral, free models | trivial tasks only |

Rules enforced in code:

- **Roles keep their tier.** A tier out of quota waits for its reset; it never silently falls to another. One exception: when no Tier 2 reviewer is eligible, the code review falls back to Tier 1 (logged).
- **Weighted draw.** A role's model is drawn at random among its tier, weighted by credit left, subscription (paid, unconfirmed, free) and an optional per-model `capacity` (overridable per project in `state.json`).
- **Vendor's own CLI.** Anthropic through Claude Code, OpenAI through Codex, Google through Antigravity, Mistral through Vibe, xAI through Grok; other vendors through pi (OpenCode Go) or opencode (free models).
- **No speed variants.** `-fast` variants cost more for the same quality and are refused (Flash and Flash-Lite are families, not speed variants).
- **The coordinator's account is protected.** Detected at run time; models on it run last, for cheap roles only, while it keeps a reserve (30% of the 5-hour window, 20% of the weekly one).
- **Latest versions.** `run-model discover --apply` (daily) finds newer model ids, smoke-tests them and switches the roster.

`bin/harness check` shows, per role, the candidates and what is missing.

## Supported harnesses

One JSON adapter per CLI in `harnesses/`. Several logins of one CLI are several accounts, each with its own quota.

| Harness | CLI | Accounts | Quota probe | Token log |
|---|---|---|---|---|
| Claude Code | `claude` | `CLAUDE_CONFIG_DIR` | `/usage` | yes |
| OpenAI Codex | `codex` | `CODEX_HOME` | session logs | yes |
| Google Antigravity | `agy` | one | `/usage` | yes |
| xAI Grok | `grok` | `GROK_HOME` | `/usage` | yes |
| pi (OpenCode Go) | `pi` | `PI_CODING_AGENT_DIR` | OpenCode Go limits | yes |
| opencode | `opencode` | `XDG_DATA_HOME` | none | yes |
| Mistral Vibe | `vibe` | one | billing | no |

Add any other CLI with a non-interactive mode with `bin/harness new` (see `/autopilot-init`).

## Under the hood

- **Pipeline.** `bin/pipeline` moves every in-flight ticket on by itself (implement, rebase, checks, review, next round) in parallel git worktrees; the coordinator only merges approvals (`bin/pipeline merge`).
- **Milestones and ETA.** `bin/milestone` and `bin/eta`: one progress bar and ETA per major milestone, synced to Linear.
- **Decision log.** `bin/decision`: every change of plan, with its source, in `PLAN.md`.
- **Alerts.** `bin/alert`: CRITICAL alerts (a vendor out of quota everywhere, a role with no model), also posted on the Linear project.
- **Quota recovery.** `run-model usage --apply` cools down exhausted models until their exact reset; free Codex weekly resets are claimed automatically (`codex_auto_reset`).
- **Housekeeping.** `bin/docker-up` / `bin/docker-reap` keep the Docker daemon up and remove dead containers; `bin/bgrun` runs long commands under a stall watchdog.
- **Nothing personal in the repo.** Roster, accounts and cooldowns live in `~/.config/linear-autopilot/`; project state in `<repo>/.autopilot/`.

## Install

```bash
git clone https://github.com/iCarossio/linear-autopilot
cd linear-autopilot && ./install.sh
```

Then run `/autopilot-init`. Requires Python 3.9+, git, and the model CLIs you want to use, logged in.

## Layout

```
skills/      one SKILL.md per skill
bin/         shared runtime (run-model, pipeline, review, premortem, milestone, eta, tokens, harness, ...)
harnesses/   one JSON adapter per CLI
prompts/     briefs for implementers, reviewers and the pre-mortem
templates/   example roster, state, plan and ticket
references/  lessons from real runs
tests/       behavioural suite against a fake harness (no quota spent)
```

## License

MIT
