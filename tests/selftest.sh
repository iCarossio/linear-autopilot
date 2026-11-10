#!/bin/bash
# Behavioural self-test of the linear-autopilot runtime with a fake harness adapter: no model CLI is run, no quota is
# spent, the user's config is never touched (everything happens in a temporary directory). Run: tests/selftest.sh
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"; export H
SCR=$(mktemp -d -t autopilot-selftest); LPID=""; trap '[ -n "$LPID" ] && kill $LPID 2>/dev/null; rm -rf "$SCR"' EXIT
export AUTOPILOT_CONFIG_DIR=$SCR/cfg3; mkdir -p "$SCR/fake"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   $1"; else FAIL=$((FAIL+1)); echo "FAIL $1: got '$2' want '$3'"; fi; }
cat > "$SCR/fake/fakecli" <<'EOF'
#!/bin/bash
if [ "$1" = usage ]; then echo "5h ${FAKE_5H:-10}% resets 2099-01-01T00:00:00+00:00"; [ -n "${FAKE_NO_WEEK:-}" ] || echo "weekly ${FAKE_WEEK:-10}% resets 2099-01-02T00:00:00+00:00"; exit 0; fi
if [ "$1" = models ]; then for x in ${FAKE_MODELS:-}; do echo "$x"; done; exit 0; fi
f=${2#Read the file }; f=${f%% and follow*}
if [ -f "$f" ] && grep -q 'Reply with exactly: AUTOPILOT_OK' "$f"; then  # a smoke test: the model id is $4
  case " ${FAKE_BAD_MODELS:-} " in *" $4 "*) echo "model not found"; exit 1;; esac
  if [ -n "${FAKE_GOOD_MODELS:-}" ]; then case " $FAKE_GOOD_MODELS " in *" $4 "*) ;; *) echo "model not found"; exit 1;; esac; fi
  echo AUTOPILOT_OK; exit 0
fi
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
  auto) case "$2" in *premortem-brief*) FAKE_BEHAVIOUR=premortem MODEL_TAG=m exec "$0" "$@";; *) FAKE_BEHAVIOUR=approve exec "$0" "$@";; esac;;
esac
EOF
chmod +x "$SCR/fake/fakecli"; export PATH="$SCR/fake:$PATH"; export SCR
# Hermetic: no real model CLI, no real Linear, never the real codex-reset, no daily model discovery. The vendor -> CLI
# rule means a fake model runs through its vendor's CLI name: the adapters of the real CLIs are overridden in the test
# config dir to call the fake binary (stubs shadow the real binaries anyway).
unset LINEAR_API_KEY LINEAR_API_URL CLAUDECODE CLAUDE_CONFIG_DIR CODEX_HOME AUTOPILOT_COORDINATOR AUTOPILOT_SEED; export AUTOPILOT_NO_DISCOVER=1
for c in codex claude agy opencode grok cursor-agent gemini vibe; do printf '#!/bin/sh\nexit 1\n' > "$SCR/fake/$c"; chmod +x "$SCR/fake/$c"; done
cat > "$SCR/fake/fake-reset" <<'EOF'
#!/bin/bash
echo "$*" >> "$SCR/resets.log"
case "$(cat "$SCR/reset.mode" 2>/dev/null || echo ok)" in
  ok) echo "Usage limit resets"; echo "Full reset redeemed"; exit 0;;
  none) echo "UNEXPECTED SCREEN: the redeem menu did not appear (expected 'Redeem')"; exit 2;;
  *) echo "UNEXPECTED SCREEN: no redemption confirmation after choosing"; exit 2;;
esac
EOF
chmod +x "$SCR/fake/fake-reset"
cat > "$SCR/fakeads.py" <<'EOF'
# fakeads.py <cfg dir> [cli ...]: fake adapters named after the real CLIs (vendor and account fields kept from the repo's).
import json, os, sys
cfg = sys.argv[1]; os.makedirs(os.path.join(cfg, 'harnesses'), exist_ok=True)
for cli in sys.argv[2:] or ['claude', 'codex', 'grok', 'agy', 'opencode', 'cursor', 'vibe']:
    src = json.load(open(os.path.join(os.environ['H'], 'harnesses', cli + '.json')))
    a = {'name': cli, 'binary': 'fakecli', 'vendor': src.get('vendor', 'by_model'), 'run': {'argv': ['-p', '{prompt}', '--model', '{model}'], 'env': {}, 'output': 'stdout'},
         'list_models': {'kind': 'command', 'argv': ['models'], 'regex': r'^(\S+)$'}, 'usage': {'kind': 'none'}, 'quota_patterns': ['usage limit'],
         'tokens': {'kind': 'none'}}
    for k in ('account_env', 'account_default', 'account_detect', 'account_login', 'coordinator_env'):
        if k in src: a[k] = src[k]
    if cli == 'codex':
        a['auto_reset'] = dict(src['auto_reset'], argv=[os.path.join(os.environ['SCR'], 'fake', 'fake-reset'), '--yes', '--account', '{account}'])
    json.dump(a, open(os.path.join(cfg, 'harnesses', cli + '.json'), 'w'))
EOF
$H/bin/harness init >/dev/null
python3 "$SCR/fakeads.py" $AUTOPILOT_CONFIG_DIR
python3 -c "
import json,os;p=os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json';r=json.load(open(p));r['models']={};r['codex_auto_reset']=False;json.dump(r,open(p,'w'))"
$H/bin/harness new fakecli --binary fakecli --vendor by_model --argv '["-p","{prompt}","--model","{model}"]' >/dev/null
$H/bin/harness add-model fk-a --cli claude --model claude-x-5 --level 1 --no-implement >/dev/null
$H/bin/harness add-model fk-b --cli codex --model gpt-x --level 1 --no-implement --subscription paid >/dev/null
$H/bin/harness add-model fk-c --cli grok --model grok-x --level 3 --subscription paid >/dev/null
$H/bin/harness add-model fk-c2 --cli grok --model grok-x --level 3 --env FAKE_ACCOUNT=2 --subscription paid >/dev/null
$H/bin/harness add-model fk-c3 --cli cursor --model grok-x --level 3 --subscription free >/dev/null
$H/bin/harness add-model fk-d --cli agy --model gemini-x --level 2 --subscription free >/dev/null
$H/bin/harness add-model fk-f --cli codex --model gpt-y-terra --level 2 --subscription paid >/dev/null
$H/bin/harness add-model fk-e --cli opencode --model beam-free --vendor opencode --level 2 >/dev/null
mkdir -p "$SCR/repo3" && cd "$SCR/repo3" && git init -q && echo base > tracked.txt && printf '\x00\x01\x02OLD' > bin.dat && cp $H/templates/PLAN.md PLAN.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm init
echo ".autopilot/" >> .git/info/exclude; mkdir -p .autopilot/tickets && python3 -c "
import json;s=json.load(open('$H/templates/state.json'));s['branch']=__import__('subprocess').run(['git','branch','--show-current'],capture_output=True,text=True).stdout.strip();s['coordinator']='fk-a';s['worktrees_dir']='$SCR/repo3-wt';json.dump(s,open('.autopilot/state.json','w'))"
cp $H/templates/ticket.md .autopilot/tickets/T-1.md
LV() { python3 -c "
import json,os,sys;sys.path.insert(0,os.environ['H']+'/bin');import autopilot_lib as lib
r=lib.load_reg(warn=False);ad=lib.adapters();ks=json.loads(sys.argv[1]);print(sorted({lib.level_of(r,r['models'][k],ad[r['models'][k]['cli']]) for k in ks}))" "$1"; }
POOL() { $H/bin/run-model pool "$1" 2>/dev/null; }
SORTED() { python3 -c "import json,sys;print(sorted(json.load(sys.stdin)))"; }

echo "--- implementer recording + identity"
B=$($H/bin/mkbrief impl T-1 1 .autopilot/tickets/T-1.md)
R=$(FAKE_BEHAVIOUR=implement $H/bin/run-model run implement "$B" .autopilot/out/T-1-impl-1.md --cwd "$PWD" --prefer fk-c | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['status'],d['model'],d['level'])")
check "implement runs a Tier 3 model and is ok" "$R" "ok fk-c 3"
check "implementer key recorded" "$($H/bin/state get implementers.T-1)" '[
  "fk-c"
]'
check "implementer identity recorded" "$($H/bin/state get implementer_ids.T-1)" '[
  "grok-x"
]'
git checkout -q -- tracked.txt
RB=$($H/bin/mkbrief review T-1 1 .autopilot/tickets/T-1.md)
$H/bin/run-model run review "$RB" .autopilot/out/x.md --cwd "$PWD" --model fk-c2 >/dev/null 2>&1; check "same model, other account refused" "$?" "4"
$H/bin/run-model run review "$RB" .autopilot/out/x.md --cwd "$PWD" --model fk-c3 >/dev/null 2>&1; check "same model via another harness (cursor grok-x) refused" "$?" "4"
$H/bin/run-model run review "$SCR/custom-review.md" .autopilot/out/x.md --cwd "$PWD" --model fk-d >/dev/null 2>&1; check "custom-named review brief without --issue refused" "$?" "4"
echo "custom" > "$SCR/custom-review.md"
FAKE_BEHAVIOUR=approve $H/bin/run-model run review "$SCR/custom-review.md" .autopilot/out/x.md --cwd "$PWD" --standalone --exclude-vendor google --model fk-d >/dev/null 2>&1; check "standalone with --exclude-vendor google refuses fk-d" "$?" "4"
FAKE_BEHAVIOUR=approve $H/bin/run-model run review "$SCR/custom-review.md" .autopilot/out/x.md --cwd "$PWD" --standalone --exclude-vendor xai --model fk-d >/dev/null 2>&1; check "standalone with other vendor runs" "$?" "0"
# roster change: upgrade fk-c's model id; identity must still exclude a key with the old model
$H/bin/harness remove fk-c >/dev/null
$H/bin/run-model run review "$RB" .autopilot/out/x.md --cwd "$PWD" --model fk-c2 >/dev/null 2>&1; check "after the implementer key is removed, same identity still refused" "$?" "4"

