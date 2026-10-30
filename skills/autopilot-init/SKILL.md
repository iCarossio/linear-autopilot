---
name: autopilot-init
description: One-time setup of the linear-autopilot runtime on this machine. Discovers the AI coding CLIs installed (Codex, Claude Code, opencode, Cursor, Grok, Gemini, Antigravity, Mistral Vibe, ...), registers several accounts per CLI (e.g. a second Codex login through CODEX_HOME), adds a harness the runtime does not know yet, builds the model roster and pools by cost tier, smoke-tests every model and reads the current quotas. Use when the user says "/autopilot-init", "set up the autopilot", "add a harness/account/model to the autopilot", or when another autopilot skill reports a missing roster.
---

# Autopilot: init

Goal: a working roster at `~/.config/linear-autopilot/models.json` (`$AUTOPILOT_CONFIG_DIR` overrides) where every entry has been smoke-tested, with pools that respect the hard rules below. Nothing personal (accounts, cooldowns, API keys) is ever written into the skill repo.

`bin/<x>` below means the `bin` directory next to this SKILL.md (`~/.claude/skills/autopilot-init/bin/<x>` after `install.sh`, `${CLAUDE_PLUGIN_ROOT}/skills/autopilot-init/bin/<x>` as a plugin).

## Hard rules the roster must satisfy

1. **Implementer and reviewer are always different models**, and the two reviewers of a ticket come from two vendors. Enforced at run time by `run-model` and `bin/review` (fail closed), but the pools must make it possible: at least two vendors able to review and two able to implement, and at least two high-tier vendors besides the coordinator's for the pre-mortem.
2. **High tier never implements** (`no_implement`): it plans, pre-mortems and reviews. The expensive mid tier is a rescue, not a default.
3. **Subscriptions and free tiers only.** No paid per-token ids, no top-ups, no extra-usage credits.
4. **Accounts of the same model are the same reviewer** (codex-sol and codex-sol-b cannot review the same ticket together).

## Steps

1. **Create or import the roster.**
   - New machine: `bin/harness init` (copies `templates/models.json`: example models and pools from October 2026).
   - Existing private roster: `bin/harness init --import <path/to/models.json>`.
   Then `bin/harness list` to see what is there.
