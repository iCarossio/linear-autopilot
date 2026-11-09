#!/bin/bash
# Behavioural self-test of the linear-autopilot runtime with a fake harness adapter: no model CLI is run, no quota is
# spent, the user's config is never touched (everything happens in a temporary directory). Run: tests/selftest.sh
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"
SCR=$(mktemp -d -t autopilot-selftest); trap 'rm -rf "$SCR"' EXIT
export AUTOPILOT_CONFIG_DIR=$SCR/cfg3; mkdir -p "$SCR/fake"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   $1"; else FAIL=$((FAIL+1)); echo "FAIL $1: got '$2' want '$3'"; fi; }
cat > "$SCR/fake/fakecli" <<'EOF'
#!/bin/bash
case "${FAKE_BEHAVIOUR:-approve}" in
  approve) echo '```json'; echo '{"verdict":"approve","unmet_criteria":[],"findings":[],"summary":"fine"}'; echo '```';;
  approve_major) echo '```json'; echo '{"verdict":"approve","unmet_criteria":[],"findings":[{"severity":"major","file":"a.py","line":1,"problem":"bug","fix":"fix"}],"summary":"approve but major"}'; echo '```';;
  changes_empty) echo '```json'; echo '{"verdict":"changes_required","unmet_criteria":[],"findings":[],"summary":"vague"}'; echo '```';;
  weird) echo '```json'; echo '{"verdict":"maybe","findings":[]}'; echo '```';;
  modify) echo "hacked" >> tracked.txt; echo '```json'; echo '{"verdict":"approve","unmet_criteria":[],"findings":[],"summary":"fine"}'; echo '```';;
  modify_binary) printf '\x00\x01\x02NEW' > bin.dat; echo '```json'; echo '{"verdict":"approve","unmet_criteria":[],"findings":[],"summary":"fine"}'; echo '```';;
  commit) echo "sneaky" >> tracked.txt; git add -A; git -c user.email=r@r -c user.name=r commit -qm "reviewer commit"; echo '```json'; echo '{"verdict":"approve","unmet_criteria":[],"findings":[],"summary":"fine"}'; echo '```';;
  premortem) echo '```json'; echo "{\"verdict\":\"premortem\",\"pass\":1,\"reasons\":[{\"id\":\"r-$MODEL_TAG\",\"title\":\"reason from $MODEL_TAG\",\"probability\":0.7,\"impact\":\"severe\",\"why\":\"w\",\"early_signal\":\"e\",\"guardrail\":\"g\",\"kpi_link\":\"K1\"},{\"id\":\"shared\",\"title\":\"shared reason about deadline\",\"probability\":0.5,\"impact\":\"fatal\",\"why\":\"w\",\"early_signal\":\"e\",\"guardrail\":\"g\",\"kpi_link\":\"K1\"},{\"id\":\"bad\",\"title\":\"bad prob\",\"probability\":\"likely\",\"impact\":\"fatal\"}],\"summary\":\"s\"}"; echo '```';;
  implement) echo "impl" >> tracked.txt; echo "STATUS: done";;
esac
EOF
chmod +x "$SCR/fake/fakecli"; export PATH="$SCR/fake:$PATH"; export SCR
$H/bin/harness init >/dev/null
$H/bin/harness new fakecli --binary fakecli --vendor by_model --argv '["-p","{prompt}","--model","{model}"]' >/dev/null
$H/bin/harness add-model fk-a --cli fakecli --model claude-x-5 --cost high --no-implement --vendor anthropic >/dev/null
$H/bin/harness add-model fk-b --cli fakecli --model gpt-x --cost high --no-implement --vendor openai >/dev/null
$H/bin/harness add-model fk-c --cli fakecli --model grok-x --cost cheap --vendor xai >/dev/null
$H/bin/harness add-model fk-c2 --cli fakecli --model grok-x --cost cheap --vendor xai --env FAKE_ACCOUNT=2 >/dev/null
$H/bin/harness add-model fk-c3 --cli fakecli --model 'openrouter/xai/grok-x:free' --cost free --vendor xai >/dev/null
$H/bin/harness add-model fk-d --cli fakecli --model gemini-x --cost mid --vendor google >/dev/null
$H/bin/harness add-model fk-e --cli fakecli --model beam-free --cost free --vendor opencode >/dev/null
$H/bin/harness pools set review_mid fk-c,fk-c2,fk-c3,fk-d,fk-a,fk-b >/dev/null; $H/bin/harness pools set review_high fk-a,fk-b,fk-d >/dev/null
$H/bin/harness pools set review fk-e >/dev/null; $H/bin/harness pools set implement fk-c,fk-d >/dev/null; $H/bin/harness pools set implement_escalation fk-d >/dev/null
$H/bin/harness pools set premortem fk-a,fk-b,fk-d >/dev/null; $H/bin/harness pools set plan_review fk-a,fk-b >/dev/null
mkdir -p "$SCR/repo3" && cd "$SCR/repo3" && git init -q && echo base > tracked.txt && printf '\x00\x01\x02OLD' > bin.dat && cp $H/templates/PLAN.md PLAN.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm init
echo ".autopilot/" >> .git/info/exclude; mkdir -p .autopilot/tickets && python3 -c "
import json;s=json.load(open('$H/templates/state.json'));s['branch']=__import__('subprocess').run(['git','branch','--show-current'],capture_output=True,text=True).stdout.strip();s['coordinator']='fk-a';s['worktrees_dir']='$SCR/repo3-wt';json.dump(s,open('.autopilot/state.json','w'))"
cp $H/templates/ticket.md .autopilot/tickets/T-1.md