echo "--- plan-review purpose enforced in the runner"
PB=$($H/bin/mkbrief plan T-1 1 .autopilot/tickets/T-1.md)
FAKE_BEHAVIOUR=approve $H/bin/run-model run review "$PB" .autopilot/out/p.md --cwd "$PWD" --pool plan_review --model fk-a >/dev/null 2>&1; check "runner refuses the coordinator (fk-a) for its own plan review" "$?" "4"
FAKE_BEHAVIOUR=approve $H/bin/run-model run review "$PB" .autopilot/out/p.md --cwd "$PWD" --pool plan_review --model fk-d >/dev/null 2>&1; check "runner refuses a Tier 2 model for a plan review" "$?" "4"
FAKE_BEHAVIOUR=approve $H/bin/run-model run review "$PB" .autopilot/out/p.md --cwd "$PWD" --pool plan_review --allow-mid --model fk-d >/dev/null 2>&1; check "--allow-mid is refused (tier policy)" "$?" "4"
FAKE_BEHAVIOUR=approve $H/bin/run-model run review "$PB" .autopilot/out/p.md --cwd "$PWD" --pool plan_review --model fk-b >/dev/null 2>&1; check "runner accepts a Tier 1 model of another vendor" "$?" "0"
$H/bin/state implementer T-3 fk-a >/dev/null; check "state implementer records identity" "$($H/bin/state get implementer_ids.T-3)" '[
  "claude-x-5"
]'
echo "--- review verdict rules (one Tier 2 reviewer per round)"
FAKE_BEHAVIOUR=approve $H/bin/review T-1 1 "$RB" >/dev/null; check "one Tier 2 reviewer approves -> 0" "$?" "0"
FAKE_BEHAVIOUR=approve_major $H/bin/review T-1 2 "$RB" >/dev/null; check "approve with major -> 1" "$?" "1"
FAKE_BEHAVIOUR=changes_empty $H/bin/review T-1 3 "$RB" >/dev/null; check "changes without findings -> 1" "$?" "1"
FAKE_BEHAVIOUR=weird $H/bin/review T-1 4 "$RB" >/dev/null; check "unknown verdict -> 2" "$?" "2"
OUT=$(FAKE_BEHAVIOUR=modify $H/bin/review T-1 5 "$RB"); check "modified tree -> 2" "$?" "2"; check "tree restored" "$(cat tracked.txt)" "base"
OUT=$(FAKE_BEHAVIOUR=modify_binary $H/bin/review T-1 6 "$RB"); check "binary rewrite -> 2" "$?" "2"; check "binary restored" "$(python3 -c "print(open('bin.dat','rb').read()[-3:])")" "b'OLD'"
OUT=$(FAKE_BEHAVIOUR=commit $H/bin/review T-1 7 "$RB"); check "reviewer commits -> 3 (history changed)" "$?" "3"; echo "    $OUT" | head -1
git reset -q --hard HEAD~1 2>/dev/null; git log --oneline | head -1 | grep -q init && echo "    (test cleanup: reviewer commit removed)"
MIN_REVIEWS=0 $H/bin/review T-1 8 "$RB" >/dev/null 2>&1; check "MIN_REVIEWS=0 refused" "$?" "1"
check "k=2 reviewers come from two vendors" "$(FAKE_BEHAVIOUR=approve $H/bin/review T-1 9 "$RB" 2 | grep -cE '^fk-(d|f): approve')" "2"
POOL=plan_review FAKE_BEHAVIOUR=approve $H/bin/review T-1 p1 "$RB" >/dev/null; check "plan review: coordinator fk-a (anthropic) excluded, one Tier 1 of another vendor (fk-b) -> 0" "$?" "0"
POOL=plan_review FAKE_BEHAVIOUR=approve $H/bin/review T-1 p2 "$RB" 2 >/dev/null 2>&1; check "plan review k=2 with one other Tier 1 vendor -> 2 (never another tier)" "$?" "2"
POOL=plan_review ALLOW_MID=1 $H/bin/review T-1 p3 "$RB" >/dev/null 2>&1; check "plan review ALLOW_MID=1 refused" "$?" "1"
$H/bin/alert ack all >/dev/null 2>&1

echo "--- premortem"
OUT=$(FAKE_BEHAVIOUR=premortem MODEL_TAG=x $H/bin/premortem PLAN.md --planner fk-a); RC=$?; check "premortem default k=1: fk-b alone, both passes -> 0" "$RC" "0"
grep -q "adversarial self-review" .autopilot/plan/premortem-brief-fk-b-2.md && echo "ok   single reviewer gets the self-review pass 2" || { echo "FAIL pass 2 brief is not the self-review"; FAIL=$((FAIL+1)); }
OUT=$(FAKE_BEHAVIOUR=premortem MODEL_TAG=x $H/bin/premortem PLAN.md --planner fk-a --k 2); RC=$?; check "premortem --k 2: only fk-b in Tier 1 -> degraded 1" "$RC" "1"
echo "$OUT" | grep -q "1 dropped" && echo "ok   malformed reason dropped" || { echo "FAIL malformed reason not reported: $OUT"; FAIL=$((FAIL+1)); }
$H/bin/premortem PLAN.md --planner fk-a --allow-mid >/dev/null 2>&1; check "premortem --allow-mid refused" "$?" "1"
$H/bin/harness add-model fk-g --cli opencode --model deepseek-x-pro --level 1 --subscription paid >/dev/null
OUT=$(FAKE_BEHAVIOUR=premortem MODEL_TAG=x $H/bin/premortem PLAN.md --planner fk-a --k 2); check "premortem --k 2 with a second Tier 1 vendor: fk-b + fk-g both passes -> 0" "$?" "0"
check "merged reasons (same tag from both reviewers merges to 2)" "$(python3 -c "import json;print(len(json.load(open('.autopilot/plan/premortem.json'))['reasons']))")" "2"
OUT=$(FAKE_BEHAVIOUR=premortem MODEL_TAG=x $H/bin/premortem PLAN.md --planner fk-a --k 2 --only-pass 2); check "only-pass 2 reuses validated pass 1 -> 0" "$?" "0"
$H/bin/premortem PLAN.md >/dev/null 2>&1; check "premortem without --planner refused" "$?" "1"
echo "edit" >> PLAN.md
OUT=$(FAKE_BEHAVIOUR=premortem MODEL_TAG=x $H/bin/premortem PLAN.md --planner fk-a --k 2 --only-pass 2); RC=$?
echo "$OUT" | grep -q "plan changed" && echo "ok   changed plan is not reused for pass 2" || { echo "FAIL changed plan reused: $OUT"; FAIL=$((FAIL+1)); }
git checkout -q -- PLAN.md

echo "--- tier policy: roles from levels, vendor -> CLI, escalation, Tier 0/4"
check "implement = Tier 3 only (never 1/2/4)" "$(LV "$(POOL implement)")" "[3]"
check "fix = Tier 3 only" "$(LV "$(POOL fix_mid)")" "[3]"
check "review = Tier 2 only (never 1/3/4)" "$(LV "$(POOL review)") $(POOL review_high | SORTED)" "[2] ['fk-d', 'fk-f']"
check "legacy pool names are aliases of the roles" "$(LV "$(POOL implement_critical)") $(LV "$(POOL review_mid)") $(LV "$(POOL premortem)") $(LV "$(POOL implement_escalation)")" "[3] [2] [1] [2]"
check "a free model added with --level 2 is Tier 4: never a reviewer" "$(POOL review | grep -c fk-e)" "0"
check "Tier 4 only in trivial" "$(POOL trivial) $(for p in implement fix review plan_review premortem milestone_review escalate; do POOL $p; done | grep -c fk-e)" '["fk-e"] 0'
$H/bin/harness add-model fk-m --cli vibe --model mistral-x --level 2 >/dev/null
check "a Mistral model is Tier 4 whatever its level" "$(POOL trivial | SORTED) $(POOL review | grep -c fk-m)" "['fk-e', 'fk-m'] 0"
$H/bin/harness add-model fk-z --cli claude --model claude-mythos-x --level 0 >/dev/null
check "Tier 0 never in a pool" "$(for p in implement fix review plan_review premortem milestone_review escalate trivial coordinate; do POOL $p; done | grep -c fk-z)" "0"
$H/bin/run-model run review "$PB" .autopilot/out/p.md --cwd "$PWD" --pool plan_review --model fk-z >/dev/null 2>&1; check "Tier 0 by --model without --allow-tier0 refused" "$?" "4"
B2=$($H/bin/mkbrief impl T-2 1 .autopilot/tickets/T-1.md)
FAKE_BEHAVIOUR=implement $H/bin/run-model run implement "$B2" .autopilot/out/T-2-impl-1.md --cwd "$PWD" --model fk-f >/dev/null 2>&1; check "implement by a Tier 2 model refused" "$?" "4"
FAKE_BEHAVIOUR=implement $H/bin/run-model run implement "$B2" .autopilot/out/T-2-impl-1.md --cwd "$PWD" --model fk-e --role trivial >/dev/null 2>&1; check "Tier 4 runs a trivial task" "$?" "0"
git checkout -q -- tracked.txt
$H/bin/run-model run review "$RB" .autopilot/out/x.md --cwd "$PWD" --model fk-e --role trivial >/dev/null 2>&1; check "Tier 4 never reviews (role trivial on a review)" "$?" "4"
$H/bin/run-model run review "$RB" .autopilot/out/x.md --cwd "$PWD" --model fk-b >/dev/null 2>&1; check "Tier 1 never reviews ticket code" "$?" "4"
R=$(FAKE_BEHAVIOUR=implement $H/bin/run-model run implement "$B2" .autopilot/out/T-2-impl-2.md --cwd "$PWD" --escalate 2>$SCR/esc.err | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['status'],d['level'])")
check "--escalate goes 3 -> 2, never Tier 1, logged" "$R $(grep -c 'escalate T-2: Tier 3 -> Tier 2' $SCR/esc.err) $($H/bin/state get escalations.T-2 | python3 -c "import json,sys;print(json.load(sys.stdin)[0]['to'])")" "ok 2 1 [2]"
git checkout -q -- tracked.txt

