---
name: autopilot-run
description: Execute a planned Linear project autonomously over a long unattended session, ticket by ticket, about one commit per ticket. The coordinator (this session) only orchestrates. Every ticket is planned at high tier, plan-reviewed by a high-tier model of another vendor, implemented by a cheap or free model and adversarially reviewed by two models of other vendors, with the tier picked from the quotas available right now. Reuses every model the minute its quota resets and never pays for extra credits. Use when the user says "run the autopilot on <project>", "implement the Linear project", "/autopilot-run", or "continue the autopilot". Requires a roster from /autopilot-init; a project planned with /autopilot-plan runs best but any Linear project works.
---

# Autopilot: run

You are the **coordinator**. You read the Linear project, write briefs, dispatch work to other models, read their one-line results and short verdicts, run checks, judge disputes, commit, and update Linear. The session lasts hours, often with the user away: it ends only when every ticket in scope is done or explicitly blocked.

`bin/<x>` below means the `bin` directory next to this SKILL.md: `~/.claude/skills/autopilot-run/bin/<x>` after `install.sh`, or `${CLAUDE_PLUGIN_ROOT}/skills/autopilot-run/bin/<x>` when installed as a plugin (both resolve to the shared `bin/` of the linear-autopilot repo). Resolve it once at setup and use absolute paths in every command. The roster, accounts and cooldowns live in `~/.config/linear-autopilot/models.json` (`$AUTOPILOT_CONFIG_DIR`), created by `/autopilot-init`. Per-project state lives in `<repo>/.autopilot/` (gitignored via `.git/info/exclude`).

| Script | Role |
|---|---|
| `bin/run-model` | Runs one model CLI under a watchdog through its harness adapter, stores the full output in a file, prints one JSON line, falls back through the pool, records cooldowns. `usage`, `health`, `wait`, `smoke`, `discover`. |
| `bin/mkbrief` | `mkbrief <impl\|review\|plan\|diag> <ISSUE> <round> <ticket.md> [findings.md]`: fills a prompt template. `WT=<worktree>` sets the working dir. |
| `bin/review` | `review <ISSUE> <round> <brief>`: 2 reviewers from distinct vendors in parallel, compact verdicts, writes `.autopilot/out/<ISSUE>-findings-<round>.md`. Exit 0 approve, 1 changes, 2 no reviewer. `POOL=`, `EXCLUDE=`, `WT=`. |
| `bin/finish` | `finish <ISSUE> "<subject>" "<body>"`: commits in the worktree, cherry-picks onto the project branch, removes the worktree, pushes if allowed. Exit 3 conflict, 4 push failed. |
| `bin/rebase-wt` | `rebase-wt <worktree>`: stash, fast-forward to the project branch, pop. Exit 3 on conflict. |
| `bin/eta` | Progress bar and ETA for the scope, from `stages`/`est` in state.json. |
| `bin/state` | `state get|set|del|push|pull|merge`: locked edits of `.autopilot/state.json`. Use it for every state change while runs are in flight: `run-model` writes implementer history concurrently and a plain file write would lose it. |
| `bin/linear` | Linear GraphQL fallback (`LINEAR_API_KEY`) when this harness has no Linear MCP tools: `issues`, `comment`, `state`, `project-update`. |
| `bin/codex-reset` | Redeems a Codex usage reset through the TUI; refuses unless the weekly window is exhausted; per-session user permission. |

Helper scripts find the project through the nearest `.autopilot/state.json` (or `$AUTOPILOT_REPO`).

## Golden rules

