---
name: autopilot-continue
description: Resume an autopilot run exactly where it stopped, in a new or compacted coordinator session, without asking setup questions again. Finds the project from the nearest .autopilot/state.json, re-records the coordinator account, refreshes quotas, restarts the pipeline and wait-approval jobs if they died, recovers interrupted tickets, reads the Linear handoff comment, then hands over to the /autopilot-run loop. Use when the user says "/autopilot-continue", "autopilot continue", "continue the autopilot", "resume the autopilot", or "pick up where it was".
---

# Autopilot: continue

**Caveman, always.** Your first action, before any other tool call: invoke the `caveman` skill (`/caveman`), and keep it for the whole session. Every Agent-tool prompt you write starts with "Invoke the `caveman` skill first and answer terse." Persisted text stays plain prose.

This is the resume entry point of `/autopilot-run`. The run itself is unchanged: after the steps below you are the coordinator and follow `/autopilot-run` (its SKILL.md is next to this one: `../autopilot-run/SKILL.md`; read it now, all of it, it is the rulebook). `bin/<x>` means the `bin` directory next to this SKILL.md (the shared `bin/` of the linear-autopilot repo); resolve it once and use absolute paths.

Setup is already done: never ask the owner the setup questions again (project, push, scope, exclusions, tiers). Everything you need is in `.autopilot/state.json`, `PLAN.md` and Linear. Ask only for something that is truly missing from all three, and record the answer as a decision.

## Steps

1. **Find the run.** The nearest `.autopilot/state.json` from the working directory (or `$AUTOPILOT_REPO`). None: say so and stop; the owner wants `/autopilot-run` (a first run) instead. Check out the project branch recorded there (`autopilot/<project-slug>`) if it is not the current one; never touch the default branch.
2. **Who you are.** `bin/run-model whoami --record`: this session's account becomes the protected one. If it differs from the previous `coordinator_account`, cooldowns recorded under the old account are stale: `bin/run-model reset` + `smoke` for it.
3. **Quotas and models.** `bin/run-model usage --apply`, `bin/run-model discover --apply`, `bin/harness check`, `bin/alert list`. Report CRITICAL alerts and what blocks a role.
4. **Where it was.** `bin/pipeline status` (the bars and every in-flight ticket), `bin/decision check` (fix a `pending` entry first), `bin/decision list` (decisions since the last handoff), the latest project-level "handoff / resume point" comment in Linear, `git log --oneline -10` on the project branch, `git worktree list`.
5. **Restart the clock.** `bin/bgrun ls`. If `pipeline` is not running, start it as in `/autopilot-run` Setup step 8 (`bin/bgrun --name pipeline -- '<bin>/pipeline run'` in the tool's background mode), and `<bin>/pipeline wait-approval` as a second background job. Never start a second `pipeline run`.
6. **Recover interrupted tickets.** For an in-flight ticket outside the clock whose model run died with the old session (no process for it in `ps`): `bin/rebase-wt <worktree>`, then a new round whose findings say "the previous round was interrupted, not rejected: keep the correct partial work in the tree and finish". Count it as a round. Approvals already in `.autopilot/pipeline/approved.txt` are merged now with `bin/pipeline merge`.
7. **Keep the machine up.** `caffeinate` (macOS) or `systemd-inhibit` (Linux) in the background, AC power check, `bin/docker-up` if the checks use containers.
8. **Tell the owner, in a few lines:** branch and compare/PR link, done since the last handoff, in flight, next in order, any `DECISION NEEDED:` lines, then `bin/pipeline status`. Post a short "resumed" note on the Linear handoff comment thread.
9. **Continue.** From here follow `/autopilot-run` from "The loop" onwards: same golden rules, same heartbeat, same end of session. The session ends only when every ticket in scope is done or explicitly blocked.