echo "--- implementer recording + identity"
B=$($H/bin/mkbrief impl T-1 1 .autopilot/tickets/T-1.md)
R=$(FAKE_BEHAVIOUR=implement $H/bin/run-model run implement "$B" .autopilot/out/T-1-impl-1.md --cwd "$PWD" --prefer fk-c | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['status'],d['model'])")
check "implement runs and is ok" "$R" "ok fk-c"
check "implementer key recorded" "$($H/bin/state get implementers.T-1)" '[
  "fk-c"
]'
check "implementer identity recorded" "$($H/bin/state get implementer_ids.T-1)" '[
  "grok-x"
]'
git checkout -q -- tracked.txt
RB=$($H/bin/mkbrief review T-1 1 .autopilot/tickets/T-1.md)
$H/bin/run-model run review "$RB" .autopilot/out/x.md --cwd "$PWD" --model fk-c2 >/dev/null 2>&1; check "same model, other account refused" "$?" "4"
$H/bin/run-model run review "$RB" .autopilot/out/x.md --cwd "$PWD" --model fk-c3 >/dev/null 2>&1; check "same model via another harness (openrouter/xai/grok-x:free) refused" "$?" "4"
$H/bin/run-model run review "$SCR/custom-review.md" .autopilot/out/x.md --cwd "$PWD" --model fk-c >/dev/null 2>&1; check "custom-named review brief without --issue refused" "$?" "4"
echo "custom" > "$SCR/custom-review.md"
FAKE_BEHAVIOUR=approve $H/bin/run-model run review "$SCR/custom-review.md" .autopilot/out/x.md --cwd "$PWD" --standalone --exclude-vendor xai --model fk-c >/dev/null 2>&1; check "standalone with --exclude-vendor xai refuses fk-c" "$?" "4"
FAKE_BEHAVIOUR=approve $H/bin/run-model run review "$SCR/custom-review.md" .autopilot/out/x.md --cwd "$PWD" --standalone --exclude-vendor xai --model fk-d >/dev/null 2>&1; check "standalone with other vendor runs" "$?" "0"
# roster change: upgrade fk-c's model id; identity must still exclude a key with the old model
$H/bin/harness remove fk-c >/dev/null
$H/bin/run-model run review "$RB" .autopilot/out/x.md --cwd "$PWD" --model fk-c2 >/dev/null 2>&1; check "after the implementer key is removed, same identity still refused" "$?" "4"

