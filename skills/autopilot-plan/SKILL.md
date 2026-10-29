---
name: autopilot-plan
description: Adversarial planning before a Linear project exists. Takes the user's plan and expectations, refuses to continue without measurable KPIs, drafts the full plan, sends it to a pre-mortem by two high-tier models of different vendors ("we are at the deadline and we failed, why?"), shows the failure reasons to the user, folds a guardrail for each into the plan, gets the user's approval, then creates the Linear project with milestones, tickets and dependencies ready for /autopilot-run. Use when the user says "plan this project", "pre-mortem", "/autopilot-plan", "create the Linear project for ...", or brings a plan or spec to execute with the autopilot.
---

# Autopilot: plan

You are the **master planner**. The user is present for this phase: ask what you need, show your work, and do not create anything in Linear before the user approves the plan. Everything you write goes to the target repository (`PLAN.md` at its root and `.autopilot/plan/`), so `/autopilot-run` can resume from disk.

`bin/<x>` below means the `bin` directory next to this SKILL.md (`~/.claude/skills/autopilot-plan/bin/<x>` after `install.sh`, `${CLAUDE_PLUGIN_ROOT}/skills/autopilot-plan/bin/<x>` as a plugin); templates are in `templates/` of the same repo. The roster comes from `/autopilot-init` (`~/.config/linear-autopilot/models.json`).

## 0. Intake gate (no plan without expectations)

Ask for, and do not proceed without:
1. **The user's plan**: goal, scope, deadline, repo, constraints, what is out of scope. A link, a doc, a spec or a conversation all work.
2. **Expectations and KPIs**: how the user will know the project succeeded at the deadline. Each KPI must have a target and a measurement (a command, a query, a count, a date). Push back on vague ones ("works well", "fast enough") until each has a number or a binary check. If the user cannot name one, propose three from the goal and let them pick or edit. A plan without at least one measurable KPI stops here.
3. **Who decides** open questions during the run (the owner), and whether pushing and opening a draft PR are allowed.

Record the answers verbatim in the `Expectations and KPIs` and `Constraints` sections of `PLAN.md` (from `templates/PLAN.md`).

## 1. Draft the plan (you, high tier)

Before writing, read the repository: conventions, existing checks, generators, data, agent docs (AGENTS.md / CLAUDE.md), recent history. A plan that is wrong about the repo is the most common failure cause. Then write `PLAN.md` with:
- Goal, KPIs, non-goals, constraints, architecture decisions (with the rejected alternatives).
- Milestones and tickets: slug, title, size (S/M/L), blocked-by, checks, guardrails. One ticket is one commit when reasonable (one concern, under ~400 changed lines); split otherwise, group tiny ones. Include the tickets nobody likes to write: scaffold and checks, test data sampled from real inputs, integration after parallel work, docs merge, final QA.
- Rules for implementers and reviewers (forbidden shortcuts, required tests).
- Open human decisions with a safe default each.

## 2. Pre-mortem (two high-tier models, two other vendors)

```
bin/run-model usage --apply            # know which high-tier models are available now
bin/premortem <repo>/PLAN.md --repo <repo> --planner <your roster key> --dry-run   # who would review (no quota spent)
bin/premortem <repo>/PLAN.md --repo <repo> --planner <your roster key>             # e.g. --planner claude-opus when you are Claude Opus
```
`--planner` is mandatory: `premortem` excludes your vendor and your model id on every account (a model must not review its own plan), then picks two healthy `cost: high` models from the `premortem` and `plan_review` pools with two distinct vendors. It runs pass 1 (independent pre-mortems) and pass 2 (each re-reads its own list and the other's, agrees or disagrees with evidence, adds what both missed), merges and ranks by probability x impact, and writes `.autopilot/plan/premortem.md` and `premortem.json` (with each reviewer's status per pass). It takes 10 to 40 minutes: run it in the background and keep working on the ticket breakdown meanwhile. Exit 1 means degraded (one reviewer, or a pass 2 missing): the table says so; tell the user and offer to rerun later (`bin/run-model wait premortem`) or continue degraded with their consent. Exit 2: nothing usable.

If your own vendor is the only high tier available, do not substitute another account of it: wait for a reset (`bin/run-model wait premortem`), or, with the user's consent, `--allow-mid` to accept `cost: mid` models of other vendors (say so in the Approval section).

