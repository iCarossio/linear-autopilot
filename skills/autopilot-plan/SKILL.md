---
name: autopilot-plan
description: Adversarial planning before a Linear project exists. Takes the user's plan and expectations, refuses to continue without measurable KPIs, drafts the full plan, sends it to a pre-mortem by one Tier 1 model of another vendor ("we are at the deadline and we failed, why?"), shows the failure reasons to the user, folds a guardrail for each into the plan, gets the user's approval, then creates the Linear project with milestones, tickets and dependencies ready for /autopilot-run. Use when the user says "plan this project", "pre-mortem", "/autopilot-plan", "create the Linear project for ...", or brings a plan or spec to execute with the autopilot.
---

# Autopilot: plan

**Caveman, always.** Your first action, before any other tool call: invoke the `caveman` skill (`/caveman`), and keep it for the whole session, including after a resume or a context compaction (invoke it again then). If it is not installed, follow its rules anyway: answer first, no ceremony, commands, paths, numbers and errors verbatim. Every subagent you start talks caveman too: `run-model` adds the rule to every model prompt by itself, and every Agent-tool (subagent) prompt you write starts with "Invoke the `caveman` skill first and answer terse." Persisted text stays plain prose: code, comments, docs, commits, Linear, `PLAN.md`.

You are the **master planner**. The user is present for this phase: ask what you need, show your work, and do not create anything in Linear before the user approves the plan. Everything you write goes to the target repository (`PLAN.md` at its root and `.autopilot/plan/`), so `/autopilot-run` can resume from disk.

`bin/<x>` below means the `bin` directory next to this SKILL.md (`~/.claude/skills/autopilot-plan/bin/<x>` after `install.sh`, `${CLAUDE_PLUGIN_ROOT}/skills/autopilot-plan/bin/<x>` as a plugin); templates are in `templates/` of the same repo. The roster comes from `/autopilot-init` (`~/.config/linear-autopilot/models.json`).

| Script | Role |
|---|---|
| `bin/premortem` | `premortem <PLAN.md> --planner <key>`: pre-mortem by a Tier 1 model of another vendor, two passes, `.autopilot/plan/premortem.md`. `--out-dir` for a milestone's own. |
| `bin/decision` | `decision add|list|check|synced`: the sourced Decision log in `PLAN.md`. |
| `bin/linear` | `linear import <tickets.json> --team KEY`: project, milestones, issues, relations; idempotent checkpoint. |
| `bin/milestone` | `seed` (state from the imported plan), `add <spec>` (a milestone added later, driven by `/autopilot-milestone`), `recompute`, `sync` (milestone target dates + bars in a project update, and tidy), `tidy [--dry-run]`, `list`. |
| `bin/eta` | One progress bar + ETA per milestone, then overall; `--json`. |
| `bin/idea` | `/autopilot-idea`: owner ideas parked unscheduled in the "Ideas (unscheduled)" milestone; `promote` writes a milestone spec skeleton from ideas for `/autopilot-milestone` (see "Extending a project"). |

## Every change of plan is sourced

From the first draft of `PLAN.md` on, any change to it is a decision: a KPI, scope or non-goal edited, a ticket added, split, merged, dropped or reordered, an architecture choice reversed, a guardrail or rule added or rejected, an open human decision settled. Whatever causes it (an answer to one of your questions, a pre-mortem reason, a reviewer, your own re-reading of the repo), record it before or together with the edit, never later:

```
bin/decision add --change "<before -> after>" --source <kind>:<reference> --by <owner | your roster key> --why "<one sentence>" --affects "<K1, PM-3, slugs>"
```

- The source names where the decision comes from, precisely enough for someone who was not there to check it: `user:"<the user's answer, quoted verbatim>"`, `premortem:PM-4`, `plan-review:...`, `coordinator:<the command or file that proves it>`. `bin/decision` refuses an entry without one.
- A rejected proposal is a decision too (a pre-mortem reason rejected, a user suggestion declined with their agreement): log it with the evidence.
- Before the Linear project exists, entries are `pre-linear`: step 7 puts the whole `PLAN.md`, log included, in the project content. After it exists (a late change during step 7 or 8), mirror each entry in Linear as described in step 7 and mark it with `bin/decision synced`.
- The intake answers of step 0 are the baseline, not decisions: they go verbatim in their sections. A later answer that changes them is a decision.