echo "--- plan-review purpose enforced in the runner"
PB=$($H/bin/mkbrief plan T-1 1 .autopilot/tickets/T-1.md)
FAKE_BEHAVIOUR=approve $H/bin/run-model run review "$PB" .autopilot/out/p.md --cwd "$PWD" --pool plan_review --model fk-a >/dev/null 2>&1; check "runner refuses the coordinator (fk-a) for its own plan review" "$?" "4"
FAKE_BEHAVIOUR=approve $H/bin/run-model run review "$PB" .autopilot/out/p.md --cwd "$PWD" --pool plan_review --model fk-d >/dev/null 2>&1; check "runner refuses a mid model for a plan review" "$?" "4"
FAKE_BEHAVIOUR=approve $H/bin/run-model run review "$PB" .autopilot/out/p.md --cwd "$PWD" --pool plan_review --allow-mid --model fk-d >/dev/null 2>&1; check "runner accepts mid with --allow-mid" "$?" "0"
FAKE_BEHAVIOUR=approve $H/bin/run-model run review "$PB" .autopilot/out/p.md --cwd "$PWD" --pool plan_review --model fk-b >/dev/null 2>&1; check "runner accepts a high model of another vendor" "$?" "0"
$H/bin/state implementer T-3 fk-a >/dev/null; check "state implementer records identity" "$($H/bin/state get implementer_ids.T-3)" '[
  "claude-x-5"
]'
echo "--- review verdict rules"
FAKE_BEHAVIOUR=approve $H/bin/review T-1 1 "$RB" >/dev/null; check "two vendors approve -> 0" "$?" "0"
FAKE_BEHAVIOUR=approve_major $H/bin/review T-1 2 "$RB" >/dev/null; check "approve with major -> 1" "$?" "1"
FAKE_BEHAVIOUR=changes_empty $H/bin/review T-1 3 "$RB" >/dev/null; check "changes without findings -> 1" "$?" "1"
FAKE_BEHAVIOUR=weird $H/bin/review T-1 4 "$RB" >/dev/null; check "unknown verdict -> 2" "$?" "2"
OUT=$(FAKE_BEHAVIOUR=modify $H/bin/review T-1 5 "$RB"); check "modified tree -> 2" "$?" "2"; check "tree restored" "$(cat tracked.txt)" "base"
OUT=$(FAKE_BEHAVIOUR=modify_binary $H/bin/review T-1 6 "$RB"); check "binary rewrite -> 2" "$?" "2"; check "binary restored" "$(python3 -c "print(open('bin.dat','rb').read()[-3:])")" "b'OLD'"
OUT=$(FAKE_BEHAVIOUR=commit $H/bin/review T-1 7 "$RB"); check "reviewer commits -> 3 (history changed)" "$?" "3"; echo "    $OUT" | head -1
git reset -q --hard HEAD~1 2>/dev/null; git log --oneline | head -1 | grep -q init && echo "    (test cleanup: reviewer commit removed)"
MIN_REVIEWS=0 $H/bin/review T-1 8 "$RB" >/dev/null 2>&1; check "MIN_REVIEWS=0 refused" "$?" "1"
POOL=plan_review FAKE_BEHAVIOUR=approve $H/bin/review T-1 p1 "$RB" >/dev/null; check "plan review: coordinator fk-a (anthropic) excluded, fk-b high + no second high vendor -> 2" "$?" "2"
POOL=plan_review ALLOW_MID=1 FAKE_BEHAVIOUR=approve $H/bin/review T-1 p2 "$RB" >/dev/null; check "plan review ALLOW_MID=1 -> fk-b + fk-d -> 0" "$?" "0"
POOL=plan_review ALLOW_MID=1 FAKE_BEHAVIOUR=approve $H/bin/review T-1 p3 "$RB" 1 >/dev/null; check "plan review k=1 -> 0" "$?" "0"

echo "--- premortem"
OUT=$(FAKE_BEHAVIOUR=premortem MODEL_TAG=x $H/bin/premortem PLAN.md --planner fk-a); RC=$?; check "premortem default k=1: fk-b alone, both passes -> 0" "$RC" "0"
grep -q "adversarial self-review" .autopilot/plan/premortem-brief-fk-b-2.md && echo "ok   single reviewer gets the self-review pass 2" || { echo "FAIL pass 2 brief is not the self-review"; FAIL=$((FAIL+1)); }
OUT=$(FAKE_BEHAVIOUR=premortem MODEL_TAG=x $H/bin/premortem PLAN.md --planner fk-a --k 2); RC=$?; check "premortem --k 2: only fk-b high -> degraded 1" "$RC" "1"
echo "$OUT" | grep -q "1 dropped" && echo "ok   malformed reason dropped" || { echo "FAIL malformed reason not reported: $OUT"; FAIL=$((FAIL+1)); }
OUT=$(FAKE_BEHAVIOUR=premortem MODEL_TAG=x $H/bin/premortem PLAN.md --planner fk-a --k 2 --allow-mid); check "premortem --allow-mid: fk-b + fk-d both passes -> 0" "$?" "0"
check "merged reasons (same tag from both reviewers merges to 2)" "$(python3 -c "import json;print(len(json.load(open('.autopilot/plan/premortem.json'))['reasons']))")" "2"
OUT=$(FAKE_BEHAVIOUR=premortem MODEL_TAG=x $H/bin/premortem PLAN.md --planner fk-a --k 2 --allow-mid --only-pass 2); check "only-pass 2 reuses validated pass 1 -> 0" "$?" "0"
$H/bin/premortem PLAN.md >/dev/null 2>&1; check "premortem without --planner refused" "$?" "1"
echo "edit" >> PLAN.md
OUT=$(FAKE_BEHAVIOUR=premortem MODEL_TAG=x $H/bin/premortem PLAN.md --planner fk-a --k 2 --allow-mid --only-pass 2); RC=$?
echo "$OUT" | grep -q "plan changed" && echo "ok   changed plan is not reused for pass 2" || { echo "FAIL changed plan reused: $OUT"; FAIL=$((FAIL+1)); }
git checkout -q -- PLAN.md

