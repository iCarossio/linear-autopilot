# Codex out of quota: resets and alerts

## Every Codex account out, nobody told (2026-11-09)

**Symptom.** All three Codex accounts (`~/.codex`, `~/.codex-b`, `~/.codex-c`) hit their weekly limit. The coordinator kept running for hours on the remaining models. Plan reviews and pre-mortems (pools of Codex only once the coordinator's vendor is excluded) ended `NO_REVIEWER`, every code review queued behind one free opencode model, and the owner was never told. Resets were available on every account, but `bin/codex-reset` then required a per-session permission, so nobody redeemed them until the owner did it by hand.

**What the runtime does now.**
- `run-model` claims the reset itself when a fresh reading shows an account's WEEKLY window at 100% (`usage --apply`, or a run that hits its quota): it runs the adapter's `auto_reset` (`bin/codex-reset --yes --account <acc>`), at most once per account per weekly window (recorded before the call in `models.json` `resets[<cli>/<account>]`, with the time and the result), then smoke-tests one model of the account and clears its cooldowns when it answers. A 5-hour limit never triggers it. `"codex_auto_reset": false` in `models.json` turns it off. `codex-reset` keeps its guards: it refuses unless the weekly window is at 100%, and stops on any unexpected screen instead of guessing.
- When a vendor is still down on every account (no reset available, reset failed, auto-reset disabled), or `plan_review`/`premortem` have no eligible model, it raises a CRITICAL alert: a `CRITICAL:` line on stderr, `.autopilot/alerts.jsonl`, a Linear project update "CRITICAL: <vendor> out of quota", and `CRITICAL:` lines at the top of `bin/eta`. Outages shorter than `alert_min_outage_minutes` (default 60) are not alerts.
- The coordinator runs `bin/alert list` on every heartbeat and reports any unacknowledged alert to the user in its next message (what is blocked, the reset results, when the earliest window resets), then acknowledges it.

**If it happens anyway.** `bin/alert list --all`, `bin/run-model usage` (the `resets` field of `models.json` says what each attempt gave; `transcript_tail` holds the end of the TUI screen), then `bin/codex-reset --account <acc>` without `--yes` to see what is left. A reset that failed on an unexpected screen is not retried in the same window: read the transcript, fix the expect script if the TUI changed, and run it by hand.

## Stale usage after a reset (2026-11-09)

**Symptom.** Right after the manual resets, `run-model usage --apply` reported weekly 100% again and re-applied cooldowns until 2026-11-11 to accounts that a live smoke run had just proved healthy. Codex writes its rate limits into the session logs only when a session runs; the newest record was from before the reset.

**What the runtime does now.** Every successful run or smoke records `last_ok[<key>]` in `models.json`. A 100% reading observed before the latest success of a key it applies to is stale: `usage --apply` skips it, lists it in `stale_readings_skipped` and says so on stderr; `codex-reset` refuses to spend a reset on it. After a manual reset, one `run-model smoke <key>` per account is enough to make the old readings stale.
