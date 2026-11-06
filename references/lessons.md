# Lessons from real runs (by symptom)

Read the section whose symptom you observe. These are facts measured on real projects; dates mark when they were learnt. Add yours at the end, with the date.

## Files change in a worktree after a round finished; check runs die with rc=143; servers vanish

**opencode ghost sessions (2026-10-25).** Without `--standalone`, `opencode run` is a client of `opencode serve --service`: sessions and their shell jobs run in the service, keep going after the client exits or is killed, and are resumed when the service restarts. Ghost sessions from earlier rounds then edit worktrees after "done" and run things like `pkill -f "npm run parity"` against every checkout. `run-model` passes `--standalone` (the adapter does). If ghosts exist: `opencode service stop`, keep it stopped (check with `pgrep -fl "opencode serve --service"`, never `opencode service status`, which starts the service; an interactive `opencode` TUI left open also restarts it), and ask the user before deleting sessions (`opencode session list` / `delete`). After a ghost, re-check every worktree it could touch: a "done" round may have been partly reverted.

## `docker version` blocks; runs report `docker_hung`; serve tests hang for everyone

**Docker can hang under many parallel container start/stop cycles (2026-10-25).** `bin/docker-up --restart` probes with a bounded `docker version` and, when the runtime runs but the daemon is silent, restarts it (on OrbStack `orb stop && orb start`, because `orb restart docker` may hang too; containers survive). If it still does not answer, kill the stuck docker clients and run it again. Implementers must never restart Docker themselves: the brief says to stop and report. Then restart the stuck checks and rounds, and `run-model reset` any model cooled during the hang. With a sufficiently sized VM (e.g. 32-64 GB), up to 5 Docker-heavy jobs at a time were fine; the hangs came with small VM memory and 3 capture-heavy suites at once.

## Docker is down after the machine restarted

**OrbStack does not always start at login (2026-11-01).** After a reboot every run died and `docker` failed with `connect: no such file or directory` on the socket. `bin/docker-up` starts the runtime and waits until the daemon answers; run it at setup, on each heartbeat and when resuming.

## Everything stalled for hours overnight, logs stopped at the same minute

**The machine slept on battery overnight.** On macOS, `caffeinate` does not prevent sleep on battery; `pmset -g log` shows `Entering Sleep ... Using Batt` (on Linux, check logind/systemd-inhibit). At setup and on each heartbeat check that the machine is on AC power (`pmset -g batt` on macOS, `/sys/class/power_supply` or `upower` on Linux); if not, tell the user at the next turn.

## A ticket's untracked file disappeared after `rebase-wt`

`git stash pop` silently does not restore an untracked file whose path now exists on the branch (e.g. a notes file both tickets create). Recover it from the stash's untracked tree (`git show <stash>^3:<path>`, or from the dangling commit after a drop) and merge the two versions.

## A pre-commit hook fails in `finish` although the worktree passed

"package doesn't seem to be present in your lockfile" (or missing generated code in a fresh worktree) means the checkout's dependencies are stale, not the change: run the repo's install (`yarn install --immutable`, then its codegen) and commit again before sending anything back to the implementer.

## Checks fail with `ERR_CONNECTION_REFUSED` storms

A leftover `cmd &` from the implementer restarting the same server mid-run, or a reviewer starting/stopping servers in the same worktree, or two wrappers rebuilding the same `dist/` while a third serves it. Fixes: never review and check the same worktree at the same time; before checks, make sure nothing of the implementer still runs (`ps` for the worktree path, `docker rm -f <name>`); build once and make sure no wrapper rebuilds (`serve:prod` instead of a no-build serve); each suite gets its own port, container name and checkout.

## Regeneration overwrote a ticket's generated output

Regenerate and check idempotency only with the repo's own pipeline command (as named in the ticket notes), never with a remembered list of scripts: an older list silently drops newer steps.

## All tests green, converter still wrong on real data

**Invented fixtures pass by construction (2026-10-27).** A content sync read fields that live in an undocumented metadata table and a redirects format never used in production, with all tests passing on fixtures the implementer wrote. Require fixtures sampled verbatim from real snapshots, plus one test that round-trips a real record against the current output.

## The same failing cases get "fixed" round after round with a new list each time