echo "--- usage aggregation (fake probe via adapter override)"
python3 - <<'PY'
import json, os
cfg = os.environ['AUTOPILOT_CONFIG_DIR']
p = os.path.join(cfg, 'harnesses', 'fakecli.json'); a = json.load(open(p))
a['usage'] = {'kind': 'command', 'argv': ['usage'], 'regex': r'^(\w+) (\d+)%(?: resets (\S+))?$', 'groups': ['window', 'used', 'reset_iso']}
json.dump(a, open(p, 'w'))
PY
cat >> "$SCR/fake/fakecli" <<'EOF'
EOF
cat > "$SCR/fake/fakecli_usage" <<'EOF'
EOF
python3 - <<'PY'
import os
p = os.path.join(os.environ['SCR'], 'fake', 'fakecli')
s = open(p).read().replace('case "${FAKE_BEHAVIOUR:-approve}" in', 'if [ "$1" = usage ]; then echo "5h ${FAKE_5H:-10}% resets 2099-01-01T00:00:00+00:00"; echo "weekly ${FAKE_WEEK:-10}% resets 2099-01-02T00:00:00+00:00"; exit 0; fi\ncase "${FAKE_BEHAVIOUR:-approve}" in')
open(p, 'w').write(s)
PY
R=$(FAKE_5H=100 FAKE_WEEK=50 $H/bin/run-model usage --apply | python3 -c "import json,sys;d=json.load(sys.stdin);print(sorted(k for k in d['exhausted_until_reset'] if k.startswith('fk-'))==['fk-a','fk-b','fk-c2','fk-c3','fk-d','fk-e'])")
check "5h exhausted cools every fakecli key" "$R" "True"
R=$(FAKE_5H=100 FAKE_WEEK=100 $H/bin/run-model usage --apply >/dev/null; $H/bin/run-model health | python3 -c "import json,sys;h=json.load(sys.stdin);print(h['fk-a']['until'][:10])")
check "longest reset wins (weekly 2099-01-02)" "$R" "2099-01-02"
R=$(FAKE_5H=100 FAKE_WEEK=10 $H/bin/run-model usage --apply | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['stale_quota_cooldowns_cleared'])")
check "5h still exhausted: nothing cleared, cooldown not shortened" "$R" "[]"
R=$($H/bin/run-model health | python3 -c "import json,sys;h=json.load(sys.stdin);print(h['fk-a']['until'][:10])"); check "cooldown kept at the longer reset" "$R" "2099-01-02"
sleep 1; R=$(FAKE_5H=10 FAKE_WEEK=10 $H/bin/run-model usage --apply | python3 -c "import json,sys;d=json.load(sys.stdin);print('fk-a' in d['stale_quota_cooldowns_cleared'])")
check "all windows under quota with a newer reading -> cleared" "$R" "True"
# a cooldown responsible for the weekly window must not be cleared by a reading that only covers 5h
python3 - <<'PY'
import json, os, datetime as dt
p = os.path.join(os.environ['AUTOPILOT_CONFIG_DIR'], 'models.json'); r = json.load(open(p))
r['health']['fk-b'] = {'until': '2099-01-02T00:00:00+00:00', 'reason': 'quota: weekly', 'set_at': (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=1)).isoformat(), 'windows': ['weekly']}
json.dump(r, open(p, 'w'))
PY
cat > "$SCR/fake/fakecli_5h_only" <<'EOF'
EOF
python3 - <<'PY'
import os
p = os.path.join(os.environ['SCR'], 'fake', 'fakecli'); s = open(p).read()
s = s.replace('echo "weekly ${FAKE_WEEK:-10}% resets 2099-01-02T00:00:00+00:00"; exit 0', '[ -n "${FAKE_NO_WEEK:-}" ] || echo "weekly ${FAKE_WEEK:-10}% resets 2099-01-02T00:00:00+00:00"; exit 0')
open(p, 'w').write(s)
PY
R=$(FAKE_5H=10 FAKE_NO_WEEK=1 $H/bin/run-model usage --apply | python3 -c "import json,sys;d=json.load(sys.stdin);print('fk-b' in d['stale_quota_cooldowns_cleared'])")
check "a 5h-only reading does not clear a weekly cooldown" "$R" "False"
R=$(FAKE_5H=10 FAKE_WEEK=10 $H/bin/run-model usage --apply | python3 -c "import json,sys;d=json.load(sys.stdin);print('fk-b' in d['stale_quota_cooldowns_cleared'])")
check "a reading covering weekly clears it" "$R" "True"