2. **Discover the harnesses.** `bin/harness discover` prints one line per CLI: installed or not, adapter present or `NO ADAPTER`, version, roster entries; then one line per account directory found on disk (e.g. `~/.codex*`): whether it holds a login (the adapter's `account_login` file), who it is (email, plan, from the login's token claims; tokens are never printed), and whether it is in the roster, with the exact `add-account` command when it is not. A directory without a login is not an account: ignore it or delete it. Show the table to the user and ask which of the installed CLIs they want to use, and which they pay for (subscription) versus free.
3. **Register a harness the runtime does not know.** For a CLI without an adapter, ask the user (or read its `--help`) for: the non-interactive invocation with full permissions, the model flag, whether the output goes to stdout or to a file flag, the environment variable that selects another login/account, a model-listing command, a usage/quota command. Then:
   ```
   bin/harness new <name> --binary <bin> --vendor <vendor|by_model> \
     --argv '["-p","{prompt}","--model","{model}","--yes"]' [--output file] \
     [--account-env VAR --account-default ~/.x --account-detect '~/.x*'] \
     [--list-cmd 'models' --list-regex '^\s*(\S+)\s*$'] \
     [--usage-cmd '-p /usage' --usage-regex '...' --usage-groups window,used,reset_text] [--env K=V] \
     [--tokens-kind codex_sessions|claude_projects|opencode_db|grok_sessions|agy_brain|gemini_chats --tokens-path '$VAR/sessions']
   ```
   `{prompt}` is always "read the brief file and follow it"; `{model}` and `{out}` are optional. The adapter lands in `~/.config/linear-autopilot/harnesses/<name>.json` (overrides the repo's). Check it with `bin/harness adapters`.
4. **Add models.** For each harness and model the user wants: `bin/harness add-model <key> --cli <cli> --model <id> --cost high|mid|cheap|free [--no-implement] [--pools p1,p2] [--note ...]`. Cost means what it costs the user on their plans, not list price. Suggested placement: high -> `premortem,plan_review,review_high` with `--no-implement`; mid -> `review_mid,review_high,fix_mid,implement_escalation`; cheap -> `implement_critical,implement,fix_mid,review_mid`; free -> `implement,review`. Use the family pattern (`--family 'gpt-*-sol'`) so `run-model discover` can upgrade it later.
5. **Add accounts: one standard for every harness.** The default account lives in the CLI's own home (`~/.codex`, `~/.claude`, `~/.local/share` for opencode); the next accounts live in `<default>-b`, `<default>-c`, ... and their roster keys are `<key>-b`, `<key>-c`, ... Nothing else. `bin/harness add-account codex b` clones every base model of Codex as `<key>-b` with `CODEX_HOME=~/.codex-b`, right after the originals in every pool (`--label "who@example.com (team)"` names it). The user logs in once in that home (`CODEX_HOME=~/.codex-b codex login`); `discover` shows whether the login exists and who it is. An existing directory with another name (`~/.codex-work`) is renamed to the standard (`mv ~/.codex-work ~/.codex-b`, then `bin/harness set-home codex ~/.codex-work ~/.codex-b` if it was already in the roster), never registered as is: `discover` keeps flagging non-standard homes. Adding multi-home support to a new adapter means declaring `account_env` and `account_default`; `account_detect` follows from the standard.
6. **Pools.** `bin/harness pools` shows them; `bin/harness pools set <pool> k1,k2,...` replaces one (order = preference). Check rule 1 above: for `review_mid` and `review_high`, list the vendors (`bin/harness list` shows them) and make sure there are at least two. For `premortem` and `plan_review`, count the `cost: high` vendors OTHER than the coordinator's: fewer than two means every pre-mortem will be degraded (one reviewer, or `--allow-mid`); say so to the user now and let them decide which mid-tier model of a third vendor to promote, or accept the degraded mode. Models that are the same underlying model through different harnesses (e.g. `claude-sonnet-5-5` natively and `anthropic/claude-sonnet-5-5` through opencode) are recognised by their canonical id; pin `canonical` on an entry when the heuristic gets it wrong.
7. **Smoke test every model** you placed in a pool: `bin/run-model smoke <key>` (a 120 s "reply AUTOPILOT_OK" run). A model that fails is cooled down; fix the adapter or the login, `bin/run-model reset <key>`, smoke again. Remove what cannot be made to work (`bin/harness remove <key>`).
8. **Read the quotas.** `bin/run-model usage --apply` prints every harness and account with its windows, used percentage and reset time, and cools down what is exhausted. Harnesses without a usage probe say so: tell the user the runtime will learn their resets from quota errors.
9. **Linear access.** Check that this harness has Linear tools (MCP), else that `LINEAR_API_KEY` is set and `bin/linear teams` answers.
10. **Summary for the user:** harnesses and accounts registered, models per cost tier, pools with their vendors, what was removed and why, quotas right now, and that `/autopilot-plan` is the next step.

## Adapter format (for reference)

`harnesses/<cli>.json`: `name`, `binary`, `vendor` (or `by_model` to derive it from the model id), `run.argv` with `{prompt}`, `{model}`, `{out}`, `{cwd}` placeholders, `run.env`, `run.output` (`stdout` or `file`), `account_env` / `account_default` / `account_detect`, `account_login` (the file that proves a login, and optional JWT claims naming the account), `list_models` (`command` + `regex`, `json_file`, or `none`), `usage` (`command` + `regex` + `groups`, `codex_sessions`, or `none`), `quota_patterns`, `tokens` (`kind` + `path`: the local log `bin/tokens` counts consumption from, one of `codex_sessions`, `claude_projects`, `opencode_db`, `grok_sessions`, `agy_brain`, `gemini_chats`, or `none` with a `note`). The repo's `harnesses/` has one per known CLI (Codex, Claude Code, opencode, Cursor, Grok, Antigravity, Gemini, Vibe); copy the closest one as a starting point. Cursor: `cursor-agent` has one login per machine and no account directory; its models (GPT, Claude, Gemini, Grok, Composer) are listed by `cursor-agent --list-models`, and `auto` is not a model id to put in the roster.