echo "--- automatic escalation: 1 implementation + 2 fixes on Tier 3, then Tier 2 (escalate_after_round)"
IMPL() { FAKE_BEHAVIOUR=implement $H/bin/run-model run implement "$@" 2>>$SCR/auto.err | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['status'],d['level'],d['run_role'])"; git checkout -q -- tracked.txt; }
B4_1=$($H/bin/mkbrief impl T-4 1 .autopilot/tickets/T-1.md); B4_2=$($H/bin/mkbrief impl T-4 2 .autopilot/tickets/T-1.md); B4_3=$($H/bin/mkbrief impl T-4 3 .autopilot/tickets/T-1.md)
check "rounds 1-3 draw Tier 3 (round 1 implement, rounds 2-3 fix)" "$(IMPL "$B4_1" .autopilot/out/T-4-impl-1.md --cwd "$PWD"); $(IMPL "$B4_2" .autopilot/out/T-4-impl-2.md --cwd "$PWD" --role fix); $(IMPL "$B4_3" .autopilot/out/T-4-impl-3.md --cwd "$PWD" --role fix)" "ok 3 implement; ok 3 fix; ok 3 fix"
check "no escalation logged for rounds 1-3" "$($H/bin/state get escalations.T-4 2>/dev/null | grep -c round)" "0"
B4_4=$($H/bin/mkbrief impl T-4 4 .autopilot/tickets/T-1.md)
check "round 4 (brief name) draws Tier 2 automatically, --role fix included" "$(IMPL "$B4_4" .autopilot/out/T-4-impl-4.md --cwd "$PWD" --role fix --prefer fk-f)" "ok 2 escalate"
check "the automatic escalation is logged with its round" "$(grep -c 'escalate T-4: Tier 3 -> Tier 2 (round 4 > escalate_after_round 3)' $SCR/auto.err) $($H/bin/state get escalations.T-4 | python3 -c "import json,sys;e=json.load(sys.stdin);print(len(e),e[0]['to'],e[0]['round'])")" "1 1 [2] 4"
check "the escalated Tier 2 implementer is recorded" "$($H/bin/state get implementers.T-4 | grep -c '"fk-f"')" "1"
check "--no-escalate keeps Tier 3 on round 4 (merge-only round)" "$(IMPL "$B4_4" .autopilot/out/T-4-impl-4m.md --cwd "$PWD" --role fix --no-escalate)" "ok 3 fix"
echo "custom" > "$SCR/custom-impl.md"
check "--round 5 with --issue escalates a custom-named brief" "$(IMPL "$SCR/custom-impl.md" .autopilot/out/x-impl.md --cwd "$PWD" --issue T-4 --round 5)" "ok 2 escalate"
check "--round 2 keeps Tier 3 whatever the output name says" "$(IMPL "$SCR/custom-impl.md" .autopilot/out/T-4-impl-9.md --cwd "$PWD" --issue T-4 --round 2)" "ok 3 implement"
check "no --round: the output name <ISSUE>-impl-<n>.md gives the round" "$(IMPL "$SCR/custom-impl.md" .autopilot/out/T-4-impl-6.md --cwd "$PWD" --issue T-4)" "ok 2 escalate"
check "a trivial run is never escalated" "$(IMPL "$B4_4" .autopilot/out/T-4-impl-4t.md --cwd "$PWD" --role trivial --model fk-e)" "ok 4 trivial"
check "--round 0 refused" "$(FAKE_BEHAVIOUR=implement $H/bin/run-model run implement "$B4_4" .autopilot/out/z.md --cwd "$PWD" --round 0 >/dev/null 2>&1; echo $?)" "1"
python3 -c "
import json,os;p=os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json';r=json.load(open(p));r['escalate_after_round']=4;json.dump(r,open(p,'w'))"
B4_5=$($H/bin/mkbrief impl T-4 5 .autopilot/tickets/T-1.md)
check "escalate_after_round 4: round 4 stays Tier 3, round 5 escalates" "$(IMPL "$B4_4" .autopilot/out/T-4-impl-4.md --cwd "$PWD" --role fix); $(IMPL "$B4_5" .autopilot/out/T-4-impl-5.md --cwd "$PWD" --role fix)" "ok 3 fix; ok 2 escalate"
python3 -c "
import json,os;p=os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json';r=json.load(open(p));r.pop('escalate_after_round');json.dump(r,open(p,'w'))"
B5=$($H/bin/mkbrief impl T-5 4 .autopilot/tickets/T-1.md)
check "escalated round 4 on T-5 by fk-f" "$(IMPL "$B5" .autopilot/out/T-5-impl-4.md --cwd "$PWD" --prefer fk-f)" "ok 2 escalate"
RB5=$($H/bin/mkbrief review T-5 4 .autopilot/tickets/T-1.md)
$H/bin/run-model run review "$RB5" .autopilot/out/x.md --cwd "$PWD" --model fk-f >/dev/null 2>&1; check "the escalated Tier 2 implementer never reviews that ticket" "$?" "4"
check "the review draw finds another Tier 2 model (fk-d, another vendor)" "$(FAKE_BEHAVIOUR=approve $H/bin/review T-5 4 "$RB5" | grep -cE '^fk-d: approve') $(ls .autopilot/out/ | grep -c 'T-5-rev-fk-f')" "1 0"
$H/bin/harness add-model bad1 --cli opencode --model anthropic/claude-x-6 --level 2 >/dev/null 2>&1; check "vendor -> CLI: Claude through opencode refused at add-model" "$?" "1"
$H/bin/harness add-model bad2 --cli cursor --model claude-x-6 --level 2 >/dev/null 2>&1; check "vendor -> CLI: Claude through cursor refused" "$?" "1"
$H/bin/harness add-model bad3 --cli agy --model gpt-x-7 --level 2 >/dev/null 2>&1; check "vendor -> CLI: GPT through agy refused" "$?" "1"
$H/bin/harness add-model bad4 --cli opencode --model kimi-x --vendor anthropic --level 3 >/dev/null 2>&1; check "vendor -> CLI: an anthropic vendor through opencode refused" "$?" "1"
$H/bin/harness add-model ok5 --cli cursor --model grok-y --level 3 >/dev/null 2>&1; check "vendor -> CLI: xAI through cursor accepted" "$?" "0"; $H/bin/harness remove ok5 >/dev/null
python3 -c "
import json,os;p=os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json';r=json.load(open(p));r['models']['bad5']={'cli':'agy','model':'claude-x-9','level':2,'vendor':'anthropic'};json.dump(r,open(p,'w'))"
check "a hand-edited entry breaking vendor -> CLI is refused at load, in pools and by --model" "$(POOL review | grep -c bad5) $($H/bin/run-model pool review 2>&1 >/dev/null | grep -c 'roster: refused bad5: anthropic models run only through claude') $($H/bin/run-model run review "$RB" .autopilot/out/x.md --cwd "$PWD" --model bad5 >/dev/null 2>&1; echo $?)" "0 1 4"
$H/bin/harness check >/dev/null 2>&1; check "harness check fails on the refused entry" "$?" "1"
$H/bin/harness remove bad5 >/dev/null
python3 -c "
import json,os;p=os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json';r=json.load(open(p));r['roles']={'review':[1,2]};json.dump(r,open(p,'w'))"
check "roles config cannot put Tier 1 in review" "$($H/bin/run-model pool review 2>&1 | grep -c 'roles.review = \[1, 2\] breaks the tier policy')" "1"
python3 -c "
import json,os;p=os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json';r=json.load(open(p));r.pop('roles');json.dump(r,open(p,'w'))"