echo "--- account standard"
$H/bin/harness add-account codex b --label "second login" >/dev/null 2>&1; check "add-account codex b (standard home)" "$?" "0"
check "cloned key uses CODEX_HOME=~/.codex-b" "$(python3 -c "import json,os;r=json.load(open(os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json'));print(r['models']['codex-sol-b']['env']['CODEX_HOME'], r['models']['codex-sol-b']['account_label'])")" "~/.codex-b second login"
$H/bin/harness add-account codex work >/dev/null 2>&1; check "add-account with a word instead of a letter refused" "$?" "1"
$H/bin/harness add-account codex c --home ~/.codex-other >/dev/null 2>&1; check "non-standard home without --nonstandard refused" "$?" "1"
$H/bin/harness add-account codex c --home ~/.codex-other --nonstandard >/dev/null 2>&1; check "non-standard home accepted with --nonstandard" "$?" "0"
$H/bin/harness discover 2>/dev/null | grep -q "NON-STANDARD home for codex-sol-c" && echo "ok   discover flags the non-standard home" || { echo "FAIL discover did not flag ~/.codex-other"; FAIL=$((FAIL+1)); }
$H/bin/harness set-home codex ~/.codex-other ~/.codex-c >/dev/null; check "set-home moves the roster entries" "$(python3 -c "import json,os;r=json.load(open(os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json'));print(r['models']['codex-sol-c']['env']['CODEX_HOME'])")" "~/.codex-c"
$H/bin/harness add-account fakecli b >/dev/null 2>&1; check "add-account refused for a harness without account_env" "$?" "1"
echo "--- state helper + finish recovery"
$H/bin/state set inflight.T-9 '{"wt":"x","round":1}' >/dev/null; $H/bin/state push done '"T-8"' >/dev/null
check "state set/push" "$($H/bin/state get done)" '[
  "T-8"
]'
cd "$SCR/repo3"; git worktree add -q -b autopilot/T-2 "$SCR/repo3-wt/T-2" HEAD; echo more >> tracked.txt; git -c user.email=t@t -c user.name=t commit -qam "main moved"
cd "$SCR/repo3-wt/T-2"; echo feat > feat.txt; git add feat.txt; git -c user.email=t@t -c user.name=t commit -qm "ticket commit"; echo fix > fix.txt
$H/bin/rebase-wt "$PWD"; check "rebase-wt committed+uncommitted" "$?" "0"; git log --oneline | head -3; git status --short
RBB=$(cd "$SCR/repo3" && WT="$SCR/repo3-wt/T-2" $H/bin/mkbrief review T-2 1 .autopilot/tickets/T-1.md); BASE=$(grep -o 'git diff [0-9a-f]\{7,40\}' "$RBB" | head -1)
check "review base is the merge-base when the ticket is committed" "$([ -n "$BASE" ] && echo sha || echo HEAD)" "sha"
cd "$SCR/repo3"; OUT=$($H/bin/finish T-2 "feat: two" "body" 2>&1); echo "    finish: $OUT"; check "finish integrates the committed range + uncommitted fix" "$?" "0"
check "both files on the project branch" "$(ls feat.txt fix.txt 2>/dev/null | wc -l | tr -d ' ')" "2"
check "two commits integrated" "$(git log --oneline | grep -c 'T-2\|ticket commit')" "2"
echo "--- token consumption report"
TOK=$SCR/tok; mkdir -p $TOK/claude/projects/p1 $TOK/codex/sessions/2026/10/01 $TOK/grok/sessions/x/s1; NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > $TOK/claude/projects/p1/a.jsonl <<EOF2
{"type":"assistant","timestamp":"$NOW","requestId":"r1","message":{"id":"m1","model":"claude-x","usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":5}}}
{"type":"assistant","timestamp":"$NOW","requestId":"r1","message":{"id":"m1","model":"claude-x","usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":7}}}
{"type":"assistant","timestamp":"$NOW","requestId":"r2","message":{"id":"m2","model":"claude-x","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}
{"type":"user","timestamp":"$NOW","message":{"role":"user","content":"hi"}}
EOF2
cat > $TOK/codex/sessions/2026/10/01/rollout-a.jsonl <<EOF2
{"timestamp":"$NOW","type":"session_meta","payload":{"id":"s1"}}
{"timestamp":"$NOW","type":"turn_context","payload":{"model":"gpt-x"}}
{"timestamp":"$NOW","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50,"total_tokens":1050},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50}},"rate_limits":{}}}
{"timestamp":"$NOW","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":1200,"output_tokens":80,"total_tokens":1580},"last_token_usage":{"input_tokens":500,"cached_input_tokens":400,"output_tokens":30}},"rate_limits":{}}}
EOF2
cat > $TOK/grok/sessions/x/s1/usage.json <<EOF2
{"sessionId":"s1","updatedAt":"$NOW","session":{"primaryModelId":"grok-x"},"turns":[{"turnNumber":1,"endedAt":"$NOW","inputTokens":200,"outputTokens":20,"cachedReadTokens":50,"modelCalls":3,"primaryModelId":"grok-x","modelUsage":{"grok-x":{"inputTokens":200,"outputTokens":20,"cachedReadTokens":50,"modelCalls":3}}}]}
EOF2
$H/bin/harness new fk-claude --binary fakecli --argv '["{prompt}"]' --tokens-kind claude_projects --tokens-path "$TOK/claude/projects" >/dev/null
$H/bin/harness new fk-codex --binary fakecli --argv '["{prompt}"]' --tokens-kind codex_sessions --tokens-path "$TOK/codex/sessions" >/dev/null
$H/bin/harness new fk-grok --binary fakecli --argv '["{prompt}"]' --tokens-kind grok_sessions --tokens-path "$TOK/grok/sessions" >/dev/null
$H/bin/harness new fk-bad --binary fakecli --argv '["{prompt}"]' --tokens-kind nope --tokens-path /x >/dev/null 2>&1; check "harness new refuses an unknown tokens kind" "$?" "1"
TJ() { $H/bin/tokens --cli fk-claude,fk-codex,fk-grok --json "$@" | python3 -c "
import json,sys; d=json.load(sys.stdin); r=d['reports'][0]; t=r['totals']
print(' '.join('%s=%d/%d/%d/%d/%d' % (k, v['input'], v['cached'], v['output'], v['total'], v['calls']) for k, v in sorted(t.items())), 'grand=%d' % r['grand']['total'])"; }
check "tokens: claude dedupes the streamed record, codex uses cumulative deltas, grok reads turns" "$(TJ --period 7d --no-cache)" "fk-claude=160/30/8/168/2 fk-codex=1500/1200/80/1580/2 fk-grok=200/50/20/220/3 grand=1968"
check "tokens: same numbers over 5 years (yearly buckets)" "$(TJ --period 5y | sed 's/.*grand=//')" "1968"
check "tokens: cached second run agrees" "$(TJ --period 7d | sed 's/.*grand=//')" "1968"
echo "{\"type\":\"assistant\",\"timestamp\":\"$NOW\",\"requestId\":\"r3\",\"message\":{\"id\":\"m3\",\"model\":\"claude-x\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":0}}}" >> $TOK/claude/projects/p1/a.jsonl
check "tokens: a grown log file is re-indexed" "$(TJ --period 7d | sed 's/.*grand=//')" "2968"
$H/bin/tokens --cli fk-claude,fk-codex,fk-grok --html $SCR/tokens.html >/dev/null; check "tokens --html writes the page" "$(grep -c 'fk-codex' $SCR/tokens.html | awk '{print ($1>0)}')" "1"
$H/bin/tokens --cli nope >/dev/null 2>&1; check "tokens refuses an unknown --cli" "$?" "1"
$H/bin/tokens --cli fk-claude --no-color --period 7d | grep -q 'total on the period: 1.17k tokens' && echo "ok   tokens terminal report" || { echo "FAIL tokens terminal report"; FAIL=$((FAIL+1)); }
# docker-up with fake docker/orb binaries: a flag file stands for a daemon that answers.
DK=$SCR/dk; mkdir -p $DK/bin
cat > $DK/bin/docker <<EOF
#!/bin/bash
[ -f $DK/up ] && { echo 27.0; exit 0; }; exit 1
EOF
cat > $DK/bin/orb <<EOF
#!/bin/bash
echo "\$*" >> $DK/calls
case "\$1" in status) [ -f $DK/vm ] && echo Running || echo Stopped;; start) touch $DK/vm $DK/up;; stop) rm -f $DK/vm $DK/up;; esac
EOF
chmod +x $DK/bin/*
DU() { PATH="$DK/bin:$PATH" AUTOPILOT_DOCKER_RUNTIME=orbstack DOCKER_UP_TIMEOUT=10 $H/bin/docker-up "$@"; }
touch $DK/up; check "docker-up: daemon up, nothing started" "$(DU; echo rc=$?; [ -f $DK/calls ] && echo called)" "docker-up: up
rc=0"
rm -f $DK/up; check "docker-up --check: down, nothing started" "$(DU --check; echo rc=$?; [ -f $DK/calls ] && echo called)" "docker-up: down
rc=1"
check "docker-up: stopped runtime is started" "$(DU; echo rc=$?; grep -c start $DK/calls)" "docker-up: started orbstack, up
rc=0
1"
rm -f $DK/up $DK/calls; touch $DK/vm; check "docker-up: hung daemon is not restarted without --restart" "$(DU; echo rc=$?; grep -c -E 'start|stop' $DK/calls)" "docker-up: orbstack runs but the daemon does not answer (hung); rerun with --restart
rc=3
0"
check "docker-up --restart: hung daemon is stopped then started" "$(DU --restart; echo rc=$?; grep -E 'start|stop' $DK/calls | tr '\n' ' ')" "docker-up: restarted orbstack, up
rc=0
stop start "
# eta: REPLAN signals (serial tail, idle lanes, slip against a reading 1-3 h ago) and the timezone on the ETA line.
ER=$SCR/eta-repo; mkdir -p $ER/.autopilot && (cd $ER && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)
EB=$(git -C $ER branch --show-current)
cat > $ER/.autopilot/state.json <<EOF
{"branch": "$EB", "queue": ["A", "B", "C"], "inflight": {}, "done": [], "per_unit_min": 60,
 "stages": [["A"], ["B"], ["C"]], "parallel_target": 3}
EOF
EO=$(ETA_LOAD=0 AUTOPILOT_REPO=$ER $H/bin/eta)
check "eta: timezone on the ETA line" "$(echo "$EO" | head -1 | grep -cE 'ETA [A-Z][a-z]{2} [0-9]{2}:[0-9]{2} [A-Z+0-9-]+ ')" "1"
check "eta: serial tail flagged" "$(echo "$EO" | grep -c 'REPLAN: 3 single-item stages in a row (A -> B -> C)')" "1"
check "eta: idle lanes flagged" "$(echo "$EO" | grep -c 'REPLAN: 0 in flight, target 3, 3 queued')" "1"
check "eta: overload suppresses idle lanes" "$(ETA_LOAD=999 AUTOPILOT_REPO=$ER $H/bin/eta | grep -cE 'REPLAN: (machine load 999|0 in flight)' ; ETA_LOAD=999 AUTOPILOT_REPO=$ER $H/bin/eta | grep -c 'REPLAN: machine load')" "1
1"
python3 -c "
import datetime as d,json
n=d.datetime.now(d.timezone.utc)
open('$ER/.autopilot/eta-history.jsonl','w').write(json.dumps({'at':(n-d.timedelta(minutes=90)).isoformat(),'end':(n-d.timedelta(minutes=30)).isoformat(),'total':60})+'\n')"
check "eta: slip against a reading 90 min ago flagged" "$(ETA_LOAD=0 AUTOPILOT_REPO=$ER $H/bin/eta | grep -c 'REPLAN: ETA slipped')" "1"
cat > $ER/.autopilot/state.json <<EOF
{"branch": "$EB", "queue": ["A", "B", "C"], "inflight": {}, "done": [], "per_unit_min": 60,
 "stages": [["A", "B", "C"]], "parallel_target": 0}
EOF
rm -f $ER/.autopilot/eta-history.jsonl
check "eta: parallel plan, no REPLAN" "$(ETA_LOAD=0 AUTOPILOT_REPO=$ER $H/bin/eta | grep -c REPLAN)" "0"
# bgrun: a silent command is killed with its detached descendants; a busy one hits --timeout; a normal one passes through.
BG=$SCR/bg; mkdir -p $BG
check "bgrun: ok passes the exit code through" "$($H/bin/bgrun --name ok --log $BG/ok.log -- 'echo hi; exit 0' | tail -1 | sed 's/ in .*//')" "bgrun ok: ok rc=0"
check "bgrun: failure keeps its exit code" "$($H/bin/bgrun --name f --log $BG/f.log -- 'exit 3' >/dev/null; echo $?)" "3"
$H/bin/bgrun --idle 6 --name stall --log $BG/st.log -- 'echo started; python3 -c "import os,time; os.setsid(); time.sleep(300)" & sleep 300' >$BG/st.out; BGRC=$?
check "bgrun: silent run stalls with exit 124" "$BGRC $(tail -1 $BG/st.out | grep -c '^bgrun stall: STALL no output')" "124 1"
check "bgrun: stall report has the process tree" "$(grep -c 'Process tree' $BG/st.log)" "1"
check "bgrun: detached descendants are killed" "$(pgrep -f 'time.sleep\(300\)' | wc -l | tr -d ' ')" "0"
check "bgrun: busy run hits --timeout" "$($H/bin/bgrun --timeout 6 --name to --log $BG/to.log -- 'while :; do echo tick; sleep 1; done' | tail -1 | grep -c '^bgrun to: TIMEOUT')" "1"
check "bgrun: a changing --watch path counts as progress" "$($H/bin/bgrun --idle 6 --watch $BG/w.txt --name w --log $BG/w.log -- 'for i in 1 2 3 4 5 6 7 8 9 10; do date >> '$BG'/w.txt; sleep 1; done' | tail -1 | sed 's/ in .*//')" "bgrun w: ok rc=0"
check "bgrun: a new working process counts as progress" "$($H/bin/bgrun --idle 6 --name sp --log $BG/sp.log -- 'for i in 1 2 3 4 5; do python3 -c "import time; time.sleep(3)"; done' | tail -1 | sed 's/ in .*//')" "bgrun sp: ok rc=0"
check "bgrun: a silent sleep loop still stalls" "$($H/bin/bgrun --idle 6 --name sl --log $BG/sl.log -- 'while :; do sleep 1; done' | tail -1 | grep -c '^bgrun sl: STALL')" "1"
# decision: every change of plan is sourced in PLAN.md, and tracked until mirrored in Linear.
DR=$SCR/dec; mkdir -p $DR/.autopilot && cp $H/templates/PLAN.md $DR/PLAN.md && echo '{"project_id": "<Linear project id>"}' > $DR/.autopilot/state.json
D() { AUTOPILOT_REPO=$DR $H/bin/decision "$@"; }
check "decision: refuses an unsourced change" "$(D add --change "a -> b" --source "because" --by me >/dev/null 2>&1; echo $?)" "1"
check "decision: refuses an unknown source kind" "$(D add --change "a -> b" --source "vibes:x" --by me >/dev/null 2>&1; echo $?)" "1"
check "decision: a user source must quote the user" "$(D add --change "a -> b" --source "user:agreed" --by me >/dev/null 2>&1; echo $?)" "1"
check "decision: pre-linear before the project exists" "$(D add --change "K2 p95 200 ms -> 300 ms" --source 'user:"300 is fine for v1"' --by owner --why "a|b")" "D-1"
check "decision: pipe escaped, row has 8 cells" "$(grep -c '^| D-1 | .*a\\|b.* | pre-linear |$' $DR/PLAN.md)" "1"
echo '{"project_id": "p-123"}' > $DR/.autopilot/state.json
check "decision: pending once the project exists" "$(D add --change "split ENG-4 into ENG-4a/4b" --source "replan:REPLAN: 2 single-item stages" --by fk-a | cut -d' ' -f1)" "D-2"
check "decision: check fails while pending" "$(D check >/dev/null; echo $?)" "1"
D synced D-2 https://linear.app/x/issue/ENG-4#comment-1 >/dev/null
check "decision: check passes once synced" "$(D check >/dev/null; echo $?)" "0"
check "decision: log sits before Approval" "$(awk '/^## Decision log/{d=NR} /^## Approval/{a=NR} END{print (d && d<a)}' $DR/PLAN.md)" "1"
echo "=== $PASS passed, $FAIL failed"
