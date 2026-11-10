# linear-autopilot

Plan a software project adversarially, create it in Linear, then let cheap models implement it ticket by ticket, reviewed by stronger models, unattended, on the AI coding CLIs you already pay for. Every role has its tier (see Tiers): flagships plan, balanced models review, fast and cheap models write the code.

Six skills for Claude Code (or any harness that reads `~/.claude/skills`):

| Skill | When | What it does |
|---|---|---|
| `/autopilot-init` | once per machine | finds your CLIs (Codex, Claude Code, opencode, Grok, ...) and their accounts, asks once which subscriptions you pay for, assigns every model its tier and vendor, smoke-tests them, reads the quotas, and prints which models can take each role and what is missing |
| `/autopilot-plan` | once per project | your plan and KPIs, a pre-mortem by one Tier 1 model of another vendor, guardrails, then the Linear project with all tickets |
| `/autopilot-milestone` | when the project grows | `/autopilot-plan` for an existing project: a new major milestone from new scope or from parked ideas (`/autopilot-milestone ENG-40,ENG-41`), its KPIs, a pre-mortem and plan review of the delta, your approval, then the Linear milestone, tickets and ETA bar |
| `/autopilot-run` | per project, for hours | one ticket at a time: Tier 1 plan review, a Tier 3 implementer, one Tier 2 reviewer, again until approved, one commit, Linear updated; one progress bar and ETA per major milestone, mirrored on the Linear milestones |
| `/autopilot-idea` | any time | captures the owner's quick ideas, verbatim, in the project's "Ideas (unscheduled)" Linear milestone, out of the queue and every ETA; later promotes one or several into a real milestone (pre-mortem, plan review, approval) |
| `/autopilot-usage` | any time | what quota is left on every CLI and account, which pools can run now, and how many tokens went through every harness and account (per day, month, year; terminal chart or HTML page) |

## Tiers

The owner's tier table (November 2026) decides who does what. `bin/autopilot_lib.py` (`DEFAULT_TIER_TABLE`) carries it; `models.json` `tier_table` overrides it; `bin/harness add-model` and `run-model discover` use it to set an entry's `level`.

| Tier | Examples | Role in the autopilot |
|---|---|---|
| 0 frontier ceiling | Claude Mythos / Fable, GPT-6 Astra, Gemini 4 Carbon | never selected automatically; `run-model --model KEY --allow-tier0` when the owner asks |
| 1 flagship | Claude Opus, GPT-6.1 Sol, Gemini 4 Argon, Grok 4.7, GLM-5.3, Kimi K3, Qwen3.8-Max, DeepSeek V4 Pro | plan reviews, pre-mortems, milestone adversarial reviews, coordination; never implements, never reviews ticket code |
| 2 balanced | Claude Sonnet, GPT-6.1 Terra, Gemini 3.8 Flash, Grok 4.3, Qwen3.7-Plus | the reviewer of each round; `--escalate` implements a stuck ticket |
| 3 fast and cheap | Claude Haiku, GPT-6 Luna, Gemini 3.5 Flash-Lite, DeepSeek V4.1 Flash, GLM-5.3 Flash, Qwen3.7-Flash, Grok 4.1 Fast | implementation and fix rounds |
| 4 small | every Mistral model, every free model, old Gemini, whatever the table says | trivial tasks only, never a reviewer |

**Roles.** `models.json` `roles` maps each role to its levels (`implement`/`fix` 3, `review` 2, `plan_review`/`premortem`/`milestone_review`/`coordinate` 1, `trivial` 4); the code refuses a mapping that moves a role to another tier. The old pool names (`implement_critical`, `fix_mid`, `review_mid`, `review_high`, `implement_escalation`) are aliases of the roles. There are no hand-ordered pools.

**Selection.** A role's candidates are the valid roster entries of its tier whose CLI is installed and that are not excluded. `run-model` draws one at random, weighted by the credit left on its account (the latest `usage` reading; unknown is neutral, an account near exhaustion is almost never drawn) and by its subscription (paid 1, unconfirmed 0.7, free plan 0.25). The draw order is the fallback chain. `AUTOPILOT_SEED` makes it reproducible.

**Vendor -> CLI.** A model is reached only through its vendor's own CLI: Anthropic through `claude`, OpenAI through `codex`, Google through `agy`, Mistral through `vibe`, xAI through `grok` or `cursor`, every other vendor through `opencode` (OpenCode Go or OpenRouter). An entry that breaks it is refused at load, in every pool and by `--model`; `bin/harness add-model` will not create one.

