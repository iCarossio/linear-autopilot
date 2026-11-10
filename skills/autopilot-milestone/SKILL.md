---
name: autopilot-milestone
description: /autopilot-plan for a project that already exists. Adds a major milestone to a Linear project planned with /autopilot-plan or running under /autopilot-run, with the same adversarial treatment as the first plan, scoped to the new milestone. Takes new scope from the user, or one or several ideas parked with /autopilot-idea (promoted into the milestone and closed as duplicates of its tickets on approval). Refuses to continue without measurable KPIs for the milestone, reads the current PLAN.md, state and Linear, drafts the milestone spec and its tickets, runs a pre-mortem and an adversarial plan review by Tier 1 models of another vendor, shows every failure reason and finding to the user, folds the accepted ones in, and only after the user approves creates the Linear milestone, issues and relations, appends PLAN.md, logs the decision and recomputes the ETAs. Use when the user says "add a milestone", "extend the project", "new phase", "promote idea ENG-40", "schedule these ideas", "/autopilot-milestone [ENG-40,...]", or brings new scope for a project the autopilot already knows.
---

# Autopilot: milestone

**Caveman, always.** Your first action, before any other tool call: invoke the `caveman` skill (`/caveman`), and keep it for the whole session, including after a resume or a context compaction (invoke it again then). If it is not installed, follow its rules anyway: answer first, no ceremony, commands, paths, numbers and errors verbatim. Every subagent you start talks caveman too: `run-model` adds the rule to every model prompt by itself, and every Agent-tool (subagent) prompt you write starts with "Invoke the `caveman` skill first and answer terse." Persisted text stays plain prose: code, comments, docs, commits, Linear, `PLAN.md`.

This is `/autopilot-plan` for a project that already exists: same intake gate, same pre-mortem and plan review, same approval, but scoped to one new milestone and fitted into the plan that is already running.

You are the **milestone planner**. A project exists: `PLAN.md` at the repo root, `.autopilot/state.json`, a Linear project, maybe tickets in flight under `/autopilot-run`. You add one major milestone to it. The user is present: ask what you need, show your work, and create nothing in Linear before the user approves.

`bin/<x>` below means the `bin` directory next to this SKILL.md (`~/.claude/skills/autopilot-milestone/bin/<x>` after `install.sh`, `${CLAUDE_PLUGIN_ROOT}/skills/autopilot-milestone/bin/<x>` as a plugin). Everything goes through `bin/milestone add`; never hand-edit `state.json`, the milestone sections of `PLAN.md` or Linear for this.

| Script | Role |
|---|---|
| `bin/milestone` | `add <spec>`: validation, pre-mortem of the delta, plan review, approval stop, decision, Linear, `PLAN.md`, state, bars. Resumable. `list`, `recompute`, `sync`. |
| `bin/decision` | The sourced Decision log in `PLAN.md`. |
| `bin/eta` | One bar + ETA per milestone, then overall. |
| `bin/idea` | `list`, `promote ENG-1,... --id --name`: turns parked ideas into this skill's spec skeleton. |
| `bin/bgrun` | Runs the 10-40 min review under a stall and timeout watchdog. |

Not this skill: a project with no `PLAN.md` / no Linear project yet (`/autopilot-plan`); grouping tickets that already exist into a milestone (`bin/milestone adopt`, see `/autopilot-run` setup); a small change inside an existing milestone (a decision under `/autopilot-run`, "Changes of plan").

## Inputs

The milestone comes from one of:
- **New scope from the user** (a message, a doc, a spec): start at step 0.
- **Ideas parked with `/autopilot-idea`**: identifiers (`/autopilot-milestone ENG-40,ENG-41`), titles ("the RBAC idea"), or "promote the ideas about X". Resolve them with `bin/idea list` (match titles there; ask only if two ideas match). Propose the ideas related to them (`related` column) and let the user decide which come along: an idea left out stays parked. Then, after step 0:
  ```
  bin/idea promote ENG-40,ENG-41 --id <milestone-slug> --name "<milestone name>"
  ```
  It writes the skeleton `.autopilot/plan/milestones/<id>/spec.json`: the owner's words of every idea quoted in `description`, one placeholder ticket per idea (`from_idea`), KPIs, plan and ticket instructions marked `TODO`, and `from_ideas`. If a skeleton already exists for that id (an earlier, interrupted session), continue from it; `--force` only when the user wants to start over.