## 3. Show the failure reasons to the user, explicitly

Paste the table from `.autopilot/plan/premortem.md` verbatim (every reason, probability, impact, early signal, guardrail), plus each reviewer's one-sentence summary. Then your own verdict per reason: accept, reject with evidence, or merge. Do not soften the list: the point is that the user sees how the project most probably fails before anything is built.

## 4. Fold the guardrails into the plan

For every accepted reason, add a guardrail with a home, so it is enforced and not just written:
- a **KPI or acceptance criterion** (measurable at the deadline or at the ticket's review),
- a **check command** on a ticket's `CHECKS:` line (the cheapest guardrail: a check that fails when the shortcut is taken),
- a **dedicated ticket** (e.g. real-data fixtures, an integration ticket, a load test) with `blocks` on what depends on it,
- or a **rule** in `PLAN.md` "Rules for implementers and reviewers" (copied into every ticket file by the run skill).
Fill the `Pre-mortem` table of `PLAN.md` with the reason, its guardrail and where it lives, and add the early signals to a "Watch for" list the run skill checks on each heartbeat. Rejected reasons stay listed as rejected, with the evidence.

## 5. User review loop

Show the updated plan (goal, KPIs, ticket table, pre-mortem table, open decisions). Iterate until the user says it is approved. Record "Plan approved by <owner> on <date>" and "Pre-mortem reviewed by <models>" in the Approval section. If the user changes the scope materially after the pre-mortem, rerun step 2 on the changed parts (`--only-pass 1` is enough for a small delta).

## 6. Ticket breakdown file

Write `.autopilot/plan/tickets.json` (format in `bin/linear --help`): project name, description (one paragraph) and content (the whole `PLAN.md`), milestones, and every ticket with slug, title, markdown description, milestone, estimate (S=1, M=2, L=3, or the team's scale), priority, `blocked_by` slugs and labels. Each ticket description carries: precise instructions, `CHECKS:` line, `**Acceptance**`, the guardrails that apply (with their PM ids), what not to touch, and the notes it builds on. The run skill rewrites them into ticket files, so write them as instructions for a cheap implementer, not as user stories.

## 7. Create the Linear project

Only after approval. Create the project, milestones, issues and `blocks` relations:
- With this harness's Linear tools (MCP): create the project with `PLAN.md` as its content, the milestones, then the issues in dependency order and the relations. Checkpoint after EVERY creation in `.autopilot/plan/tickets.created.json`: `{"project_id", "project_url", "milestones": {name: id}, "tickets": {slug: {"id", "identifier", "url"}}, "relations": ["blocker-slug->blocked-slug"]}` (the same file `bin/linear import` writes). Before each creation, check the checkpoint; after a failure or a timeout, search Linear for the title in the project before creating again (a lost response is not a missing issue). A resumed session continues from the checkpoint, never from scratch.
- Without Linear tools: `LINEAR_API_KEY=... bin/linear import .autopilot/plan/tickets.json --team <KEY>` (idempotent; `--dry-run` first).
Then post a project update with the KPI table and the top pre-mortem reasons, so the humans who follow the project in Linear see what the autopilot is guarding against.

## 8. Handoff

- Commit `PLAN.md` on a branch `autopilot/<project-slug>` if the user agrees (ask; the user is here). Add `.autopilot/` to `.git/info/exclude`.
- Seed `<repo>/.autopilot/state.json` from `templates/state.json`: project, project id, team, branch, push, checks, `critical_path` (the longest chain of `blocked_by`), `queue` in milestone order, `sizes`, `stages`.
- Tell the user, in a few lines: the Linear project link, the number of tickets and milestones, the top three failure reasons and their guardrails, and that `/autopilot-run` will execute it.

## Rules

- You plan; you never implement during this phase. Reading the repo is allowed, editing code is not.
- Pre-mortem reviewers are read-only; `premortem` restores the tree if one of them changes it.
- Keep each reviewer's full output on disk (`.autopilot/plan/premortem-<key>-<pass>.md`) and never paraphrase a reason into something weaker than the reviewer wrote.
- Budget: the pre-mortem is the one place where high-tier models are spent on purpose. Two reviewers, two passes, once per plan (plus one rerun on a material change). Never pay for extra credits to run it: wait for a reset instead (`bin/run-model wait premortem`).
