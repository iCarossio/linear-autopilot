---
name: autopilot-idea
description: Capture the owner's quick product ideas in a Linear project without planning them. Each idea becomes one issue in the project's "Ideas (unscheduled)" milestone (label idea, state Backlog) with the owner's words verbatim, a row in PLAN.md's idea backlog and a sourced decision. Ideas never enter the autopilot queue or any ETA; later one or several are promoted into a real milestone that goes through pre-mortem, plan review and approval. Use when the user says "idea:", "add an idea", "note this idea", "/autopilot-idea ...", lists ideas for later, or asks to list, adopt or promote ideas.
---

# Autopilot: idea

**Caveman, always.** Your first action, before any other tool call: invoke the `caveman` skill (`/caveman`), and keep it for the whole session, including after a resume or a context compaction (invoke it again then). If it is not installed, follow its rules anyway: answer first, no ceremony, commands, paths, numbers and errors verbatim. Every subagent you start talks caveman too: `run-model` adds the rule to every model prompt by itself, and every Agent-tool (subagent) prompt you write starts with "Invoke the `caveman` skill first and answer terse." Persisted text stays plain prose: code, comments, docs, commits, Linear, `PLAN.md`.

An idea is not work. Capture it immediately, exactly as the owner said it, and get out of the way: no planning questions, no KPIs, no pre-mortem, no review, no estimate, no queue, no ETA. Planning happens only when the owner promotes ideas into a milestone.

`bin/<x>` below means the `bin` directory next to this SKILL.md (`~/.claude/skills/autopilot-idea/bin/<x>` after `install.sh`). The project is found through the nearest `.autopilot/state.json` (or `$AUTOPILOT_REPO`); it needs `project_id` and `team` (a project created by `/autopilot-plan` or set up by `/autopilot-run`) and a `PLAN.md`.

| Script | Role |
|---|---|
| `bin/idea` | `add "<title>" --words "<verbatim>" [--note] [--related ENG-1,...]`: the Ideas milestone and `idea` label (created if missing), one Backlog issue, PLAN.md backlog row, decision, project content. Idempotent per title. `list [--json]`, `adopt ENG-1,...`, `promote ENG-1,... --id --name`. |
| `bin/milestone` | `add <spec>` (driven by `/autopilot-milestone`): the promoted spec goes through pre-mortem, plan review and approval; on approval the promoted ideas are closed as duplicates of the new tickets. |

## Capture (`/autopilot-idea ...`, "idea: ...", "add an idea")

1. Split the message into ideas: one issue per distinct idea. Two ideas the owner ties together ("same private locations as ...") stay two issues, linked with `--related`.
2. For each, without asking anything:
   ```
   bin/idea add "<short title, 4-10 words>" --words "<the owner's words for this idea, verbatim>" \
     --note "<one line of scope: what it would cover>" [--related <identifiers of related ideas>] --by <owner>
   ```
   - `--words` is the owner's text, copied, never paraphrased or fixed (typos and all). It is the decision's source.
   - The note is one line, yours, to make the idea findable later. No design, no estimate.
   - Related: ideas captured in the same message (pass the identifier printed by the earlier call) or existing ideas (`bin/idea list`).
3. Reply with one short table, nothing else:

   | Issue | Idea |
   |---|---|
   | ENG-40 | RBAC like Claude Cowork |

A rerun with the same title prints `already captured` and creates nothing. A failed step (network, Linear) is resumed by running the same command again.

## Other commands

- `bin/idea list [--json]`: identifier, state, title, related ideas, read from Linear.
- `bin/idea adopt ENG-1,ENG-2 --source user:"<words>"`: for ideas collected before this skill existed (an `idea` label, no milestone): moves them into the Ideas milestone, adds the label, sets Backlog, adds their backlog rows, logs one decision. Refuses scheduled work (a ticket of a milestone, queued, in flight or done).
- **Promote** (the owner schedules one or several ideas): run `/autopilot-milestone ENG-1,ENG-2` (or name the ideas). That skill calls `bin/idea promote ENG-1[,ENG-2] --id <slug> --name "<milestone name>"`, which writes the spec skeleton `.autopilot/plan/milestones/<id>/spec.json` (the ideas quoted, one placeholder ticket per idea with `from_idea`, KPIs, plan and ticket instructions marked TODO, `from_ideas`), then runs its intake gate (measurable KPIs), pre-mortem, plan review and the owner's approval. The real add refuses a spec that still has a TODO. On approval each promoted idea gets a comment, a duplicate relation to its new tickets, the Duplicate (else Canceled) state, a struck-through backlog row, and leaves `ideas.issues`. Never promote and plan inside this skill.

## Rules

- Never schedule an idea: it is not added to `queue`, `stages`, `milestones`, `blockers` or `est`. `bin/eta`, `bin/milestone recompute/list/sync` ignore the Ideas milestone and its issues; `sync` never gives it a target date and mentions the idea count in one line of the project update.
- Never create an idea issue by hand or through `bin/linear import`: `bin/idea` handles the missing label and Linear's "Entity not found" right after a creation (retried with backoff), which a hand-made flow gets wrong.
- An idea arriving during `/autopilot-run` is captured the same way and changes nothing in the run.