**Coordinator account.** Detected per session, never configured: an adapter's `coordinator_env` (Claude Code sets `CLAUDECODE`) names the CLI the coordinator runs in, its `account_env` in the coordinator's process names the account (unset = the CLI's default home); `AUTOPILOT_COORDINATOR=<cli>[/<account>]` overrides. `bin/run-model whoami --record` stores it in `state.json`. Entries on that exact account (another login of the same CLI is a normal account) run last, for cheap roles only, and only while the account keeps `coordinator_reserve` (default 30% of the 5-hour window and 20% of the weekly window left); below it the run is refused and a CRITICAL alert raised.

**Subscriptions and exclusions.** `/autopilot-init` asks once, per account, what the owner pays for (`bin/harness subscription <cli> <account> paid|free|reserved --plan NAME`). `reserved` or `excluded: <reason>` removes an account or entry everywhere; a project's `state.json` `exclude` (`{"<key>|<cli>/<account>|<cli>": "<reason>"}`) removes it for that project only.

**Latest version.** `run-model discover --apply` (and once a day from `usage --apply`) looks for a newer id of every versioned `family` per CLI (listing command, or generated next-version ids for a CLI without a listing, such as Claude), smoke-tests it through the entry's own account, switches every entry of that id, keeps the level unless the tier table names the new id, and logs it in `changelog`.

`bin/harness check` prints, per role, the candidates with their tier, account, subscription, health and credit left, then every missing piece (a role without a candidate, a CLI not installed, a refused entry, an unknown subscription) with what to do.

## Supported harnesses

One JSON adapter per CLI in `harnesses/`. "Accounts" means several logins of the same CLI, each its own quota, selected by an environment variable; "usage" is the quota probe; "tokens" is the local log `bin/tokens` reads to count consumption.

| Harness | CLI | Accounts | Usage probe | Token log |
|---|---|---|---|---|
| OpenAI Codex | `codex` | `CODEX_HOME`: `~/.codex`, `~/.codex-b`, ... | rate limits in the session logs | session rollouts |
| Claude Code | `claude` | `CLAUDE_CONFIG_DIR`: `~/.claude`, `~/.claude-b`, ... | `/usage` | project transcripts |
| opencode | `opencode` | `XDG_DATA_HOME`: `~/.local/share`, `~/.local/share-b`, ... | none (quota errors) | SQLite store |
| Cursor | `cursor-agent` | one login (an API key per extra account) | none (cursor.com) | none |
| xAI Grok | `grok` | one login | interactive `/usage` only | session usage files |
| Google Antigravity | `agy` | one login | `/usage` | brain transcripts |
| Google Gemini CLI | `gemini` | one login | `/stats` only | chat recordings (untested); not used for models: Google models run only through `agy` |
| Mistral Vibe | `vibe` | one login | interactive `/usage` only | none |

Any other CLI with a non-interactive mode is added with `bin/harness new` (see `/autopilot-init`); accounts, usage and token logs are optional fields of the adapter. Under the vendor -> CLI rule a new CLI can serve only vendors that have no CLI of their own above, and only if it replaces `opencode` for them in `VENDOR_CLIS`.

## Principles

1. **No plan without measurable KPIs.** The planning skill refuses to continue until every expectation has a number or a binary check.
2. **Assume failure first.** Before any ticket exists, a Tier 1 model of another vendor answers one question: "we are at the deadline and we failed, why?". Every reason gets a guardrail with a home: a KPI, a check, a ticket or a rule.
3. **A model never reviews its own work.** The implementer of a ticket, on any account or through any harness, is excluded from its review; the planner's vendor is excluded from the review of its plan. Enforced in code, not by prompt.
4. **One implementer, one reviewer, and again.** Each round is one Tier 3 implementer then one Tier 2 reviewer that is not any implementer of the ticket (another vendor when one is available). A review counts only when it parses, the reviewer did not touch the tree, and an "approve" carries no blocking finding.
5. **Every role has its tier, never another.** Tier 1 plans, pre-mortems, reviews milestones and coordinates; Tier 2 reviews ticket code; Tier 3 writes it; Tier 4 only does trivial tasks. When a tier is out of quota the run waits for its reset or raises a CRITICAL alert: it never falls to another tier silently.
6. **Max out what you pay for, never pay more.** Inside a tier, the model is drawn at random weighted by the credit left on its account, paid subscriptions before free plans, so every subscription is used up before its reset. Several logins of one CLI are several quotas. The runtime waits for a reset, claims the free Codex weekly resets by itself (`codex_auto_reset`), and never buys credits. A vendor out of quota on every account with no reset left is a CRITICAL alert (`bin/alert`, the top of `bin/eta`, a Linear project update) that the coordinator reports to you at once.
7. **One account standard.** Homes are `<default>`, `<default>-b`, `<default>-c` (`~/.codex`, `~/.codex-b`, `~/.codex-c`); roster keys are `<key>`, `<key>-b`, `<key>-c`. Same for every harness.
8. **The coordinator only orchestrates, and its account is protected.** It never implements or reviews. The account it runs on is detected at run time; models on that account run only as a last resort, for cheap roles, while its quota keeps a reserve, so the coordinator never runs out of credits. State lives on disk and in Linear; a new session resumes from there.
9. **Milestones grow with the project.** A project has one or more major milestones, each with its KPIs, its Linear milestone and its own ETA bar. Adding one later is normal and goes through the same pre-mortem and plan review, scoped to the delta, before anything is created (`/autopilot-milestone`, on top of `bin/milestone add`). Ideas are not milestones: `/autopilot-idea` parks them unscheduled until the owner promotes them.
10. **About one ticket per commit.** Small tickets, parallel worktrees, cherry-picked onto one project branch, nothing merged into the default branch without you.
11. **Nothing personal in the repo.** Accounts, cooldowns and overrides live in `~/.config/linear-autopilot/`; project state in `<repo>/.autopilot/`.

## Install

```bash
git clone https://github.com/iCarossio/linear-autopilot
cd linear-autopilot && ./install.sh
```
Then run `/autopilot-init` in your harness. Requirements: Python 3.9+, git, and the model CLIs you want to use, logged in.

## Layout

```
skills/      the six SKILL.md files
bin/         shared runtime (run-model, review, premortem, decision, milestone, idea, eta, harness, linear, state, tokens, ...)
harnesses/   one JSON adapter per CLI: how to call it, where its accounts live, how to read its usage
prompts/     briefs for implementers, reviewers and the pre-mortem
templates/   example roster, state, plan and ticket
references/  lessons from real runs, by symptom (lessons.md; lessons-codex-resets.md: Codex quota outage, automatic resets, stale usage)
tests/       behavioural suite against a fake harness (no quota spent)
```

## License

MIT
