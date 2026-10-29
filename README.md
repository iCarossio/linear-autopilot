# linear-autopilot

Plan a software project adversarially, create it in Linear, then let cheap models implement it ticket by ticket, reviewed by other models, unattended, on the AI coding CLIs you already pay for.

Four skills for Claude Code (or any harness that reads `~/.claude/skills`):

| Skill | When | What it does |
|---|---|---|
| `/autopilot-init` | once per machine | finds your CLIs (Codex, Claude Code, opencode, Grok, ...), their accounts and quotas; builds the model roster |
| `/autopilot-plan` | once per project | your plan and KPIs, a pre-mortem by two high-tier models, guardrails, then the Linear project with all tickets |
| `/autopilot-run` | per project, for hours | one ticket at a time: plan review, cheap implementation, two-vendor review, one commit, Linear updated |
| `/autopilot-usage` | any time | what quota is left on every CLI and account, and which pools can run now |

## Principles

1. **No plan without measurable KPIs.** The planning skill refuses to continue until every expectation has a number or a binary check.
2. **Assume failure first.** Before any ticket exists, two high-tier models of two other vendors answer one question: "we are at the deadline and we failed, why?". Every reason gets a guardrail with a home: a KPI, a check, a ticket or a rule.
3. **A model never reviews its own work.** The implementer of a ticket, on any account or through any harness, is excluded from its review; the planner's vendor is excluded from the review of its plan. Enforced in code, not by prompt.
4. **Two reviewers, two vendors.** A review counts only when it parses, the reviewer did not touch the tree, and an "approve" carries no blocking finding. Degraded modes exist but must be asked for.
5. **High tier thinks, cheap tier types.** Expensive models plan, pre-mortem and review; cheap and free models write the code. The tier actually used follows the quota available right now.
6. **Subscriptions and free tiers only.** Several logins of one CLI are several quotas. The runtime waits for a reset; it never buys credits.
7. **One account standard.** Homes are `<default>`, `<default>-b`, `<default>-c` (`~/.codex`, `~/.codex-b`, `~/.codex-c`); roster keys are `<key>`, `<key>-b`, `<key>-c`. Same for every harness.
8. **The coordinator only orchestrates.** It never implements or reviews, so its own budget lasts the night. State lives on disk and in Linear; a new session resumes from there.
9. **About one ticket per commit.** Small tickets, parallel worktrees, cherry-picked onto one project branch, nothing merged into the default branch without you.
10. **Nothing personal in the repo.** Accounts, cooldowns and overrides live in `~/.config/linear-autopilot/`; project state in `<repo>/.autopilot/`.

## Install

```bash
git clone https://github.com/iCarossio/linear-autopilot ~/Work/linear-autopilot
cd ~/Work/linear-autopilot && ./install.sh
```
Then run `/autopilot-init` in your harness. Requirements: Python 3.9+, git, and the model CLIs you want to use, logged in.

## Layout

```
skills/      the four SKILL.md files
bin/         shared runtime (run-model, review, premortem, harness, linear, state, ...)
harnesses/   one JSON adapter per CLI: how to call it, where its accounts live, how to read its usage
prompts/     briefs for implementers, reviewers and the pre-mortem
templates/   example roster, state, plan and ticket
references/  lessons from real runs, by symptom
tests/       behavioural suite against a fake harness (no quota spent)
```

## License

MIT