- **A skeleton or spec already on disk** (`.autopilot/plan/milestones/<id>/spec.json`): continue from it; `status.json` next to it says which steps of `bin/milestone add` already ran.

## 0. Context

1. Find the repo (`.autopilot/state.json`); read `PLAN.md` (goal, KPIs, architecture, rules, pre-mortem, Decision log, existing milestone sections), `bin/milestone list` and the head of `bin/eta`.
2. `bin/decision check`: pending decisions are synced first; a new milestone is not built on an unsynced plan.
3. Is `/autopilot-run` active on this project (inflight tickets in state, running `run-model` processes)? Then the run keeps going on the current milestones while you work: never pause it, never touch its worktrees. `bin/milestone add` writes state under the lock; the coordinator picks up the new queue at its next re-plan.

## 1. Intake gate (no milestone without expectations)

Ask for, and do not proceed without the following. For promoted ideas, the owner's words quoted in the skeleton are the starting point, not the answer: an idea says what, rarely how much or how it is measured. Restate each idea in one line, then ask only what it leaves open.
1. **What exists when the milestone is done**, for whom, why now, and what is out of scope.
2. **Milestone KPIs**: each with a target and a measurement (command, query, count, date). Push back on vague ones; if the user cannot name one, propose three and let them pick. No measurable KPI: stop here.
3. **Ordering**: must it wait for a current milestone, run beside it, or preempt it? A deadline?

Keep the user's answers verbatim: they are the `user:"..."` source of the approval decision. A promoted idea whose answers turn it into something else than its words (narrowed, split, merged with another) is fine: say so in `why`, the idea's words stay quoted in `description`.

## 2. Draft the spec (you, Tier 1)

Read the code the milestone touches before writing (conventions, existing checks, the notes of the tickets it builds on, `docs/notes/*`). Then write `.autopilot/plan/milestones/<id>/spec.json` (format: `bin/milestone --help`):
- `id`, `name`, `description`, `why`, `kpis` (ids `<id>-K1`, ...).
- `plan`: markdown with the goal, the architecture decisions (with rejected alternatives), the rules and guardrails of this milestone, and a `Pre-mortem` table filled in step 4.
- `tickets`: as in `/autopilot-plan` step 6: precise instructions for a cheap implementer, `CHECKS:` line, `**Acceptance**`, guardrails, what not to touch. One ticket is one commit when reasonable. Include the unglamorous ones: integration with the existing milestones, real-data fixtures, docs merge, final QA against the milestone KPIs.
- `blocked_by`: real dependencies only, on new slugs or existing issues (`ENG-12`). An ordering-only dependency on a current milestone is not a blocker: say it in `plan`.
- Latest stable technologies for anything new, verified on this machine, as in `/autopilot-plan` step 1; existing dependencies keep their versions.

From promoted ideas: replace every `TODO` (the real add refuses one; `--dry-run` only warns). Each placeholder ticket becomes as many real tickets as the idea needs; every ticket that implements an idea keeps `"from_idea": "<its identifier>"`, and `from_ideas` stays as written, so the approval links each idea as a duplicate of its tickets and closes it. Integration, fixtures and QA tickets carry no `from_idea`. An idea the user drops during intake: remove it from `from_ideas` and from its tickets; it stays parked.

Then `bin/milestone add <spec> --dry-run`: fix every validation error, and show the user the stages and the ETA of every milestone with this one added. If it pushes an existing milestone's ETA, say so now.

## 3. Adversarial review (pre-mortem + plan review)