1. **Never implement and never review yourself.** Your budget keeps the session alive. Exceptions: a mechanical fix of 5 lines or fewer that unblocks everyone, or when every implementer is cooling down. Before touching the tree, record yourself as an implementer of that ticket (`bin/state implementer <ISSUE> <your roster key>`), so that no account or harness of your model reviews it; log the edit in the commit body.
2. **Implementer and reviewer are always different models**, and the two reviewers come from two different vendors. Enforced in code, fail closed: `run-model` records every implementer before it runs and refuses a review run by any of them (or by the same model id on another account), `bin/review` never relaxes the distinct-vendor rule, discards a verdict from a reviewer that modified the tree or returned an invalid verdict, and treats an approve that carries a blocking finding as changes required. Plan reviews (`POOL=plan_review`) exclude the planner's vendor, taken from `coordinator` in state.json.
3. **Keep your context small.** Read the JSON line, the final `STATUS` block (`tail -5`), the verdict lines, `git status --short`, `git diff --stat`, and the last 40 lines of a failing check. Grep for a suspicion rather than reading a diff. Reviewers read the code, you don't.
4. **State lives on disk.** Update `.autopilot/state.json` after every step through `bin/state` (`inflight` per ticket: worktree, round, implementer key). Linear comments record decisions for humans. A fresh session resumes from Linear plus state.json alone.
5. **Never get stuck, never stop.** The runner falls back on quota/timeout/idle/bad output. If a whole pool is down, wait in the background (see "Waiting"), keep other work moving, and always keep at least one background job (a heartbeat if nothing else) so you are woken up.
6. **Never launch a model CLI by hand**, always through `run-model` (stdin closed, own process group, watchdog). Every other long command runs in the background with `< /dev/null`.
7. **Safety:** dedicated branch, never force-push, never rewrite history, push/PR only if the user said so. Discard with `git stash push -u -m "autopilot-failed-<ISSUE>"`, never `git reset --hard` or `git clean`.
8. **You are the judge.** Reviewers and implementers are often right and sometimes wrong in both directions. Verify cheaply before acting on a claim you doubt, and reject shortcuts even when every check is green (see "Judging").
9. **Terse everywhere.** Load the `caveman` skill if available and keep it for the session; briefs ask subagents for terse answers. Persisted text stays plain prose: code, comments, docs, commits, Linear.

## Setup (once per project)

1. If `<repo>/.autopilot/plan/` exists (the project came from `/autopilot-plan`): read `PLAN.md`, `premortem.md` and `tickets.created.json`; the guardrails there are rules for every ticket. The plan skill may already have created the branch and seeded `state.json`: reuse both (steps 4 and 6 then only fill what is missing, never overwrite `queue`, `sizes`, `stages`, `critical_path`). Otherwise ask only what you can't infer: Linear project, repo path, push allowed (default no), scope (milestones), tickets to skip, check commands not discoverable. Then the user may leave: never ask again during the run; decide, and record the decision in Linear and in the repo's agent docs.
2. `bin/run-model usage --apply` (exact quota resets per harness and account), `bin/run-model discover --apply`, then `bin/run-model smoke <key>` for every healthy model in the pools you will use. If a pool has fewer than two healthy vendors, say so to the user before they leave.
3. Read the project and its issues (milestones in order, then sort order, `blockedBy` relations). Linear MCP tools when this harness has them, else `bin/linear issues <project-id>`.
4. Create `autopilot/<project-slug>` from the current branch, unless it exists (then check it out and continue from it).
5. Discover the checks (package.json, Makefile, AGENTS.md / CLAUDE.md, the `checks` column of the plan). If the repo has none yet, checks are per ticket (a `CHECKS:` line in the ticket file) until a scaffold ticket adds them.
6. Write `.autopilot/state.json` from `templates/state.json` (repo root of this skill) if it does not exist, add `.autopilot/` to `.git/info/exclude`. Set `coordinator` to your own roster key (plan reviews exclude its vendor; without it `bin/review` refuses a plan review) and `critical_path` from the plan.
7. **Make the work visible.** Everything lands on `autopilot/<project-slug>`, never on the default branch. If push is allowed, open a draft PR/MR from that branch at setup, titled with the project name, and keep its description updated with the done list. Every user update and Linear summary includes the branch name and the compare URL or draft PR link, and says that nothing is merged into the default branch.
8. Keep the machine awake (`caffeinate -dimsu -t <seconds> < /dev/null` on macOS, in the background) and check it is on AC power on each heartbeat.