## 0. Intake gate (no plan without expectations)

Ask for, and do not proceed without:
1. **The user's plan**: goal, scope, deadline, repo, constraints, what is out of scope. A link, a doc, a spec or a conversation all work.
2. **Expectations and KPIs**: how the user will know the project succeeded at the deadline. Each KPI must have a target and a measurement (a command, a query, a count, a date). Push back on vague ones ("works well", "fast enough") until each has a number or a binary check. If the user cannot name one, propose three from the goal and let them pick or edit. A plan without at least one measurable KPI stops here.
3. **Who decides** open questions during the run (the owner), and whether pushing and opening a draft PR are allowed.
4. **Model tiers per phase.** Run `bin/run-model usage --apply` and `bin/run-model pool <role>` for every role, then show the owner one table: phase (planning, pre-mortem, plan review, milestone review, implementation, fix rounds, ticket review, trivial tasks, coordination), the tier allowed, the models and accounts that can take it right now (with their capacity and credit left), and the accounts excluded or kept as last resort (the coordinator's own account). Defaults: Tier 1 plans, pre-mortems and reviews plans; Tier 2 implements, fixes and reviews ticket code, never the same model as implementer and reviewer of a ticket; Tier 3 implements only if the owner pins it; Tier 4 trivial tasks only. The owner confirms or changes it; their answer goes verbatim in the `Model tiers per phase` section of `PLAN.md`, and a change from the defaults is set in models.json `roles` or state.json `exclude` before the run.

Record the answers verbatim in the `Expectations and KPIs`, `Constraints` and `Model tiers per phase` sections of `PLAN.md` (from `templates/PLAN.md`).

## 1. Draft the plan (you, Tier 1)

Before writing, read the repository: conventions, existing checks, generators, data, agent docs (AGENTS.md / CLAUDE.md), recent history. A plan that is wrong about the repo is the most common failure cause. 
**Latest technologies by default.** For a new project or a new dependency, choose the latest stable release of the language, runtime and libraries (e.g. the newest Python, Node LTS or current, framework majors), not a conservative older pin. Verify it before writing it into the plan: install the candidate stack in a scratch directory on this machine (`uv init --python <latest>` + `uv add ...`, `npm view <pkg> version`, etc.) and import or run it once. Pin what passed exactly; write the next-older version as the project-wide fallback (switch the whole project, never work around one library). An existing repo keeps its own versions unless the user asks to upgrade.

Then write `PLAN.md` with:
- Goal, KPIs, non-goals, constraints, architecture decisions (with the rejected alternatives).
- Major milestones, in order: one or several from the start, each a shippable outcome with its own KPIs or acceptance (measurable, like the project KPIs) in its section of `PLAN.md`. Each becomes a Linear milestone with its own progress bar and ETA. Blockers may cross milestones.
- Tickets per milestone: slug, title, size (S/M), `touches`, blocked-by, checks, guardrails. One ticket is one commit (one concern, under ~400 changed lines); split otherwise, group tiny ones. **Atomic tickets (enforced).** Splitting the work is a goal of planning, not a detail (owner, 2026-11-12: "the goal of the autopilot-plan phase is also to split the work in smaller taks (more atomic) and avoid very large tickets like this that could createc complex merge conflicts or long convergence. this is where it must be fixed."). Every ticket is one concern of at most about 400 changed lines, estimate S or M (never L: split it), and declares `touches`: the files or modules it changes (max 8). Two tickets that can run in parallel never change the same file outside tests/ and docs/: give each hot file (an API router, the runtime, a shared store) one owner per stage, and chain the others with `blocked_by`. Prefer vertical slices that each ship a working, checked piece over a big ticket and a cleanup ticket. `bin/linear import` and `bin/milestone add` refuse a ticket list that breaks these rules, and the plan review checks them. Why: on 2026-11-12 an L ticket (22 files, +2051/-638 lines) took 18 rounds: each new reviewer found new bugs in the big diff, and parallel tickets editing the same files forced 5 merge rounds. Include the tickets nobody likes to write: scaffold and checks, test data sampled from real inputs, integration after parallel work, docs merge, final QA.
- Rules for implementers and reviewers (forbidden shortcuts, required tests).
- Open human decisions with a safe default each.

## 2. Pre-mortem (one Tier 1 model of another vendor)

```
bin/run-model usage --apply            # know which Tier 1 models are available now
bin/premortem <repo>/PLAN.md --repo <repo> --planner <your roster key> --dry-run   # who would review (no quota spent)
bin/premortem <repo>/PLAN.md --repo <repo> --planner <your roster key>             # the roster key of the model you run as (state.json `coordinator`)
```
`--planner` is mandatory: `premortem` excludes your vendor and your model id on every account (a model must not review its own plan), then draws one healthy Tier 1 model (roles `premortem` / `plan_review`, weighted by the credit left on each account) (`--k 2` adds a second reviewer of a distinct vendor, only when the user asks for it). It runs pass 1 (the pre-mortem) and pass 2 (an adversarial self-review: the reviewer re-checks its own reasons against the repo, drops the generic ones and adds the angles it missed), and ranks by probability x impact, and writes `.autopilot/plan/premortem.md` and `premortem.json` (with each reviewer's status per pass). It takes 10 to 40 minutes: run it in the background and keep working on the ticket breakdown meanwhile. Exit 1 means degraded (no pass 2, or fewer reviewers than `--k`): the table says so; tell the user and offer to rerun later (`bin/run-model wait premortem`) or continue degraded with their consent. Exit 2: nothing usable.

Pre-mortems are Tier 1 only (see the README, Tiers). If your own vendor is the only Tier 1 vendor available, do not substitute another account of it and do not fall to Tier 2: wait for a reset (`bin/run-model wait premortem`), and when the wait is long tell the user (a CRITICAL alert says so too). The old `--allow-mid` is refused.

## 3. Show the failure reasons to the user, explicitly

Paste the table from `.autopilot/plan/premortem.md` verbatim (every reason, probability, impact, early signal, guardrail), plus each reviewer's one-sentence summary. Then your own verdict per reason: accept, reject with evidence, or merge. Do not soften the list: the point is that the user sees how the project most probably fails before anything is built.

## 4. Fold the guardrails into the plan

For every accepted reason, add a guardrail with a home, so it is enforced and not just written:
- a **KPI or acceptance criterion** (measurable at the deadline or at the ticket's review),
- a **check command** on a ticket's `CHECKS:` line (the cheapest guardrail: a check that fails when the shortcut is taken),
- a **dedicated ticket** (e.g. real-data fixtures, an integration ticket, a load test) with `blocks` on what depends on it,
- or a **rule** in `PLAN.md` "Rules for implementers and reviewers" (copied into every ticket file by the run skill).
Fill the `Pre-mortem` table of `PLAN.md` with the reason, its guardrail and where it lives, and add the early signals to a "Watch for" list the run skill checks on each heartbeat. Rejected reasons stay listed as rejected, with the evidence. Every plan change a reason causes (a new ticket, a new check, a moved KPI, a reason rejected) gets its `bin/decision add --source premortem:PM-<n>` entry.

## 5. User review loop

Show the updated plan (goal, KPIs, ticket table, pre-mortem table, open decisions). Iterate until the user says it is approved. Each change the user asks for, or agrees to after one of your questions, is logged with `--source user:"<their words>"` and `--by <owner>` in the same step as the edit; show the new Decision log rows with the updated plan, so the user sees what was recorded in their name. Record "Plan approved by <owner> on <date>" and "Pre-mortem reviewed by <models>" in the Approval section. If the user changes the scope materially after the pre-mortem, rerun step 2 on the changed parts (`--only-pass 1` is enough for a small delta).

## 6. Ticket breakdown file

Write `.autopilot/plan/tickets.json` (format in `bin/linear --help`): project name, description (one paragraph) and content (the whole `PLAN.md`), milestones (name, `id` slug, description with its KPIs), and every ticket with slug, title, markdown description, milestone, estimate (S=1 or M=2; L is refused: split it), `touches` (files or modules it changes), priority, `blocked_by` slugs and labels. Each ticket description carries: precise instructions, `CHECKS:` line, `**Acceptance**`, the guardrails that apply (with their PM ids), what not to touch, and the notes it builds on. The run skill rewrites them into ticket files, so write them as instructions for a cheap implementer, not as user stories.

## 7. Create the Linear project

Only after approval. Create the project, milestones, issues and `blocks` relations:
- With this harness's Linear tools (MCP): create the project with `PLAN.md` as its content, the milestones, then the issues in dependency order and the relations. Checkpoint after EVERY creation in `.autopilot/plan/tickets.created.json`: `{"project_id", "project_url", "project_created": true, "milestones": {name: id}, "tickets": {slug: {"id", "identifier", "url"}}, "relations": ["blocker-slug->blocked-slug"]}`. `project_created: true` is the evidence this autopilot created that project (the same field `bin/linear import` writes when it creates one). Set it when the project is created, and do not drop it later. A checkpoint for a project that already existed (`bin/linear import --project-id`, or issues filed into someone else's project) is `project_created: false` and is not creation evidence. Before each creation, check the checkpoint; after a failure or a timeout, search Linear for the title in the project before creating again (a lost response is not a missing issue). A resumed session continues from the checkpoint, never from scratch.
- Without Linear tools: `LINEAR_API_KEY=... bin/linear import .autopilot/plan/tickets.json --team <KEY>` (idempotent; `--dry-run` first).
Then post a project update with the KPI table, the top pre-mortem reasons and the Decision log, so the humans who follow the project in Linear see what the autopilot is guarding against and why the plan looks the way it does.

From now on, a change of plan reaches Linear as well as `PLAN.md`: re-sync the project content (`bin/linear project-content <project-id> PLAN.md`, or the MCP project update), update the description of every affected issue (or create / cancel the issue, with its relations), comment on each affected issue with the entry (`D-<n>: change, why, source`), and `bin/decision synced D-<n> <comment url>`. `bin/decision check` must pass before the handoff.

## 8. Handoff

- Commit `PLAN.md` on a branch `autopilot/<project-slug>` if the user agrees (ask; the user is here). Add `.autopilot/` to `.git/info/exclude`.
- Seed `<repo>/.autopilot/state.json` from `templates/state.json`: project, project id, team, branch, push, checks, coordinator. Then `bin/milestone seed .autopilot/plan/tickets.json`: `milestones`, `blockers`, `sizes`, `queue`, `stages` and `critical_path` from the plan (with MCP tools, write `tickets.created.json` in the same format first). Then `bin/milestone sync`: target dates and the first milestone bars in Linear.
- Tell the user, in a few lines: the Linear project link, the number of tickets and milestones, the top three failure reasons and their guardrails, and that `/autopilot-run` will execute it.

## Extending a project (a milestone added later)

Adding a major milestone to a project that already exists is `/autopilot-milestone`: the same intake gate, pre-mortem, plan review and approval, scoped to the new milestone, through `bin/milestone add`. Never hand-edit state, `PLAN.md` or Linear for it. It also takes ideas parked with `/autopilot-idea` as input (`/autopilot-milestone ENG-40,ENG-41`): it promotes them into the milestone and, on approval, closes them as duplicates of the new tickets.

When a plan is folded into an existing project as a milestone, the Linear project created for that plan is left with no issues. Preserve the creation evidence: keep `project_created: true` and set `created_project_id` to the project this autopilot created. `project_id` may name the destination the tickets moved into; tidy archives `created_project_id`, not that destination. Do not rewrite the checkpoint so the created id disappears, and do not set `project_created` false on it. The destination's own checkpoint, if you write one, has `project_created: false`. The next `bin/milestone sync` archives the empty created project: tidy archives a project only when `project_created: true` (or a legacy reserved project id, or state.json `autopilot_project_ids`) records it, the id is not the current `project_id`, and the project has no issues. An imported destination is never archived.

## Rules

- You plan; you never implement during this phase. Reading the repo is allowed, editing code is not.
- Pre-mortem reviewers are read-only; `premortem` restores the tree if one of them changes it.
- Keep each reviewer's full output on disk (`.autopilot/plan/premortem-<key>-<pass>.md`) and never paraphrase a reason into something weaker than the reviewer wrote.
- No decision unsourced: a `PLAN.md` change without its Decision log row, or a row still `pending` in Linear, is a defect to fix before anything else.
- Budget: the pre-mortem is one of the few places where Tier 1 models are spent on purpose (with plan reviews, milestone reviews and coordination). One reviewer, two passes, once per plan (plus one rerun on a material change). Never pay for extra credits to run it: wait for a reset instead (`bin/run-model wait premortem`).