```
bin/run-model usage --apply
bin/bgrun --name milestone-<id> --idle 1800 --timeout 5400 --watch .autopilot/plan/milestones/<id> -- bin/milestone add <spec> --planner <your roster key>
```
in the background (10-40 min), while you re-read the spec. It runs:
- a **pre-mortem** of the milestone by a Tier 1 model of another vendor (the milestone's adversarial review), two passes (the reasons, then an adversarial self-review against the repo), with the existing plan as context, so it raises how this milestone fails and how it breaks what is already planned; into `.autopilot/plan/milestones/<id>/premortem.md`;
- a **plan review** by a Tier 1 model of another vendor (`POOL=plan_review`): fit with the existing architecture, tickets and KPIs, real and complete dependencies, measurable KPIs; into `.../plan-review.md`.

Exit 3 is the expected stop (needs approval). Exit 2: a review gave nothing usable; wait for a reset (`bin/run-model wait premortem`), and tell the user when it lasts. Neither your own vendor nor a Tier 2 model is ever a substitute (the old `--allow-mid` is gone). `--review-k 2` adds a second plan reviewer of a distinct vendor only when the user asks.

## 4. Show everything to the user, then fold

Paste the pre-mortem table and the plan-review findings verbatim (every reason, probability, impact, early signal, guardrail; every finding), plus your verdict on each: accept, reject with evidence, or merge. Do not soften them.

For each accepted reason or finding, give it a home in the spec: a milestone KPI, a `CHECKS:` command, a dedicated ticket with `blocked_by`, or a rule in `plan`. Fill the `Pre-mortem` table of `plan` (reason, verdict, guardrail, where it lives; rejected ones with their evidence): it lands in `PLAN.md` with the milestone, so every change made because of the review keeps its source.

If a reason changes something **outside** the milestone (an existing ticket's scope or blockers, an existing KPI, a shared rule), that is a decision on the current plan: after approval, `bin/decision add --source premortem:<id>/PM-<n>` (or `plan-review:milestone-<id> m<n>`), apply it under `/autopilot-run`'s "Changes of plan", then `bin/milestone recompute` and `sync --decision D-<n>`.

Show the updated spec (KPIs, ticket table, pre-mortem table, ETAs from a new `--dry-run`). Iterate until the user approves.

**Re-review after a material fold.** A rerun of `bin/milestone add <spec>` without `--approved` detects the changed spec and runs the pre-mortem and the plan review again. Do it when the fold added scope, tickets or architecture. When it only added the guardrails the reviewers asked for, the user may approve directly.

## 5. Apply (only after approval)

```
bin/milestone add <spec> --approved --by <owner> --source user:"<their approval, verbatim>"
```
It logs the decision, creates the Linear milestone, issues and `blocks` relations in the existing project (checkpointed: a rerun never duplicates), appends the milestone section to `PLAN.md`, updates `state.json` (milestones, blockers, sizes) and recomputes `queue`, `stages`, `critical_path`, then syncs the target dates and bars to Linear and marks the decision synced. After any failure, rerun the same command: it resumes after the last completed step.

A step is skipped only with `--skip-premortem "<why>"` / `--skip-review "<why>"`, with the user's consent; the reason is written into the decision.

Then: apply the outside-the-milestone decisions from step 4, run `bin/decision check` (must pass), and if `PLAN.md` is tracked on the project branch commit it alone (`docs(plan): milestone <name>`).

## 6. Handoff

Tell the user in a few lines: the Linear milestone link, the ideas closed into it (with their new tickets), the number of tickets, the top three failure reasons and their guardrails, the `bin/eta` lines (one bar per milestone), and what happens next: the running `/autopilot-run` picks the tickets up at its next re-plan; if none is running, `/autopilot-run` starts them.

## Rules

- You plan; you never implement. Reading the repo is allowed, editing code is not.
- Reviewers are read-only and never of your own vendor or model (`--planner` excludes them).
- Keep every reviewer's full output on disk under `.autopilot/plan/milestones/<id>/` and never paraphrase a reason into something weaker.
- No decision unsourced: the milestone itself, every change it forces on the existing plan, and every skipped step have a Decision log row synced to Linear.
- Budget: one pre-mortem (two passes) and one plan review per milestone, plus one rerun after a material fold. Never pay for extra credits: wait for a reset.