## Ticket files (your briefs' source)

For each ticket write `.autopilot/tickets/<ISSUE>.md` from `templates/ticket.md`: `# Title`, the Linear description rewritten as precise instructions, an explicit `CHECKS:` line, `**Acceptance**`, the pre-mortem guardrails that apply, and COMMON RULES. A good ticket file is the cheapest way to save rounds: exact inputs (files, formats, counts), the architecture decision when the ticket shapes the project, what not to touch, its own port and container name when it starts a server, and the notes of the tickets it builds on (`docs/notes/<ISSUE>.md`). After a round, append "Coordinator decision: ..." lines for every dispute you settled.

## The loop (one ticket)

1. **Pick** a ticket whose blockers are Done (or ordering-only, see "Parallelism"). Linear: In Progress. Create the worktree from the current head and install dependencies there.
2. **Plan** (high tier). You write the ticket file; then a high-tier model of another vendor reviews it adversarially before any code: `bin/mkbrief plan <ISSUE> 1 <ticket.md>` then `POOL=plan_review EXCLUDE=<your key> WT=<wt> bin/review <ISSUE> plan-1 <brief> 1`. Fold accepted findings into the ticket file, reject the rest in writing, at most 2 plan rounds. Before writing a plan, check the repo's real conventions with a few greps: wrong paths are the most common plan blocker. Skip the plan review only for mechanical tickets.
3. **Size it.** Split a ticket that needs more than ~400 changed lines or several independent parts into sub-steps (one commit each); group tiny tickets that touch the same files. One ticket per commit when reasonable, never at the cost of a clean history.
4. **Brief:** `WT=<wt> bin/mkbrief impl <ISSUE> <n> .autopilot/tickets/<ISSUE>.md [findings]`.
5. **Implement** (cheap or free): `bin/run-model run implement <brief> .autopilot/out/<ISSUE>-impl-<n>.md --cwd <wt> --issue <ISSUE> [--prefer <key>] [--pool implement_critical | fix_mid | --escalate]` in the background (`--issue` is what ties the implementer to the ticket for the review exclusions; the brief name `<ISSUE>-impl-<n>.md` works too). Statuses: `ok`, `quota`, `timeout`, `idle`, `waiting_input`, `error`, `bad_output`, `unavailable`, `all_failed` (see "Waiting"), `docker_hung`. Note the implementer key from `tried`.
6. **Check** yourself in the worktree, quietly (`> .autopilot/out/check-<ISSUE>.log 2>&1; echo rc=$?`). Look at `git status --short`: unexpected files are the cheapest early warning. Failure: next round with the log tail as findings.
7. **Review:** `WT=<wt> bin/mkbrief review <ISSUE> <n> <ticket.md>` then `POOL=<review_mid|review_high> WT=<wt> bin/review <ISSUE> <n> <brief>` in the background. `review_high` for architecture-shaping or cross-cutting tickets (anything later tickets build on, data model, security); `review_mid` for the rest. Exit 0 (two valid approvals): step 8. Exit 1: next round with `.autopilot/out/<ISSUE>-findings-<n>.md` (edited by you: drop findings you rejected, add coordinator decisions). Exit 2 (`NO_REVIEWER` or `INCOMPLETE`: not enough valid verdicts): retry when a reviewer of another vendor is healthy (`bin/run-model wait`). Only when a whole vendor is down for hours may you accept one valid approval, explicitly: `MIN_REVIEWS=1` (a documented degraded mode for code reviews only; `bin/review` refuses 0), and say so in the Linear comment. Plan reviews take `cost: high` models only; `ALLOW_MID=1` is the degraded mode there. Exit 3: a reviewer committed or moved HEAD (`HISTORY CHANGED`, nothing is rewritten automatically) or the tree could not be restored; inspect the worktree before anything else. Never edit the worktree yourself while a review runs there: the modified-tree check covers the whole directory.
8. **Commit:** `bin/finish <ISSUE> "<type>(<scope>): <title>" "<what changed. Implementer: <models>. Approved by <models> after <n> rounds.>"` (the worktree must exist; `NO_WT=1` commits in the repo itself). Exit 3: see "Merging". Exit 4: fix the push before anything else. Then run the full checks on the project branch: a merge can break what each worktree passed alone.
9. **Linear:** comment (commit, what was built, decisions, numbers, implementer and reviewers, rounds) and move to Done. Update state and `bin/eta` inputs.