**Per-case harness tuning.** A literal list of pages/ids in capture or compare code that changes behaviour for exactly the failing cases, then a "metadata" file, then a "generator" with hard-coded exclusions. Ask for the general rule (derived from the content or from metadata recorded with the baseline) and a test that fails on literal paths in the harness. When the expected output itself is inconsistent and no recorded fact explains it, stop the loop early: decide that those cases become explicit, reviewed exception entries (url, field, reason) and every other case follows the derived rule. Verify exception claims against the source data with one grep before accepting them.

## A reviewer wiped a ticket's work

**Reviewers can modify the tree (2026-10-25).** A free-tier reviewer ran `git stash`, a generator, then `git stash drop && git checkout -- .`. `bin/review` snapshots and restores the tree and prints `TREE RESTORED`; discard the verdict of the reviewer flagged `modified tree`. A dropped stash is still recoverable: `git fsck --no-reflog --unreachable | grep commit`, find the `WIP on <branch>` commit, `git stash apply <sha>`.

## Reviewer verdicts contradict a quick run

Typical false positives seen: "Go regexp rejects `(?:...)`" (it doesn't), "fails" claims disproved by the saved report, findings that contradict a documented coordinator decision, demands outside the ticket's scope (third-party embeds, data owned by a human). One command, then reject in writing.

## Codex usage limits

Codex models on one ChatGPT account share one usage limit (5 h and weekly windows); `run-model usage` reads them from the session logs of each `CODEX_HOME`. `bin/codex-reset` redeems a "Full reset" through the TUI (`/usage` -> Redeem reset -> the earliest-expiring one), only with the user's per-session permission and only when the weekly window is at 100%.

## Grok on quota

A 402 balance message is a quota, not a billing request: it cools down and comes back at the subscription renewal shown by `/usage` in an interactive `grok` session (the CLI `grok usage` needs a session id). Set the cooldown to that time instead of retrying hourly.

## OpenRouter through opencode

Only `:free` ids when the account has no credits (never `openrouter/auto` or paid ids). A model missing from models.dev must be declared under `provider.openrouter.models` in `~/.config/opencode/opencode.jsonc`.

## Model ranking measured on real tickets (2026-10-25)

Best first: Claude Opus 5.5, Codex gpt-6.1-sol, Codex gpt-6.1-terra (good mid-tier compromise), Codex gpt-6-luna, Grok 4.7, Claude Sonnet 5.5, opencode-go beam-free, Poolside Laguna S 2.1 free (OpenRouter), opencode-go DeepSeek flash, opencode-go GLM flash. Not worth running: Nemotron 3 Ultra free, OpenRouter free router, the opencode free flash models, Antigravity Claude Sonnet, Mistral Vibe (as implementer). Re-measure on your own tickets; this is one project's view.

## A review was killed as `quota` while the log shows normal activity

**Quota phrases echoed by the model (2026-10-29).** A reviewer that reads this repository (or any file with "usage limit" / "rate limit exceeded" in it) prints those phrases into its log; the watchdog took them for the CLI's own quota loop and killed the run. `run-model` now counts only short plain lines without code or quote characters, three of them, before calling a run `quota`; adapter `quota_patterns` classify the final exit only. If it happens again: `run-model reset <key>` and relaunch.

## A reviewer was flagged `modified tree` but changed nothing

The fingerprint covers the whole working directory (tracked state, untracked content, HEAD). Editing the repo yourself while a review runs there (a hot fix to a script, a doc update) flags that review and discards its verdict. Edit in another checkout, or wait for the review to finish.
- 2026-11-04: `run-model wait <pool> <excluded>` knows nothing about vendors. For a plan review it returned `claude-opus-b`, another account of the planner's vendor, and `bin/review` then refused with NO_REVIEWER. Pass every key of the excluded vendor (all `claude-*` keys, including `-b` accounts) until `wait` takes a vendor filter.
- 2026-11-04: the ETA kept slipping while the tail of `stages` held eight single-item stages that nobody had re-checked. Three of those items were independent: one only needed an owner token for its live run, another only needed a plan, and the third only conflicted on generated files. `bin/eta` now prints `REPLAN:` lines (slip, serial tail, idle lanes); act on them.
- 2026-11-04: implementers that run full suites under load hit their watchdog and leave no STATUS block. One left an orphaned test runner suite, reparented to PID 1 (init / launchd), that kept running in the worktree the coordinator was about to check. After any `timeout`, list `ps -Ao ppid,pid,command | awk '$1==1'` filtered on the worktree paths, and stop those process trees before checking. The resolved work was in the tree each time: run the coordinator check instead of another implementer round.
- 2026-11-04: dead test runs can leave orphaned headless browsers or test processes reparented to PID 1 (init / launchd). On each heartbeat, list `ps -Ao ppid,pid,etime,command | awk '$1==1'` filtered on the test runner or browser binary path, and stop the trees older than one hour. A plain `kill` may not be enough; use `kill -9` for survivors.
- 2026-11-04: `bin/state implementer <ISSUE> <key>` run from inside a secondary sub-repo recorded the coordinator in that sub-repo's `.autopilot/state.json`, not in the project state, and still printed `ok`. `bin/review` then let the coordinator's model review a ticket it had edited. Always run `bin/state` with `AUTOPILOT_REPO=<project repo>`, and check with `state get implementers.<ISSUE>` before the next review. Fix to make: refuse when the resolved repo is not the project's.
- 2026-11-04: in the coordinator shell, `ls` is aliased to `ls -l`, so `$(ls pattern)` builds argument lists of long-format lines (node then fails with "bad option: -rw-r--r--@"). Build file lists with `find` or `grep -l`, never with `ls`.

- **A network outage looks like every model failing.** On 2026-11-04 a DNS outage (`ENOTFOUND` on every API) turned three runs into `all_failed` and put a false cooldown on every model in the pools. Before treating `all_failed` as quotas, read the tail of one output file and run one `curl` to an API host. If it was the network: `run-model reset` each key that errored, smoke one model per vendor, and relaunch each ticket with an "interrupted, not rejected" round that keeps the partial tree. Candidate harness fix: `run-model` should detect `ENOTFOUND`/`ECONNREFUSED` in the output, classify it as `network`, retry with backoff, and set no cooldown.

- **A one-lane check queue idles the machine.** On 2026-11-05 six full checks waited behind one running check at load 5 on 16 cores. Run checks in lanes: a second lane opens while the 1-minute load is below about 0.9 x cores (`QCHECK_LANES`, `QCHECK_MAX_LOAD` in the project's `qcheck.sh`). Waiting `qcheck` processes keep the old script after an edit: stop and re-queue the critical-path ones.

- **`bin/review` does not fall back to another account of the same vendor.** On 2026-11-05 the default Codex account hit its usage limit mid-review; `bin/review` picked codex-sol, then codex-luna on the same account, and returned INCOMPLETE twice while the `-b` and `-c` accounts had quota. Workaround: `EXCLUDE=<the exhausted account's keys>`. Harness fix: on a quota failure, cool down every key of that account and retry the same vendor on the next account before giving up.

- **`restore()` loses tracked work when the ticket's new files are staged (`A`).** `snapshot()` records them in the `git stash create` commit; `restore()` runs `reset -q` (the added files become untracked), `checkout -- .`, then `stash apply`, which refuses because those files already exist untracked. Result on 2026-11-05 (M8.6-1g-company, after nemotron edited the tree): every modification to tracked files was gone, only the added files were left. Recovery: find the dangling `WIP on <branch>` commit from the review start (`git fsck --unreachable`), then `git checkout <that commit> -- .` and confirm with `git diff --quiet <commit> -- .`. Harness fix: restore with `git checkout <stash> -- .` (plus the cached patch), or remove the snapshot's added paths before `stash apply`; and print the snapshot commit id in every restore message so the coordinator can recover directly.

- **Helper links in a worktree get committed.** On 2026-11-05 the coordinator linked `node_modules` and `migration/node_modules` into a migration worktree to run tests, forgot to remove them before `finish`, and the repo's ignore rule was `node_modules/` (directories only), so `finish` committed both links (36bd131). Checking the commit out replaced the main checkout's installed packages with self-referencing links. Fix: bae06e3 (untracked, ignore rule `node_modules`), then `npm ci` in both package roots. Harness fix: `finish` must refuse to commit a symlink or any path named `node_modules`, and worktrees should get dependencies by `npm ci`, never by links.

- **A findings file built by a script can be silently missing.** On 2026-11-05 the coordinator's inline python that extracts review findings into `<ISSUE>-findings-r<n>c.md` crashed (the review file was not pure JSON) inside a backgrounded command, so `mkbrief` built a brief with no findings and the implementer ran a round "blind". Before dispatching, check that the findings file exists and that the brief contains a phrase from it (`grep -c`); `mkbrief` should fail when a findings path is given but missing.
