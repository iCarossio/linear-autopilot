# Pre-mortem (pass {{PASS}}): cross-review and merge

You are {{REVIEWER}}. In pass 1 you listed the most probable reasons this project fails by its deadline. Another reviewer, from another vendor, did the same independently. Below is their list. Produce the final ranked list that a project owner should act on.

You are READ-ONLY: do not edit, create or delete any file, do not run git commands that change state.

## Plan ({{PLAN_PATH}})
{{PLAN}}

## Repository
{{CWD}}

## Your own pass-1 reasons (a fresh session: this is what you wrote)
{{MINE}}

## The other reviewer's pass-1 reasons
{{OTHER}}

## Do this
1. For each of their reasons: agree (keep, possibly sharpen the guardrail), or disagree with evidence from the repo or the plan (drop it, and say why in `why`, prefixed "DROPPED:"), or merge it with one of yours when they are the same cause.
2. Re-read your own pass-1 list with their eyes: drop what is generic, keep what is specific.
3. Add what BOTH of you missed, now that you have seen two angles. Verify any new claim against the repository.
4. Rank the kept reasons by probability x impact. Each kept reason: a concrete early signal and a concrete guardrail (a rule, a check command, an acceptance criterion or a dedicated ticket). `source` = "mine", "theirs" or "both".

Keep at most 10 reasons. Dropped reasons go in `dropped` with one line each, not in `reasons`.

## Style
Terse. Paths, commands, numbers verbatim. No preamble.

## Final answer: ONLY this JSON, nothing before or after
```json
{"verdict": "premortem", "pass": {{PASS}},
 "reasons": [{"id": "short-slug", "title": "one line", "probability": 0.0, "impact": "fatal|severe|moderate", "source": "mine|theirs|both",
              "why": "specific evidence", "early_signal": "what shows it is happening, by when",
              "guardrail": "exact rule / check / criterion / ticket to add", "kpi_link": "KPI name or none"}],
 "dropped": [{"id": "slug", "why": "one line"}],
 "summary": "one sentence: the single most likely way this project fails"}
```