**Rounds:** round 1 = implementation from the ticket's pool (`implement_critical` on the critical path, `implement` elsewhere); round 2 = the fix of the review's findings from the same pool; if the second review still asks for changes, round 3+ = `--pool fix_mid`; the last round (5) or a ticket stuck on the same failure = `--escalate`. 5 rounds in total; a merge-only round after a rebase does not count. The pool, not you, picks the model: pools are ordered by preference and skip cooled-down models, so the tier adapts to the quotas available right now.

## Resuming after the coordinator session ends

**Linear is the restart source.** At every phase change keep Linear in sync: ticket status, a short status comment on in-flight tickets (stage, worktree, round, model), and a project-level "handoff / resume point" comment (done, in flight, next in order, where state.json lives, decisions). Secrets are never written to Linear.

A new coordinator session finds `inflight` tickets whose model runs died with the old session (no process for them in `ps`). For each: `rebase-wt`, then a new round whose findings say "the previous round was interrupted, not rejected: keep the correct partial work in the tree and finish". Count it as a round. After switching accounts, cooldowns recorded under the old account are stale: `reset` + `smoke`.

## Parallelism

- Run independent tickets at the same time, each in `git worktree add -b autopilot/<ISSUE> <worktrees_dir>/<ISSUE> HEAD`. 3 to 6 in flight is a good level; the bottleneck is review capacity and quotas.
- Spread implementers (`--prefer <key>`) across models and accounts; a model may run several tickets concurrently.
- Parallel tickets must not edit shared docs: they write `docs/notes/<ISSUE>.md`. Merge the notes into the agent docs in a dedicated docs step later.
- A ticket whose Linear blocker is only an ordering preference may start early: say so in a Linear comment.
- Before a later round of a worktree ticket, and before checks that depend on newly merged code, `bin/rebase-wt <wt>` (serialised across worktrees by a repo-level lock; the stash is found by its own message, never by stack position); then check that every untracked file of the ticket came back (a path that now exists on the branch is silently not restored by `stash apply`; recover it from the kept stash's untracked tree).
- Never run a review in parallel with your own checks in the same worktree (reviewers may start or stop servers there). Check first, then review.
- Before running checks, make sure nothing of the implementer still runs (no process with the worktree path in `ps`; remove its containers).
- Collisions to prevent up front: fixed ports and container names, shared generated files, two tickets editing the same layout or manifest. When the merged branch fails because parallel tickets disagree, create a small integration follow-up ticket in Linear with `blocks`; don't hide it in the next ticket.

## Merging (cherry-pick conflicts)

- `package.json` / lockfiles: take the **union** of both sides' scripts and dependencies, dedupe, then reinstall to regenerate the lockfile. `.gitignore`: union.
- Anything else: resolve if trivial and obvious, otherwise `git cherry-pick --abort`, then `bin/rebase-wt <wt>` (the ticket is already committed in its worktree: it rebases that commit onto the project branch, exit 3 with the conflicting files if it cannot), re-dispatch a merge round if needed (`mkbrief` then reviews the committed work plus the fixes, from the merge-base), and `finish` again: it integrates every commit of the ticket branch that is not on the project branch, and commits nothing when there is nothing new.
- After resolving: `git add`, `GIT_EDITOR=true git cherry-pick --continue`, remove the worktree and branch, run the full checks, push.

## Judging (what makes the night succeed)

- **Shortcuts are blockers even when checks pass:** copied expected outputs or snapshots, hard-coded test answers, checks that pass by construction, test-only code shipped in the product, a harness that reads the expected output to shape what it captures, a literal list of cases that changes behaviour for exactly the failing ones. Send it back with a precise "coordinator blocker" finding, and ask for a test that makes that class of shortcut fail.
- **Fix the class, not the instance:** when a reviewer finds a bug a harness should have caught, ask for the harness change and a test that covers the class.
- **Invented fixtures pass by construction.** Require fixtures sampled verbatim from the real data, plus one test that round-trips a real record.
- **Reviewers can be wrong.** Typical false positives: claims about a library contradicted by a quick run, findings that contradict a documented coordinator decision, demands outside the ticket's scope. Verify with one command, reject in writing (Linear comment + ticket file), approve on the remaining verdict. Hypothetical inputs absent from the real data are `minor`; don't spend more than one round on them.
- **Suggested patches are findings, not commands.** They get the same check as any other finding before they go into a findings file.
- **Skip the review when you already found a blocker.** Reviews cost as much as implementations.
- **Flaky checks are defects.** Ask for determinism and the root cause.
- **Human decisions:** when a requirement needs information no model can have, ship the safe default, list it as an open human decision in Linear and the agent docs, and approve.
- **Pre-mortem guardrails are acceptance criteria.** A ticket that violates a guardrail from `PLAN.md` is not done, whatever the reviewers say.

## Roles, tiers and quotas

Pools are lists in `~/.config/linear-autopilot/models.json` (`bin/harness pools`); every entry has a `cost` (high, mid, cheap, free) and optionally `no_implement`. Any model can take any role, subject to the hard rules:

| Role | Pool | Who |
|---|---|---|
| Coordinator, planner | the coordinator session | you |
| Review of a ticket plan | `plan_review` | high tier, another vendor than you |
| Implement a critical-path ticket (and its fixes) | `implement_critical` | best cheap/mid models first |
| Implement anything else | `implement` | free and cheap first |
| Fix after a second failed review | `fix_mid` | mid tier |
| Rescue a stuck ticket (last round) | `implement_escalation` | mid/high tier that may implement |
| Adversarial review, normal tickets | `review_mid` | mid and cheap, two vendors |
| Adversarial review, architecture / cross-cutting / final | `review_high` | high tier, two vendors |
| Last resort review | `review` | free |

Hard rules: `no_implement` models (the expensive high tier) never implement unless the user grants a per-session exception (`ALLOW_IMPLEMENT=<key>`, recorded in state.json notes). Spend the expensive mid tier (e.g. a subscription with a small quota) only to save a situation. Use every included quota to the max, never pay more: subscriptions and free tiers only, never top-ups or paid per-token ids. Prefer pool selection (`--prefer <key>`) over `--model <key>`: pinning skips the pools, so models that come back after a reset are never used again. A model that misbehaves (empty runs, ignores the output format, edits during review, loops) is cooled down automatically; move it down a pool permanently and say why in `changelog` if it repeats.

Watch quotas with `bin/run-model usage` (the `/autopilot-usage` skill explains the output). When your own vendor's window is tight, move its models after the free ones in the implement pools. Expect whole accounts to go down together, and keep at least two vendors able to implement and two able to review.

## Waiting (never stop because of credits)

- `all_failed` or `review` exit 2: `bin/run-model health` shows the first cooldown end. Meanwhile do anything else.
- **Reuse every model the minute it is back.** Cooldowns hold the exact reset (from `usage --apply` or parsed from the quota error). Put blocked work behind `bin/run-model wait <pool> [EXCLUDE]` in a background job: it sleeps until the earliest cooldown end and prints the first healthy key, e.g. `bin/run-model wait review_high >/dev/null && POOL=review_high ... bin/review ...` with the tool's background mode. Never a foreground sleep.
- Quota cooldowns without a known reset last 60 min; when the user says a model works again, `reset` + `smoke`.
- Keep a heartbeat (`sleep 1500` in the background) whenever jobs run: on each heartbeat check that every in-flight log moved recently, run `usage --apply`, and renew it.
- When a CLI announces its reset time, don't smoke it before: schedule one background job that sleeps until just after the reset, then `reset` + `smoke`.
- macOS has no `timeout`: bound a background command with an `until` loop on its end condition and `kill` it.
- A run that returns `docker_hung` is an environment stall, not a model failure: recover Docker (see `references/lessons.md`), `reset` any model cooled during the hang, relaunch.
- Background jobs launched with `&` inside a command don't notify you; use the tool's background mode, or wrap the job with a background `until` loop that waits for its result file.

## ETA (always shown)

Every message to the user, every heartbeat summary and every Linear project summary starts with the first line of `bin/eta` in a code span (run it, never guess). Keep its inputs current in state.json: `stages` (ordered list of parallel groups, including your own final steps), `est` per ticket (`{"min": minutes left, "at": ISO}`, set when a round starts and re-set when a review sends the ticket back), `sizes`, `queue` without done or in-flight tickets. When asked for a tighter bound, name what drives the error rather than inventing precision.

## Self-update

- `bin/run-model discover --apply` at setup, every 10 tickets, and on "model not found": newer model in the same family and tier, smoke-tested before switching. Models without a listing command (e.g. Claude) are updated by hand.
- Improve the procedure during the session when you learn something (a failure pattern, a better prompt, a missing helper): edit this skill, `prompts/`, `bin/`, keep changes small, log them in `models.json` `changelog`. Project-specific lessons go to `references/lessons.md`, not here. Edit `models.json` atomically (temp file + rename); `run-model` reloads it before saving health.

## run-model behaviour (reference)

- Watchdog: kills a run that asks for input, exceeds its timeout (`implement` 4800 s, `review` 1800 s), or stays silent for `idle` (900 s) while nothing changes in the working directory.
- `bad_output`: exit 0 but no `STATUS: done|partial|blocked` (implement) or `"verdict"` (review) at the end. The model is cooled down and the next one runs.
- Environment: `CI=1 NO_COLOR=1 TERM=dumb PYTHONDONTWRITEBYTECODE=1`, plus the adapter env and the account env (e.g. `CODEX_HOME`).
- Reviewers run with full rights but must not change the tree; `bin/review` snapshots the tree and restores it (`TREE RESTORED`). Discard the verdict of a reviewer flagged `modified tree`.
- How each CLI is invoked: `bin/harness adapters` (one JSON per harness, user overrides in `~/.config/linear-autopilot/harnesses/`).

## When something looks familiar

`references/lessons.md` (in the skill repo) holds the failure patterns met on real runs, by symptom: ghost sessions editing finished worktrees, Docker hangs under parallel capture runs, the machine sleeping on battery, stash pops dropping untracked files, invented fixtures, per-case harness tuning. `references/fanout-qa.md` is the procedure for big failure lists (parallel read-only diagnosers, one todo list by root cause, sub-tickets). Read the matching section when a symptom appears; don't load them up front.

## End of session

When the scope is done, or the user is about to come back: run all checks on the branch, make sure the agent docs describe the current state (dispatch a docs ticket that merges `docs/notes/*`), post a summary on the Linear project (done, in progress, not started, blocked with reasons, open human decisions, KPI status from `PLAN.md`, models used, commit range, branch + compare URL or draft PR link), and tell the user the same in a few lines. Keep working on what is still unblocked unless the user says stop.
