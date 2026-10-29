# Lessons from real runs (by symptom)

Read the section whose symptom you observe. These are facts measured on real projects; dates mark when they were learnt. Add yours at the end, with the date.

## Files change in a worktree after a round finished; check runs die with rc=143; servers vanish

**opencode ghost sessions (2026-10-25).** Without `--standalone`, `opencode run` is a client of `opencode serve --service`: sessions and their shell jobs run in the service, keep going after the client exits or is killed, and are resumed when the service restarts. Ghost sessions from earlier rounds then edit worktrees after "done" and run things like `pkill -f "npm run parity"` against every checkout. `run-model` passes `--standalone` (the adapter does). If ghosts exist: `opencode service stop`, keep it stopped (check with `pgrep -fl "opencode serve --service"`, never `opencode service status`, which starts the service; an interactive `opencode` TUI left open also restarts it), and ask the user before deleting sessions (`opencode session list` / `delete`). After a ghost, re-check every worktree it could touch: a "done" round may have been partly reverted.

## `docker version` blocks; runs report `docker_hung`; serve tests hang for everyone

**Docker can hang under many parallel container start/stop cycles (2026-10-25).** Probe with a bounded `docker version`; on OrbStack `orb restart docker` may hang too, so kill the stuck docker clients and run `orb stop && orb start` (containers survive). Implementers must never restart Docker themselves: the brief says to stop and report. Then restart the stuck checks and rounds, and `run-model reset` any model cooled during the hang. With a 64 GB VM, up to 5 Docker-heavy jobs at a time were fine; the hangs came with small VM memory and 3 capture-heavy suites at once.

## Everything stalled for hours overnight, logs stopped at the same minute

**The Mac slept on battery (2026-10-25, 02:20 to 07:50).** `caffeinate` does not prevent sleep on battery; `pmset -g log` shows `Entering Sleep ... Using Batt`. At setup and on each heartbeat check `pmset -g batt` shows `AC Power`; if not, tell the user at the next turn.

## A ticket's untracked file disappeared after `rebase-wt`

`git stash pop` silently does not restore an untracked file whose path now exists on the branch (e.g. a notes file both tickets create). Recover it from the stash's untracked tree (`git show <stash>^3:<path>`, or from the dangling commit after a drop) and merge the two versions.

## A pre-commit hook fails in `finish` although the worktree passed

"package doesn't seem to be present in your lockfile" (or missing generated code in a fresh worktree) means the checkout's dependencies are stale, not the change: run the repo's install (`yarn install --immutable`, then its codegen) and commit again before sending anything back to the implementer.

## Checks fail with `ERR_CONNECTION_REFUSED` storms

A leftover `cmd &` from the implementer restarting the same server mid-run, or a reviewer starting/stopping servers in the same worktree, or two wrappers rebuilding the same `dist/` while a third serves it. Fixes: never review and check the same worktree at the same time; before checks, make sure nothing of the implementer still runs (`ps` for the worktree path, `docker rm -f <name>`); build once and make sure no wrapper rebuilds (`serve:prod` instead of a no-build serve); each suite gets its own port, container name and checkout.

## Regeneration overwrote a ticket's generated output

Regenerate and check idempotency only with the repo's own pipeline command (as named in the ticket notes), never with a remembered list of scripts: an older list silently drops newer steps.

## All tests green, converter still wrong on real data

**Invented fixtures pass by construction (2026-10-27).** A Ghost sync read fields that live in `posts_meta` and a redirects format Ghost never uses, all tests green on fixtures the implementer wrote. Require fixtures sampled verbatim from the real snapshot, plus one test that round-trips a real record against the current output.

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