echo "--- subscriptions, credit-weighted draws, coordinator account"
check "harness pools set refused (no hand-ordered pools)" "$($H/bin/harness pools set review fk-b >/dev/null 2>&1; echo $?)" "1"
FIRST() { for i in $(seq 1 ${2:-200}); do AUTOPILOT_SEED=$i $H/bin/run-model pool "$1" 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin)[0])"; done | sort | uniq -c | awk '{print $2"="$1}' | tr '\n' ' '; }
check "draws are reproducible with AUTOPILOT_SEED" "$(AUTOPILOT_SEED=7 POOL trivial)" "$(AUTOPILOT_SEED=7 POOL trivial)"
D=$(FIRST implement 120); N3=$(echo "$D" | tr ' ' '\n' | grep '^fk-c3=' | cut -d= -f2)
check "paid before free: the free fk-c3 is drawn first rarely (<25% of 120 seeds; weight 0.25 vs 1)" "$([ "${N3:-0}" -lt 30 ] && echo yes || echo "no: $D")" "yes"
python3 -c "
import json,os,datetime as d;p=os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json';r=json.load(open(p));r['usage_seen']={'grok/default':{'used':97,'at':d.datetime.now(d.timezone.utc).isoformat()}};json.dump(r,open(p,'w'))"
D=$(FIRST implement 120); N3=$(echo "$D" | tr ' ' '\n' | grep '^fk-c3=' | cut -d= -f2)
check "credit-weighted: an account at 97% is almost never drawn first (fk-c3 first >75%)" "$([ "${N3:-0}" -gt 90 ] && echo yes || echo "no: $D")" "yes"
python3 -c "
import json,os;p=os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json';r=json.load(open(p));r['usage_seen']={};json.dump(r,open(p,'w'))"
$H/bin/harness subscription grok default reserved >/dev/null
check "reserved account never drawn" "$(POOL implement)" '["fk-c3"]'
$H/bin/harness subscription grok default paid >/dev/null; $H/bin/harness set fk-c3 excluded "owner: not this one" >/dev/null
check "excluded entry never drawn, reserved lifted" "$(POOL implement | SORTED)" "['fk-c2']"
$H/bin/harness set fk-c3 excluded "" >/dev/null
$H/bin/state set exclude '{"grok/default": "kept for another project"}' >/dev/null
check "project-level exclude of a whole account (state.json exclude)" "$(POOL implement) $($H/bin/run-model run implement "$B2" .autopilot/out/T-2-impl-9.md --cwd "$PWD" --model fk-c2 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin)['reason'])")" '["fk-c3"] fk-c2 is excluded: project exclude grok/default: kept for another project'
$H/bin/state set exclude '{}' >/dev/null
# The coordinator account is detected from the session (Claude Code sets CLAUDECODE; CLAUDE_CONFIG_DIR unset = the
# default home): fk-a / fk-h / fk-i are on it, fk-i-b on a second login of the same CLI.
export CLAUDECODE=1
check "coordinator account detected from the session, recorded in state.json" "$($H/bin/run-model whoami --record | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['cli'],d['account'],d['keys'])") $($H/bin/state get coordinator_account.account)" "claude default ['fk-a', 'fk-z'] \"default\""
check "started from another login, that one is protected instead (default-account keys stay on the default home)" "$(CLAUDE_CONFIG_DIR=$HOME/.claude-b $H/bin/run-model whoami | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['account'].startswith('CLAUDE_CONFIG_DIR='),d['keys'])")" "True []"
$H/bin/harness add-model fk-h --cli claude --model claude-haiku-x --level 3 >/dev/null
$H/bin/harness add-model fk-i --cli claude --model claude-sonnet-x --level 2 >/dev/null
$H/bin/harness add-model fk-i-b --cli claude --model claude-sonnet-x --level 2 --env CLAUDE_CONFIG_DIR=~/.claude-b --subscription paid >/dev/null
check "coordinator account last, for a cheap role" "$(for i in 1 2 3 4 5; do AUTOPILOT_SEED=$i POOL implement | python3 -c "import json,sys;print(json.load(sys.stdin)[-1])"; done | sort -u)" "fk-h"
check "coordinator account never in a Tier 2 role while another candidate exists" "$(POOL review | grep -c '"fk-i"')" "0"
check "a second account of the coordinator's vendor is a normal paid account" "$(python3 -c "
import os,sys;sys.path.insert(0,os.environ['H']+'/bin');import autopilot_lib as lib
r=lib.load_reg(warn=False);ad=lib.adapters();print([lib.on_coordinator_account(r,r['models'][k],ad['claude']) for k in ('fk-a','fk-h','fk-i','fk-i-b')])") $(POOL review | grep -c fk-i-b) $($H/bin/harness check 2>/dev/null | grep -E '^ +fk-i-b ' | grep -c ' paid ')" "[True, True, True, False] 1 2"
python3 -c "
import json,os;p=os.environ['AUTOPILOT_CONFIG_DIR']+'/harnesses/claude.json';a=json.load(open(p))
a['usage']={'kind':'command','argv':['usage'],'regex':r'^(\w+) (\d+)%(?: resets (\S+))?$','groups':['window','used','reset_iso']};json.dump(a,open(p,'w'))"
B4=$($H/bin/mkbrief impl T-4 1 .autopilot/tickets/T-1.md)
RUNH() { $H/bin/run-model run implement "$B4" .autopilot/out/T-4-impl-1.md --cwd "$PWD" --model fk-h 2>$SCR/cr.err | python3 -c "import json,sys;print(json.load(sys.stdin)['status'])"; git checkout -q -- tracked.txt; }
R=$(FAKE_5H=80 FAKE_BEHAVIOUR=implement RUNH)
check "coordinator quota reserve: 20% of the 5-hour window left (< 30%) -> refused, CRITICAL alert" "$R $(grep -c 'CRITICAL: delegation to the coordinator account claude/default refused (5h 20% left (reserve 30%))' $SCR/cr.err) $($H/bin/alert list | grep -c 'coordinator account')" "coordinator_reserve 1 1"
R=$(FAKE_5H=10 FAKE_WEEK=85 FAKE_BEHAVIOUR=implement RUNH)
check "coordinator quota reserve: 15% of the week left (< 20%) -> refused" "$R" "coordinator_reserve"
R=$(FAKE_5H=10 FAKE_WEEK=10 FAKE_BEHAVIOUR=implement RUNH)
check "coordinator quota above the reserve -> runs, alert resolved" "$R $($H/bin/alert list | grep 'coordinator account' | grep -c resolved)" "ok 1"
$H/bin/alert ack all >/dev/null
python3 -c "import json,os;p=os.environ['AUTOPILOT_CONFIG_DIR']+'/harnesses/claude.json';a=json.load(open(p));a['usage']={'kind':'none'};json.dump(a,open(p,'w'))"
R=$(FAKE_BEHAVIOUR=implement RUNH)
check "coordinator quota unreadable -> refused (fails closed)" "$R" "coordinator_reserve"
$H/bin/alert ack all >/dev/null; for k in fk-h fk-i fk-i-b fk-m fk-z fk-g; do $H/bin/harness remove $k >/dev/null; done; unset CLAUDECODE

