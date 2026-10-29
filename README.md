# linear-autopilot

Plan a software project adversarially, create it in Linear, then implement it ticket by ticket with cheap models and cross-model review, unattended, on whatever AI coding CLIs you already pay for. Four skills for Claude Code (or any harness that reads the Agent Skills layout) over one shared runtime.

```
/autopilot-init    once per machine: harnesses, accounts, roster, pools, smoke tests, quotas
/autopilot-plan    per project: KPIs gate -> plan -> pre-mortem by 2 high-tier models of 2 vendors -> guardrails -> Linear project
/autopilot-run     per project: the unattended loop, one ticket = plan review + cheap implementation + 2-vendor review + commit
/autopilot-usage   any time: quota per harness and account, cooldowns, resets, which pools can run now
```

## Principles

- **Implementer and reviewer are always different models**, and the two reviewers come from two vendors. Enforced in `bin/review`, not by prompt.
- **The planner never reviews its own plan.** The pre-mortem excludes the coordinator's vendor.
- **High tier plans, pre-mortems and reviews; it never implements.** Cheap and free models write the code. The tier actually used adapts to the quotas available right now (pools skip cooled-down models and reuse them the minute they reset).
- **Subscriptions and free tiers only.** Several accounts per CLI (e.g. three Codex logins through `CODEX_HOME`) are several quotas; the runtime never pays for extra credits. One naming standard for every harness: the default home, then `<default>-b`, `<default>-c`; roster keys `<key>`, `<key>-b`, `<key>-c`.
- **The coordinator only orchestrates**, so its own budget lasts the night. State lives on disk and in Linear; a new session resumes from there.
- **A plan without measurable KPIs is not a plan.** The pre-mortem question is always the same: "we are at the deadline and we failed; what are the most probable reasons?" Every reason gets a guardrail with a home (a KPI, a check, a ticket, a rule).

## Install

```bash
git clone https://github.com/iCarossio/linear-autopilot ~/Work/linear-autopilot
cd ~/Work/linear-autopilot
./install.sh            # symlinks skills/* into ~/.claude/skills, creates ~/.config/linear-autopilot/models.json
./install.sh --agents   # also into ~/.agents/skills (other harnesses)
./install.sh --import ~/path/to/your/models.json   # start from an existing private roster
```
Then open your harness and run `/autopilot-init`. Python 3.9+ and git are the only requirements; each model CLI you want to use must be installed and logged in.

## Layout

```
skills/autopilot-{init,plan,run,usage}/SKILL.md   the four skills (each has a bin -> ../../bin link)
bin/            shared runtime: autopilot_lib.py (the rules: config transactions, identity, exclusions, tree snapshots, verdict validation), run-model (watchdog + pools + usage), review, premortem, mkbrief, finish, rebase-wt, eta, harness (registry), linear (GraphQL fallback), codex-reset
harnesses/      one JSON adapter per CLI: how to invoke it, account env var, how to list models and read usage
prompts/        briefs: implement, review, plan-review, premortem (2 passes), diagnose
templates/      models.json (example roster), state.json, PLAN.md, ticket.md
references/     lessons learnt on real runs (by symptom), fan-out QA procedure
tests/          tests/selftest.sh: behavioural suite against a fake harness adapter (no quota spent, user config untouched)
```
User state never lives in the repo: `~/.config/linear-autopilot/` holds the roster, accounts, cooldowns, adapter and prompt overrides; `<repo>/.autopilot/` holds per-project state, briefs, outputs and the plan artefacts.

## Adding a harness or an account

```bash
bin/harness discover                                   # what is installed, what has an adapter, accounts on disk
bin/harness new mycli --binary mycli --vendor acme --argv '["-p","{prompt}","--model","{model}","--yes"]'
bin/harness add-model acme-big --cli mycli --model big-2 --cost high --no-implement --pools premortem,plan_review,review_high
bin/harness add-account codex b --label "second login"        # standard: homes ~/.codex, ~/.codex-b, ~/.codex-c; keys <key>, <key>-b, <key>-c
bin/run-model smoke acme-big
bin/run-model usage --apply
```

## Status

Extracted from a private skill that ran several multi-day projects (Oct 2026). The run loop is battle-tested; the init, plan and usage skills, the adapter layer and the shared rules module are new in this repo. Three adversarial review rounds by Codex gpt-6.1-sol preceded the first release (28, 22 and 12 findings; every blocker fixed and covered by `tests/selftest.sh`, 45 checks). Known limits left on purpose: `MIN_REVIEWS=1` and `ALLOW_MID=1` are explicit degraded modes; nested Linear relations are capped at 100 per issue; `codex-reset` drives a TUI and verifies the redemption through the usage probe afterwards. See `references/lessons.md` for what went wrong on real runs and how the runtime now prevents it.

## License

MIT