echo "--- no reviewer: wait within review_wait_minutes, else CRITICAL, never another tier"
COOL() { python3 -c "
import json,os,sys,datetime as d;p=os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json';r=json.load(open(p))
for k in sys.argv[2:]: r['health'][k]={'until':(d.datetime.now(d.timezone.utc)+d.timedelta(seconds=float(sys.argv[1]))).isoformat(),'reason':'quota: test','set_at':d.datetime.now(d.timezone.utc).isoformat()}
json.dump(r,open(p,'w'))" "$@"; }
COOL 4 fk-d fk-f
OUT=$(FAKE_BEHAVIOUR=approve $H/bin/review T-1 w1 "$RB"); RC=$?
check "the Tier 2 reviewers are back in 4 s: waits, then reviews" "$RC $(echo "$OUT" | grep -c '^WAITING: no eligible review reviewer')" "0 1"
COOL 36000 fk-d fk-f
OUT=$(FAKE_BEHAVIOUR=approve $H/bin/review T-1 w2 "$RB" 2>$SCR/nr.err); RC=$?
check "no Tier 2 reviewer for 10 h: NO_REVIEWER exit 2, CRITICAL alert, no Tier 1/4 fallback" "$RC $(echo "$OUT" | grep -c '^NO_REVIEWER: review for T-1 round w2: 0 eligible reviewer') $(grep -c '^CRITICAL: review for T-1' $SCR/nr.err) $(ls .autopilot/out/ | grep -cE 'T-1-rev-(fk-a|fk-b|fk-e)-w2')" "2 1 1 0"
python3 -c "import json,os;p=os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json';r=json.load(open(p));r['health']={};json.dump(r,open(p,'w'))"; $H/bin/alert ack all >/dev/null

echo "--- watchdog: code in the model's own output is not an input prompt"
cat > "$SCR/wp.py" <<'EOF'
import importlib.util, importlib.machinery, os
ld = importlib.machinery.SourceFileLoader('rm', os.path.join(os.environ['H'], 'bin', 'run-model'))
sp = importlib.util.spec_from_loader('rm', ld); rm = importlib.util.module_from_spec(sp); ld.exec_module(rm)
code = ['            facts.ticketed += 1\n        elif isinstance(event, TicketClosed):\n            ss}, {event.severity})")',
        'def run(agent_id: str, *, user_guid', '            approval_id=approval_id,\n            x.mission_id,',
        '            question=(\n                f"Approve this plan? Agents {\', \'.join(plan.agents)']
print([rm.waiting_prompt(t, 3600) for t in code], rm.waiting_prompt('Do you want to proceed? (y/n)', 60), rm.waiting_prompt('Do you want to proceed? (y/n)', 5))
EOF
check "waiting_input only on a CLI prompt after silence, never on code lines" "$(python3 "$SCR/wp.py")" "[False, False, False, False] True False"

echo "--- discover: latest version of every family, smoke first, level from the tier table"
export AUTOPILOT_CONFIG_DIR=$SCR/cfg5; mkdir -p $AUTOPILOT_CONFIG_DIR; python3 "$SCR/fakeads.py" $AUTOPILOT_CONFIG_DIR
python3 -c "
import json,os
m=lambda cli,mid,fam,lv,**k: dict({'cli':cli,'model':mid,'family':fam,'level':lv,'subscription':'paid'},**k)
json.dump({'cooldown_minutes':30,'timeouts_seconds':{'implement':60,'review':60,'smoke':30,'idle':60},'health':{},'changelog':[],
 'tier_table':[{'match':'gpt-7-luna','level':2}],
 'models':{'cx-terra':m('codex','gpt-6.1-terra','gpt-*-terra',2),'cx-terra-b':m('codex','gpt-6.1-terra','gpt-*-terra',2,env={'CODEX_HOME':'~/.codex-b'}),
           'cx-luna':m('codex','gpt-6-luna','gpt-*-luna',3),'cl-sonnet':m('claude','claude-sonnet-5-5','claude-sonnet-*',2)}},
 open(os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json','w'))"
python3 -c "import json,os;p=os.environ['AUTOPILOT_CONFIG_DIR']+'/harnesses/claude.json';a=json.load(open(p));a['list_models']={'kind':'probe'};json.dump(a,open(p,'w'))"
MID() { python3 -c "import json,os;r=json.load(open(os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json'));print(' '.join('%s=%s/%s' % (k, m['model'], m['level']) for k, m in r['models'].items()))"; }
check "discover lists the newer family ids, applies nothing" "$(FAKE_MODELS='gpt-6.1-terra gpt-6.2-terra gpt-6-luna gpt-7-luna' $H/bin/run-model discover | python3 -c "import json,sys;d=json.load(sys.stdin);print(sorted((u['from'],u['to']) for u in d['upgrades']), [p['candidates'] for p in d['probes']])") $(MID)" "[('gpt-6-luna', 'gpt-7-luna'), ('gpt-6.1-terra', 'gpt-6.2-terra')] [['claude-sonnet-6-0', 'claude-sonnet-6', 'claude-sonnet-5-6']] cx-terra=gpt-6.1-terra/2 cx-terra-b=gpt-6.1-terra/2 cx-luna=gpt-6-luna/3 cl-sonnet=claude-sonnet-5-5/2"
FAKE_MODELS='gpt-6.1-terra gpt-6.2-terra gpt-6-luna gpt-7-luna' FAKE_BAD_MODELS='gpt-6.2-terra claude-sonnet-6-0 claude-sonnet-6 claude-sonnet-5-6' $H/bin/run-model discover --apply >/dev/null 2>&1
check "a candidate that fails its smoke is not applied, nothing cooled" "$(MID) $($H/bin/run-model health)" "cx-terra=gpt-6.1-terra/2 cx-terra-b=gpt-6.1-terra/2 cx-luna=gpt-7-luna/2 cl-sonnet=claude-sonnet-5-5/2 {}"
FAKE_MODELS='gpt-6.1-terra gpt-6.2-terra' FAKE_GOOD_MODELS='gpt-6.2-terra claude-sonnet-5-6' $H/bin/run-model discover --apply 2>$SCR/disc.err >/dev/null
check "upgrade after a fake smoke: every account moves, level kept; Claude probed to 5-6; changelog; reported" "$(MID) $(python3 -c "import json,os;r=json.load(open(os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json'));print(sum('discover:' in str(c.get('change','')) for c in r['changelog']))") $(grep -c 'upgraded' $SCR/disc.err)" "cx-terra=gpt-6.2-terra/2 cx-terra-b=gpt-6.2-terra/2 cx-luna=gpt-7-luna/2 cl-sonnet=claude-sonnet-5-6/2 3 2"
check "the tier table re-levels an upgraded id (gpt-7-luna -> Tier 2 by the owner's table)" "$(MID | tr ' ' '\n' | grep cx-luna)" "cx-luna=gpt-7-luna/2"
export AUTOPILOT_CONFIG_DIR=$SCR/cfg3; cd "$SCR/repo3"

echo "--- usage aggregation (fake probe via adapter override)"
python3 - <<'PY'
import json, os
cfg = os.environ['AUTOPILOT_CONFIG_DIR']
for cli in ('claude', 'codex', 'grok', 'agy', 'opencode', 'cursor', 'vibe'):
    p = os.path.join(cfg, 'harnesses', cli + '.json'); a = json.load(open(p))
    a['usage'] = {'kind': 'command', 'argv': ['usage'], 'regex': r'^(\w+) (\d+)%(?: resets (\S+))?$', 'groups': ['window', 'used', 'reset_iso']}
    json.dump(a, open(p, 'w'))
PY
R=$(FAKE_5H=100 FAKE_WEEK=50 $H/bin/run-model usage --apply | python3 -c "import json,sys;d=json.load(sys.stdin);print(sorted(k for k in d['exhausted_until_reset'] if k.startswith('fk-'))==['fk-a','fk-b','fk-c2','fk-c3','fk-d','fk-e','fk-f'])")
check "5h exhausted cools every key" "$R" "True"
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
R=$(FAKE_5H=10 FAKE_NO_WEEK=1 $H/bin/run-model usage --apply | python3 -c "import json,sys;d=json.load(sys.stdin);print('fk-b' in d['stale_quota_cooldowns_cleared'])")
check "a 5h-only reading does not clear a weekly cooldown" "$R" "False"
R=$(FAKE_5H=10 FAKE_WEEK=10 $H/bin/run-model usage --apply | python3 -c "import json,sys;d=json.load(sys.stdin);print('fk-b' in d['stale_quota_cooldowns_cleared'])")
check "a reading covering weekly clears it" "$R" "True"

echo "--- account standard"
$H/bin/harness add-account codex b --label "second login" >/dev/null 2>&1; check "add-account codex b (standard home)" "$?" "0"
check "cloned key uses CODEX_HOME=~/.codex-b, its own subscription (paid?)" "$(python3 -c "import json,os;r=json.load(open(os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json'));m=r['models']['fk-b-b'];print(m['env']['CODEX_HOME'], m['account_label'], m['subscription'])")" "~/.codex-b second login paid?"
$H/bin/harness add-account codex work >/dev/null 2>&1; check "add-account with a word instead of a letter refused" "$?" "1"
$H/bin/harness add-account codex c --home ~/.codex-other >/dev/null 2>&1; check "non-standard home without --nonstandard refused" "$?" "1"
$H/bin/harness add-account codex c --home ~/.codex-other --nonstandard >/dev/null 2>&1; check "non-standard home accepted with --nonstandard" "$?" "0"
$H/bin/harness discover 2>/dev/null | grep -q "NON-STANDARD home for fk-b-c" && echo "ok   discover flags the non-standard home" || { echo "FAIL discover did not flag ~/.codex-other"; FAIL=$((FAIL+1)); }
$H/bin/harness set-home codex ~/.codex-other ~/.codex-c >/dev/null; check "set-home moves the roster entries" "$(python3 -c "import json,os;r=json.load(open(os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json'));print(r['models']['fk-b-c']['env']['CODEX_HOME'])")" "~/.codex-c"
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
# The detached sleeper carries this run's own path as its argument: pgrep matches it only, never the sleeper of another
# selftest running on the machine at the same time (a machine-wide pattern made this check flaky under parallel runs).
$H/bin/bgrun --idle 6 --name stall --log $BG/st.log -- 'echo started; python3 -c "import os,time; os.setsid(); time.sleep(300)" '"$BG"'/sleeper & sleep 300' >$BG/st.out; BGRC=$?
check "bgrun: silent run stalls with exit 124" "$BGRC $(tail -1 $BG/st.out | grep -c '^bgrun stall: STALL no output')" "124 1"
check "bgrun: stall report has the process tree" "$(grep -c 'Process tree' $BG/st.log)" "1"
check "bgrun: detached descendants are killed" "$(for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$BG/sleeper" >/dev/null || break; sleep 0.5; done; pgrep -f "$BG/sleeper" | wc -l | tr -d ' ')" "0"
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
# milestones: per-milestone ETA bars, stages recomputed from blockers, a milestone added a posteriori with its
# pre-mortem, plan review, approval stop, decision, Linear creation (a local fake GraphQL server: no network) and sync.
MR=$SCR/ms-repo; mkdir -p $MR/.autopilot && (cd $MR && git init -q && cp $H/templates/PLAN.md PLAN.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm init) && echo ".autopilot/" >> $MR/.git/info/exclude
MB=$(git -C $MR branch --show-current)
MS() { AUTOPILOT_REPO=$MR ETA_LOAD=0 $H/bin/milestone "$@"; }
ETA() { AUTOPILOT_REPO=$MR ETA_LOAD=0 $H/bin/eta "$@"; }
J() { python3 -c "import json,sys; d=json.load(open('$1')); print($2)"; }
cat > $MR/.autopilot/state.json <<EOF
{"branch": "$MB", "project": "P", "project_id": "proj-1", "team": "ENG", "coordinator": "fk-a", "per_unit_min": 60,
 "parallel_target": 0, "queue": ["ENG-1", "ENG-2", "ENG-3", "ENG-4", "ENG-5"], "inflight": {}, "done": [],
 "sizes": {"ENG-1": "S", "ENG-2": "M", "ENG-3": "L", "ENG-4": 1, "ENG-5": 2},
 "stages": [["ENG-1", "ENG-2", "ENG-3", "ENG-4", "ENG-5"]]}
EOF
check "eta: S/M/L sizes, no milestones -> the single overall line" "$(ETA | grep -v '^REPLAN' | grep -cE '^\[[█░]{30}\] 0%  0 done, 0 in flight, 5 to do  \|  ETA ')" "1"
check "eta --json: L=3 units x 60 min" "$(ETA --json | python3 -c "import json,sys;print(json.load(sys.stdin)['minutes'])")" "180"
MS recompute >/dev/null 2>&1; check "recompute refused without blockers (would flatten stages)" "$?" "1"
python3 - <<EOF
import json; p='$MR/.autopilot/state.json'; s=json.load(open(p))
s['milestones'] = [{'id': 'm1', 'name': 'Foundation', 'issues': ['ENG-1', 'ENG-2']}, {'id': 'm2', 'name': 'Core', 'issues': ['ENG-3']},
                   {'id': 'm3', 'name': 'Polish', 'issues': ['ENG-4', 'ENG-5']}]
s['blockers'] = {'ENG-2': ['ENG-1'], 'ENG-3': ['ENG-2'], 'ENG-5': ['ENG-3']}
json.dump(s, open(p, 'w'))
EOF
check "eta: hand-edited stages that ignore a blocker are flagged" "$(ETA | grep -c 'REPLAN: stages out of step with blockers')" "1"
check "eta: a blocker outranks a stage that ignores it (ENG-2 after ENG-1, Polish after Core)" "$(ETA --json | python3 -c "import json,sys;print(*[m['minutes'] for m in json.load(sys.stdin)['milestones']])")" "300 480 600"
MS recompute >/dev/null
check "recompute: stages match the hand-computed fixture" "$(J $MR/.autopilot/state.json "json.dumps(d['stages'])")" '[["ENG-1", "ENG-4"], ["ENG-2"], ["ENG-3"], ["ENG-5"]]'
check "recompute: size-weighted critical path" "$(J $MR/.autopilot/state.json "' '.join(d['critical_path'])")" "ENG-1 ENG-2 ENG-3 ENG-5"
check "recompute: queue in stage order" "$(J $MR/.autopilot/state.json "' '.join(d['queue'])")" "ENG-1 ENG-4 ENG-2 ENG-3 ENG-5"
EO=$(ETA)
check "eta: 3 milestones -> 3 bars then the overall line" "$(echo "$EO" | grep -v '^REPLAN' | cut -c1-10 | tr '\n' '|')" "Foundation|Core      |Polish    |[░░░░░░░░░|"
check "eta: no out-of-step signal once recomputed" "$(echo "$EO" | grep -c 'out of step')" "0"
check "eta --json: per-milestone ETAs, cross-milestone dependency" "$(ETA --json | python3 -c "import json,sys;print(*[(m['id'], m['minutes'], m['total']) for m in json.load(sys.stdin)['milestones']])")" "('m1', 180, 2) ('m2', 360, 1) ('m3', 480, 2)"
# Fake Linear: ENG-1..5 exist, with the same blocks relations as the state.
python3 - <<EOF
import json
iss = [{'id': 'i%d' % n, 'identifier': 'ENG-%d' % n, 'title': 't%d' % n, 'projectId': 'proj-1', 'estimate': 1} for n in range(1, 6)]
rel = [{'issueId': 'i%d' % a, 'relatedIssueId': 'i%d' % b, 'type': 'blocks'} for a, b in ((1, 2), (2, 3), (3, 5))]
json.dump({'team': 'ENG', 'project_id': 'proj-1', 'milestones': [{'id': 'lm1', 'name': 'Foundation', 'projectId': 'proj-1', 'targetDate': None}],
           'issues': iss, 'relations': rel, 'updates': []}, open('$SCR/linear.json', 'w'))
EOF
python3 $H/tests/fake_linear.py $SCR/linear.json $SCR/linear.port & LPID=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s $SCR/linear.port ] && break; sleep 0.3; done
export LINEAR_API_URL=http://127.0.0.1:$(cat $SCR/linear.port)/graphql LINEAR_API_KEY=fake-key
NCALLS() { [ -f $SCR/linear.json.log ] && grep -c "${1:-.}" $SCR/linear.json.log || echo 0; }
python3 -c "import json;p='$MR/.autopilot/state.json';s=json.load(open(p));s.pop('blockers');s['stages']=[];s['milestones'][0]['linear_id']='lm1';json.dump(s,open(p,'w'))"
MS recompute --from-linear >/dev/null
check "recompute --from-linear: blockers reloaded, same stages" "$(J $MR/.autopilot/state.json "json.dumps(d['stages'])")" '[["ENG-1", "ENG-4"], ["ENG-2"], ["ENG-3"], ["ENG-5"]]'
# milestone add: validation, dry run, approval stop, then the approved run.
cat > $SCR/ext.json <<'EOF'
{"id": "ext", "name": "Extension", "description": "Adds the API and its UI.", "why": "the owner extends the project",
 "kpis": [{"id": "X1", "kpi": "API answers", "target": "200 on /health", "measure": "curl -f localhost:8000/health"}],
 "tickets": [{"slug": "api", "title": "API", "estimate": "M", "blocked_by": ["ENG-3"]},
             {"slug": "ui", "title": "UI", "estimate": 1, "blocked_by": ["api", "ENG-4"]}]}
EOF
BAD() { python3 -c "import json;s=json.load(open('$SCR/ext.json'));$1;json.dump(s,open('$SCR/bad.json','w'))"; MS add $SCR/bad.json --dry-run 2>&1 | grep -c "$2"; }
check "add: unknown dependency refused" "$(BAD "s['tickets'][0]['blocked_by']=['ENG-99']" "INVALID: api: blocked_by 'ENG-99'")" "1"
check "add: cycle refused" "$(BAD "s['tickets'][0]['blocked_by']=['ui']" 'INVALID: dependency cycle')" "1"
check "add: duplicate slug refused" "$(BAD "s['tickets'][1]['slug']='api'" 'INVALID: duplicate slugs')" "1"
check "add: a KPI without measurement refused" "$(BAD "s['kpis'][0]['measure']=''" 'INVALID: KPI X1 lacks measure')" "1"
DRY=$(MS add $SCR/ext.json --dry-run); RC=$?
check "add --dry-run: valid, exit 0" "$RC" "0"
check "add --dry-run: new tickets scheduled after their blockers" "$(echo "$DRY" | grep -E '^  stage (4|5):' | tr '\n' '|')" "  stage 4: ENG-5, +api|  stage 5: +ui|"
check "add --dry-run: ETA bar for the new milestone" "$(echo "$DRY" | grep -c '^  Extension  *\[░*\]   0%  0/2 done  |  ETA ')" "1"
check "add --dry-run: no external call, nothing written" "$(NCALLS) $([ -d $MR/.autopilot/plan/milestones ] && echo dir || echo none)" "0 none"
OUT=$(FAKE_BEHAVIOUR=auto MS add $SCR/ext.json --review-k 1 2>&1); RC=$?
check "add: pre-mortem + plan review, then stops for approval (exit 3)" "$RC" "3"
check "add: findings printed for approval" "$(echo "$OUT" | grep -cE '^(NEEDS APPROVAL|--- premortem: .*premortem.md|--- review: .*plan-review.md)')" "3"
check "add: milestone pre-mortem kept apart from the project's" "$(ls $MR/.autopilot/plan/milestones/ext/ | grep -cE '^(premortem.md|premortem.json|plan-review.md)$') $([ -e $MR/.autopilot/plan/premortem.md ] && echo leak || echo apart)" "3 apart"
check "add: pre-mortem scoped to the milestone, plan as context" "$(grep -c '^# Existing plan (context)' $MR/.autopilot/plan/milestones/ext/premortem-input.md)" "1"
check "add: nothing applied before approval" "$(NCALLS) $(J $MR/.autopilot/state.json "len(d['milestones'])")" "0 3"
OUT=$(FAKE_BEHAVIOUR=auto MS add $SCR/ext.json --review-k 1 2>&1); check "add: rerun without --approved still stops (no review rerun)" "$? $(echo "$OUT" | grep -c 'pre-mortem of milestone')" "3 0"
OUT=$(MS add $SCR/ext.json --approved --by owner --source 'user:"ship it"' 2>&1); RC=$?
check "add --approved: applied" "$RC" "0"
check "add: Linear milestone, 2 issues, 3 relations (2 on existing issues)" "$(NCALLS projectMilestoneCreate) $(NCALLS issueCreate) $(NCALLS issueRelationCreate)" "1 2 3"
check "add: issues assigned to the Linear milestone" "$(J $SCR/linear.json "sorted(i['identifier'] for i in d['issues'] if i.get('projectMilestoneId') == [m for m in d['milestones'] if m['name'] == 'Extension'][0]['id'])")" "['ENG-6', 'ENG-7']"
check "add: state milestones, blockers, recomputed stages" "$(J $MR/.autopilot/state.json "' '.join(m['id'] for m in d['milestones']) + ' ' + json.dumps(d['blockers']['ENG-7']) + ' ' + json.dumps(d['stages'][-2:])")" 'm1 m2 m3 ext ["ENG-6", "ENG-4"] [["ENG-5", "ENG-6"], ["ENG-7"]]'
check "add: milestone section appended in the Milestones section of PLAN.md" "$(awk '/<!-- milestone:ext -->/{m=NR} /^## Milestones/{s=NR} /^## Pre-mortem/{p=NR} END{print (s<m && m<p)}' $MR/PLAN.md) $(grep -c '| ui | ENG-7 | UI | 1 | ENG-6, ENG-4 |' $MR/PLAN.md)" "1 1"
check "add: decision logged and mirrored (decision check passes)" "$(AUTOPILOT_REPO=$MR $H/bin/decision list | grep -c 'milestone Extension added: 2 tickets  <- user:"ship it"') $(AUTOPILOT_REPO=$MR $H/bin/decision check >/dev/null; echo $?)" "1 0"
check "add: Linear target dates and one project update with every bar" "$(J $SCR/linear.json "sum(1 for m in d['milestones'] if m['targetDate'])") $(J $SCR/linear.json "len(d['updates'])") $(J $SCR/linear.json "d['updates'][0]['body'].count('done  |'), d['updates'][0]['body'].count('Overall')")" "2 1 4 1"
check "add: PLAN.md pushed as project content" "$(J $SCR/linear.json "'milestone:ext' in (d.get('content') or '')")" "True"
N=$(NCALLS)
OUT=$(MS add $SCR/ext.json --approved --by owner --source 'user:"ship it"' 2>&1); RC=$?
check "add: rerun after completion is a no-op" "$RC $(echo "$OUT" | grep -c 'already added') $(NCALLS)" "0 1 $N"
AUTOPILOT_REPO=$MR $H/bin/linear import $MR/.autopilot/plan/milestones/ext/tickets.json --team ENG --project-id proj-1 >/dev/null
check "linear import: rerun on the checkpoint creates nothing" "$(NCALLS projectMilestoneCreate) $(NCALLS issueCreate) $(NCALLS issueRelationCreate)" "1 2 3"
MS sync >/dev/null
check "sync: edits the recent project update instead of posting another" "$(NCALLS projectUpdateUpdate) $(J $SCR/linear.json "len(d['updates'])")" "1 1"
cat > $SCR/ext2.json <<'EOF'
{"name": "Docs", "description": "Docs.", "kpis": [{"kpi": "docs build", "target": "0 warnings", "measure": "mkdocs build --strict"}],
 "tickets": [{"slug": "docs", "title": "Docs", "estimate": "S", "blocked_by": ["ui"]}]}
EOF
MS add $SCR/ext2.json --skip-premortem "" >/dev/null 2>&1; check "add: a skip without its reason is refused" "$?" "1"
OUT=$(MS add $SCR/ext2.json --skip-premortem "one docs ticket" --skip-review "one docs ticket" --approved --by owner --source 'user:"docs too"' 2>&1); RC=$?
check "add: logged skips, blocker by slug of an earlier milestone" "$RC $(J $MR/.autopilot/state.json "d['blockers']['ENG-8']") $(grep -c 'premortem skipped: one docs ticket' $MR/PLAN.md)" "0 ['ENG-7'] 1"
python3 -c "import json;p='$SCR/linear.json';s=json.load(open(p));s['issues'].append({'id':'i60','identifier':'ENG-60','title':'orphan','projectId':'proj-1'});json.dump(s,open(p,'w'))"
AUTOPILOT_REPO=$MR $H/bin/state push queue '"ENG-60"' >/dev/null
MS adopt --id dup --name Dup --issues ENG-1 --by owner --source 'user:"x"' >/dev/null 2>&1; check "adopt: a ticket of another milestone refused" "$?" "1"
MS adopt --id later --name Later --issues ENG-60 --create-linear --by owner --source 'user:"group it"' >/dev/null
check "adopt --create-linear: milestone created, issue moved, state updated" "$(NCALLS projectMilestoneCreate) $(J $SCR/linear.json "[i for i in d['issues'] if i['identifier']=='ENG-60'][0].get('projectMilestoneId') is not None") $(J $MR/.autopilot/state.json "d['milestones'][-1]['issues']")" "3 True ['ENG-60']"
# ideas: captured in their own Linear milestone, never scheduled, promoted later through bin/milestone add.
IDEA() { AUTOPILOT_REPO=$MR LINEAR_RETRY_SLEEP=0 ETA_LOAD=0 $H/bin/idea "$@"; }
EJ() { ETA --json | python3 -c "import json,sys;e=json.load(sys.stdin);print(e['todo'], e['minutes'], [m['id'] for m in e['milestones']])"; }
E0=$(EJ); Q0=$(J $MR/.autopilot/state.json "d['queue']")
N=$(NCALLS); IDEA add "Idea dry" --words "x" --dry-run >/dev/null; check "idea add --dry-run: no Linear call, no state" "$(NCALLS) $(J $MR/.autopilot/state.json "'ideas' in d")" "$N False"
python3 -c "import json;p='$SCR/linear.json';s=json.load(open(p));s['fail']={'issueUpdate': 2};json.dump(s,open(p,'w'))"
OUT=$(IDEA add "RBAC like Claude Cowork" --words 'RBAC: like Claude Cowork, assign "agents" to projects' --note "roles: global, per project" --by owner 2>&1); RC=$?
check "idea add: prints the new identifier" "$RC $(echo "$OUT" | tail -1)" "0 ENG-61"
check "idea add: transient 'Entity not found' retried" "$(echo "$OUT" | grep -c 'Entity not found.*retry')" "2"
ID_MS=$(J $MR/.autopilot/state.json "d['ideas']['linear_milestone_id']")
check "idea add: Ideas milestone (no target date) + label created, issue in it, label idea, Backlog" "$(NCALLS projectMilestoneCreate) $(NCALLS issueLabelCreate) $(J $SCR/linear.json "[(m['name'], m['targetDate']) for m in d['milestones'] if m['id']=='$ID_MS'], [(i['projectMilestoneId']=='$ID_MS', [l['name'] for l in d['labels'] if l['id'] in i['labelIds']], i['stateId']) for i in d['issues'] if i['identifier']=='ENG-61']")" "4 1 [('Ideas (unscheduled)', None)] [(True, ['idea'], 'st-backlog')]"
check "idea add: the owner's words quoted verbatim, note, how to promote" "$(J $SCR/linear.json "[i['description'] for i in d['issues'] if i['identifier']=='ENG-61'][0]" | grep -cE '^> RBAC: like Claude Cowork, assign "agents" to projects$|^roles: global, per project$|/autopilot-idea promote')" "3"
check "idea add: PLAN.md backlog row, decision sourced with the words and synced, content pushed" "$(grep -c '^| ENG-61 | RBAC like Claude Cowork (roles: global, per project) |$' $MR/PLAN.md) $(AUTOPILOT_REPO=$MR $H/bin/decision list | grep 'idea captured: ENG-61 .*<- user:"RBAC: like Claude Cowork' | grep -vc '\[pending\]') $(J $SCR/linear.json "'| ENG-61 |' in d['content']")" "1 1 True"
IDEA add "Password manager like Grok Bot" --words "a password manager like Grok Bot, with Bitwarden import" --related ENG-61 >/dev/null 2>&1
check "idea add: second idea reuses milestone and label, related link" "$(NCALLS projectMilestoneCreate) $(NCALLS issueLabelCreate) $(J $SCR/linear.json "[(r['type'], r['relatedIssueId']) for r in d['relations'] if r['issueId']==[i['id'] for i in d['issues'] if i['identifier']=='ENG-62'][0]]")" "4 1 [('related', $(J $SCR/linear.json "repr([i['id'] for i in d['issues'] if i['identifier']=='ENG-61'][0])"))]"
N=$(NCALLS); OUT=$(IDEA add "RBAC like Claude Cowork" --words "again" 2>&1)
check "idea add: rerun of the same idea is a no-op" "$(echo "$OUT" | grep -c 'ENG-61  already captured') $(NCALLS) $(J $MR/.autopilot/state.json "d['ideas']['issues']")" "1 $N ['ENG-61', 'ENG-62']"
check "ideas: eta unchanged (no queue, no bar, no ETA)" "$(EJ) $(J $MR/.autopilot/state.json "d['queue']")" "$E0 $Q0"
MS recompute >/dev/null; E1=$(EJ); AUTOPILOT_REPO=$MR $H/bin/state push queue '"ENG-61"' >/dev/null; MS recompute >/dev/null
check "ideas: recompute drops an idea that slipped into the queue" "$(J $MR/.autopilot/state.json "'ENG-61' in d['queue'] or any('ENG-61' in s for s in d['stages'])") $(EJ)" "False $E1"
MS sync >/dev/null
check "ideas: sync never dates the Ideas milestone, update counts the ideas" "$(J $SCR/linear.json "[m['targetDate'] for m in d['milestones'] if m['id']=='$ID_MS']") $(J $SCR/linear.json "d['updates'][-1]['body']" | grep -c '^Ideas (unscheduled): 2 ideas, not scheduled')" "[None] 1"
check "idea list --json: state, related" "$(IDEA list --json | python3 -c "import json,sys;print([(r['identifier'], r['state'], r['related']) for r in json.load(sys.stdin)])")" "[('ENG-61', 'Backlog', ['ENG-62']), ('ENG-62', 'Backlog', ['ENG-61'])]"
python3 -c "import json;p='$SCR/linear.json';s=json.load(open(p));s['issues'].append({'id':'i70','identifier':'ENG-70','title':'Idea: private locations','projectId':'proj-1','labelIds':['old']});json.dump(s,open(p,'w'))"
IDEA adopt ENG-1 --source 'user:"x"' >/dev/null 2>&1; check "idea adopt: scheduled work refused" "$?" "1"
IDEA adopt ENG-70 --source 'user:"move the old ideas"' >/dev/null 2>&1
check "idea adopt: moved into the Ideas milestone, label added, Backlog, backlog row" "$(J $SCR/linear.json "[(i['projectMilestoneId']=='$ID_MS', i['labelIds'], i['stateId']) for i in d['issues'] if i['identifier']=='ENG-70']") $(J $MR/.autopilot/state.json "d['ideas']['issues']") $(grep -c '^| ENG-70 | private locations |$' $MR/PLAN.md)" "[(True, ['old', 'lbl-1'], 'st-backlog')] ['ENG-61', 'ENG-62', 'ENG-70'] 1"
MS adopt --id idm --name I --issues ENG-70 --by owner --source 'user:"x"' >/dev/null 2>&1; check "milestone adopt: an idea refused" "$?" "1"
IDEA promote ENG-61,ENG-99 --id rbac --name "RBAC and vault" >/dev/null 2>&1; check "idea promote: a non-idea refused" "$?" "1"
SPEC=$(IDEA promote ENG-61,ENG-62 --id rbac --name "RBAC and vault" | head -1)
check "idea promote: spec skeleton with from_ideas and one ticket per idea" "$(J $SPEC "d['from_ideas'], [(t['slug'], t['from_idea']) for t in d['tickets']], 'assign \"agents\"' in d['description']")" "['ENG-61', 'ENG-62'] [('rbac-like-claude-cowork', 'ENG-61'), ('password-manager-like-grok-bot', 'ENG-62')] True"
OUT=$(MS add $SPEC --dry-run 2>&1); check "promote spec: milestone add --dry-run accepts it, TODOs flagged" "$? $(echo "$OUT" | grep -c 'warning: .* is still TODO')" "0 6"
MS add $SPEC --skip-premortem t --skip-review t --approved --by owner --source 'user:"go"' >/dev/null 2>&1; check "promote spec: a real add refused while TODO" "$?" "1"
python3 -c "import json;p='$SPEC';s=json.load(open(p));s['kpis']=[{'id':'R1','kpi':'roles enforced','target':'0 cross-project reads','measure':'pytest tests/rbac'}];s['plan']='Roles, then the vault.';[t.update(description='do it') for t in s['tickets']];json.dump(s,open(p,'w'))"
OUT=$(MS add $SPEC --skip-premortem "ideas already discussed" --skip-review "test" --approved --by owner --source 'user:"go"' 2>&1); RC=$?
check "promote: milestone added with the promoted tickets" "$RC $(J $MR/.autopilot/state.json "d['milestones'][-1]['id'], d['milestones'][-1]['issues']")" "0 rbac ['ENG-71', 'ENG-72']"
check "promote hook: ideas closed as duplicates of their tickets, commented, out of the backlog" "$(J $SCR/linear.json "[(i['identifier'], i.get('stateId')) for i in d['issues'] if i['identifier'] in ('ENG-61','ENG-62')], sorted(tuple(next(i['identifier'] for i in d['issues'] if i['id']==x) for x in (r['issueId'], r['relatedIssueId'])) for r in d['relations'] if r['type']=='duplicate'), len(d.get('comments', []))") $(J $MR/.autopilot/state.json "d['ideas']['issues']")" "[('ENG-61', 'st-duplicate'), ('ENG-62', 'st-duplicate')] [('ENG-61', 'ENG-71'), ('ENG-62', 'ENG-72')] 2 ['ENG-70']"
check "promote hook: backlog rows struck through with the new tickets" "$(grep -c '^| ENG-61 | ~~RBAC like Claude Cowork (roles: global, per project)~~ promoted to RBAC and vault (ENG-71) |$' $MR/PLAN.md)" "1"
N=$(NCALLS); MS add $SPEC --approved --by owner --source 'user:"go"' >/dev/null 2>&1; check "promote: rerun after completion is a no-op" "$? $(NCALLS)" "0 $N"
SD=$SCR/seed-repo; mkdir -p $SD/.autopilot/plan && echo '{"branch": "x", "queue": [], "done": []}' > $SD/.autopilot/state.json
cat > $SD/.autopilot/plan/tickets.json <<'EOF'
{"project": {"name": "P"}, "milestones": [{"name": "M1 Base"}, {"name": "M2 More"}],
 "tickets": [{"slug": "a", "title": "A", "milestone": "M1 Base", "estimate": 1},
             {"slug": "b", "title": "B", "milestone": "M2 More", "estimate": "L", "blocked_by": ["a"]},
             {"slug": "c", "title": "C", "milestone": "M1 Base", "estimate": 2}]}
EOF
echo '{"milestones": {"M1 Base": "l1", "M2 More": "l2"}, "tickets": {"a": {"identifier": "E-1"}, "b": {"identifier": "E-2"}, "c": {"identifier": "E-3"}}}' > $SD/.autopilot/plan/tickets.created.json
AUTOPILOT_REPO=$SD $H/bin/milestone seed $SD/.autopilot/plan/tickets.json >/dev/null
check "seed: milestones from tickets.json, stages from blocked_by" "$(J $SD/.autopilot/state.json "[(m['id'], m['linear_id'], m['issues']) for m in d['milestones']], d['stages'], d['critical_path']")" "[('m1-base', 'l1', ['E-1', 'E-3']), ('m2-more', 'l2', ['E-2'])] [['E-1', 'E-3'], ['E-2']] ['E-1', 'E-2']"
AUTOPILOT_REPO=$SD $H/bin/milestone seed $SD/.autopilot/plan/tickets.json >/dev/null 2>&1; check "seed: refused once milestones exist" "$?" "1"
# Codex resets and CRITICAL alerts: a roster of its own (two "Codex-like" accounts read from session logs, one xai key),
# the fake reset script (never the real codex-reset), the fake Linear server still running from the milestone tests.
echo "--- auto-reset, stale usage, CRITICAL alerts"
export AUTOPILOT_CONFIG_DIR=$SCR/cfg4; AC=$SCR/acct; mkdir -p $AUTOPILOT_CONFIG_DIR/harnesses $AC/a $AC/b $AC/x
cat > "$SCR/fake/fakeacct" <<'EOF'
#!/bin/bash
[ -f "${FAKE_HOME:-$SCR/acct/a}/down" ] && { echo "usage limit reached"; exit 1; }
echo AUTOPILOT_OK
EOF
chmod +x "$SCR/fake/fakeacct"
python3 - <<'PY'
import json, os
S = os.environ['SCR']; ac = os.path.join(S, 'acct'); cfg = os.environ['AUTOPILOT_CONFIG_DIR']
# Two Codex-like accounts (vendor openai, so the adapter is named codex: vendor -> CLI) and one xAI account (grok).
for name, extra in (('codex', {'auto_reset': {'window': 'weekly', 'argv': [os.path.join(S, 'fake', 'fake-reset'), '--yes', '--account', '{account}']}}), ('grok', {})):
    json.dump(dict({'name': name, 'binary': 'fakeacct', 'vendor': 'by_model', 'run': {'argv': ['-p', '{prompt}'], 'env': {}, 'output': 'stdout'},
                    'account_env': 'FAKE_HOME', 'account_default': os.path.join(ac, 'a'),
                    'usage': {'kind': 'codex_sessions', 'path': '$FAKE_HOME/sessions', 'windows': {'300min': '5h', '10080min': 'weekly'}},
                    'quota_patterns': ['usage limit']}, **extra), open(os.path.join(cfg, 'harnesses', name + '.json'), 'w'))
m = lambda cli, model, home, vendor, level: {'cli': cli, 'model': model, 'vendor': vendor, 'level': level, 'subscription': 'paid', 'tier': model, 'family': model,
                                               **({'env': {'FAKE_HOME': os.path.join(ac, home)}} if home else {})}
json.dump({'cooldown_minutes': 30, 'timeouts_seconds': {'implement': 60, 'review': 60, 'smoke': 30, 'idle': 60}, 'health': {}, 'changelog': [],
           'models': {'fa-a': m('codex', 'gpt-a', None, 'openai', 1), 'fa-b': m('codex', 'gpt-a', 'b', 'openai', 1), 'fx': m('grok', 'grok-y', 'x', 'xai', 2)}},
          open(os.path.join(cfg, 'models.json'), 'w'))
PY
# SESS <account> <5h %> <weekly %> <minutes ago>: the newest Codex-style rate_limits record of that account.
SESS() { mkdir -p $AC/$1/sessions/2026/11/09; python3 -c "
import json, datetime as d
t = d.datetime.now(d.timezone.utc) - d.timedelta(minutes=$4)
rl = {'primary': {'window_minutes': 300, 'used_percent': $2, 'resets_at': 4070908800}, 'secondary': {'window_minutes': 10080, 'used_percent': $3, 'resets_at': 4070995200}}
print(json.dumps({'timestamp': t.isoformat(), 'type': 'event_msg', 'payload': {'type': 'token_count', 'rate_limits': rl}}))" > $AC/$1/sessions/2026/11/09/r.jsonl; }
CLEAN() { python3 -c "
import json,os;p=os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json';r=json.load(open(p))
for k in ('health','resets','last_ok'): r[k]={}
r['codex_auto_reset']=True; r.update($1);json.dump(r,open(p,'w'))"; rm -f $SCR/resets.log $AC/*/down; }
NRESET() { [ -f $SCR/resets.log ] && wc -l < $SCR/resets.log | tr -d ' ' || echo 0; }
HEALTH() { python3 -c "import json,os;print(sorted(json.load(open(os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json'))['health']))"; }
AR=$SCR/ar-repo; mkdir -p $AR/.autopilot && (cd $AR && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)
echo "{\"branch\": \"$(git -C $AR branch --show-current)\", \"project_id\": \"proj-1\", \"coordinator\": \"fx\", \"queue\": [\"T-1\"], \"inflight\": {}, \"done\": [], \"per_unit_min\": 60}" > $AR/.autopilot/state.json
cd $AR; export AUTOPILOT_REPO=$AR
SESS x 10 10 1
CLEAN '{}'; SESS a 100 50 1; SESS b 10 10 1
$H/bin/run-model usage --apply >/dev/null 2>&1
check "auto-reset: a 5-hour limit alone never claims a reset, the account cools down" "$(NRESET) $(HEALTH)" "0 ['fa-a']"
CLEAN '{}'; SESS a 100 100 1; echo ok > $SCR/reset.mode
U=$($H/bin/run-model usage --apply 2>$SCR/u.err)
check "auto-reset: weekly 100% claims the account's reset once, through the adapter (codex-reset --yes --account)" "$(cat $SCR/resets.log)" "--yes --account default"
check "auto-reset: redeemed, smoke ok, cooldowns cleared, the triggering reading now stale" "$(echo "$U" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['resets'][0]['result'][:30], d['exhausted_until_reset'], [(s['account'], s['window']) for s in d['stale_readings_skipped']])") $(HEALTH)" "redeemed, smoke ok (fa-a), coo [] [('default', '5h'), ('default', 'weekly')] []"
check "auto-reset: attempt recorded in the roster with the window, time and result" "$(python3 -c "import json,os;r=json.load(open(os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json'))['resets']['codex/default'];print(r['window'], r['window_reset'][:10], bool(r['at']), r['result'][:8])")" "weekly 2099-01-02 True redeemed"
CLEAN '{}'; SESS a 100 100 1; touch $AC/a/down
U=$($H/bin/run-model usage --apply 2>/dev/null); $H/bin/run-model usage --apply >/dev/null 2>&1
check "auto-reset: once per account per weekly window (smoke failed: cooled, no second claim)" "$(NRESET) $(HEALTH) $(echo "$U" | python3 -c "import json,sys;print(json.load(sys.stdin)['resets'][0]['result'][:22])")" "1 ['fa-a'] redeemed, smoke failed"
CLEAN '{"codex_auto_reset": False}'; SESS a 100 100 1
$H/bin/run-model usage --apply >/dev/null 2>&1
check "auto-reset: disabled by models.json codex_auto_reset=false" "$(NRESET) $(HEALTH)" "0 ['fa-a']"
CLEAN '{}'; SESS a 100 100 1; touch $AC/a/down; echo x > $SCR/rb.md
$H/bin/run-model run review $SCR/rb.md $SCR/rb.out --cwd $AR --standalone --role milestone_review --exclude-vendor anthropic --model fa-a >/dev/null 2>&1
check "auto-reset: a run that hits its quota claims the weekly reset too" "$(NRESET) $(cat $SCR/resets.log)" "1 --yes --account default"
# Stale usage: a reading taken before a successful smoke of the account is not re-applied.
CLEAN '{"codex_auto_reset": False}'; SESS a 100 100 30
$H/bin/run-model smoke fa-a >/dev/null
U=$($H/bin/run-model usage --apply 2>$SCR/u.err)
check "stale usage: 100% reading older than a successful smoke is skipped, no cooldown" "$(echo "$U" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['exhausted_until_reset'], len(d['stale_readings_skipped']))") $(HEALTH) $(grep -c 'stale reading skipped: codex default weekly' $SCR/u.err)" "[] 2 [] 1"
SESS a 100 100 0; sleep 1
check "stale usage: a reading newer than the smoke still applies" "$($H/bin/run-model usage --apply 2>/dev/null >/dev/null; HEALTH)" "['fa-a']"
# CRITICAL: both accounts of the vendor out, no reset available.
CLEAN '{}'; SESS a 100 100 1; SESS b 100 100 1; echo none > $SCR/reset.mode
NU=$(J $SCR/linear.json "len(d['updates'])")
$H/bin/run-model usage --apply >/dev/null 2>$SCR/u.err
check "critical: both resets attempted, none available" "$(NRESET) $(HEALTH)" "2 ['fa-a', 'fa-b']"
check "critical: CRITICAL line on stderr names the vendor and the blocked plan review" "$(grep -c '^CRITICAL: openai out of quota on every account (codex/FAKE_HOME=.*/b, codex/default); blocked pools: milestone_review, plan_review, premortem; earliest reset ' $SCR/u.err)" "1"
check "critical: alerts.jsonl entry (vendor, accounts, reset results, pools, earliest reset)" "$(python3 -c "
import json; a=[json.loads(l) for l in open('$AR/.autopilot/alerts.jsonl')]; d=a[0]['details']
print(len(a), a[0]['level'], d['vendor'], len(d['accounts']), sorted(v[:18] for v in d['resets'].values()), d['blocked_pools'], d['earliest_reset'][:10])")" "1 CRITICAL openai 2 ['no reset available', 'no reset available'] ['milestone_review', 'plan_review', 'premortem'] 2099-01-02"
check "critical: one Linear project update titled CRITICAL: openai out of quota" "$(J $SCR/linear.json "len(d['updates']) - $NU, d['updates'][-1]['body'].splitlines()[0]")" "1 CRITICAL: openai out of quota"
$H/bin/run-model usage --apply >/dev/null 2>&1
check "critical: rerun keeps one alert, no second Linear update, no second reset" "$(wc -l < $AR/.autopilot/alerts.jsonl | tr -d ' ') $(J $SCR/linear.json "len(d['updates']) - $NU") $(NRESET)" "1 1 2"
check "critical: bin/alert list shows it" "$($H/bin/alert list | grep -c '^CRITICAL: \[.*-openai\] openai out of quota.*ACTIVE')" "1"
AID=$(python3 -c "import json;print(json.loads(open('$AR/.autopilot/alerts.jsonl').readline())['id'])")
check "critical: bin/eta prints it first" "$(ETA_LOAD=0 $H/bin/eta | head -1 | cut -d']' -f1)" "CRITICAL: [$AID"
check "critical: a run prints CRITICAL on stderr too" "$(echo x > $SCR/rb.md; $H/bin/run-model run review $SCR/rb.md $SCR/rb.out --cwd $AR --standalone --exclude-vendor anthropic --model fx 2>&1 >/dev/null | grep -c '^CRITICAL: openai')" "1"
python3 -c "import json,os;p=os.environ['AUTOPILOT_CONFIG_DIR']+'/models.json';r=json.load(open(p));r['health']={};json.dump(r,open(p,'w'))"
$H/bin/run-model alerts >/dev/null 2>&1
check "critical: resolved once a key is back, still listed until acknowledged" "$($H/bin/alert list | grep -c 'resolved')" "1"
$H/bin/alert ack all >/dev/null
check "critical: acknowledged -> gone from alert list and eta" "$($H/bin/alert list | wc -l | tr -d ' ') $(ETA_LOAD=0 $H/bin/eta | grep -c CRITICAL)" "0 0"
unset AUTOPILOT_REPO
echo "=== $PASS passed, $FAIL failed"
