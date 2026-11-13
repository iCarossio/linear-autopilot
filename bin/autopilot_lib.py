"""Shared rules of the linear-autopilot runtime. Every bin/ script imports this so that identity, exclusions,
config transactions, tree snapshots and verdict validation are enforced in exactly one place.

Config: $AUTOPILOT_CONFIG_DIR (default ~/.config/linear-autopilot): models.json (roster, accounts, pools, health),
harnesses/ (adapter overrides), prompts/ (template overrides). Per project: <repo>/.autopilot/state.json.
Python 3.9+ (no match statements, no nested same-quote f-strings).
"""
import contextlib, datetime as dt, fcntl, glob, hashlib, json, os, re, shutil, subprocess, sys, tarfile, tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
HOME = os.path.dirname(HERE)
CONFIG_DIR = os.path.expanduser(os.environ.get('AUTOPILOT_CONFIG_DIR') or '~/.config/linear-autopilot')
REG = os.path.join(CONFIG_DIR, 'models.json')
VERDICTS = ('approve', 'changes_required')
SEVERITIES = ('blocker', 'major', 'minor')
BLOCKING = ('blocker', 'major')
IMPACTS = ('fatal', 'severe', 'moderate')
COSTS = ('high', 'mid', 'cheap', 'free')
IGNORE_PREFIXES = ('.autopilot/', '.tmp/')


def now():
    return dt.datetime.now(dt.timezone.utc)


def parse_time(s):
    return dt.datetime.fromisoformat(s.replace('Z', '+00:00'))


# ---------- config transactions (one lock per file, unique temp files, atomic rename) ----------

@contextlib.contextmanager
def locked(path):
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    with open(path + '.lock', 'a+') as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def read_json(path):
    with open(path) as f:
        return json.load(f)


def write_json_atomic(path, data):
    d = os.path.dirname(path) or '.'
    fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(path) + '.', dir=d)
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


_WARNED = set()


def load_reg(warn=True):
    """The roster. Entries that break the tier policy (vendor -> CLI, level) are reported once per process on stderr;
    they stay in the file (so `bin/harness` can fix or remove them) but no pool ever selects them (see `refused`)."""
    if not os.path.exists(REG):
        sys.exit('no roster at %s. Run the autopilot-init skill (bin/harness init).' % REG)
    r = read_json(REG)
    if warn:
        try:
            bad = refused(r)
        except SystemExit:
            raise
        except Exception:
            bad = {}
        for k, why in sorted(bad.items()):
            if (k, why) not in _WARNED:
                _WARNED.add((k, why))
                print('roster: refused %s: %s' % (k, why), file=sys.stderr)
    return r


def update_reg(fn):
    """Locked read-modify-write of the roster. fn(r) mutates r and may return a value."""
    with locked(REG):
        r = load_reg(warn=False)
        out = fn(r)
        write_json_atomic(REG, r)
        return out


def state_path(repo):
    return os.path.join(repo, '.autopilot', 'state.json')


def load_state(repo):
    p = state_path(repo)
    return read_json(p) if os.path.exists(p) else {}


def update_state(repo, fn):
    """Locked read-modify-write of the project state. Coordinators use `bin/state` (same lock) for their own edits."""
    with locked(state_path(repo)):
        st = load_state(repo)
        out = fn(st)
        write_json_atomic(state_path(repo), st)
        return out


def find_repo(required=True, start=None):
    if os.environ.get('AUTOPILOT_REPO'):
        return os.environ['AUTOPILOT_REPO']
    d = os.path.abspath(start or os.getcwd())
    while d != '/':
        if os.path.exists(state_path(d)):
            return d
        d = os.path.dirname(d)
    if required:
        sys.exit('no .autopilot/state.json found above the current directory (set AUTOPILOT_REPO)')
    return None


# ---------- harness adapters, accounts, vendors, model identity ----------

def adapters():
    out = {}
    for d in (os.path.join(HOME, 'harnesses'), os.path.join(CONFIG_DIR, 'harnesses')):
        for p in sorted(glob.glob(os.path.join(d, '*.json'))):
            a = read_json(p); a['_path'] = p; out[a['name']] = a
    return out


def adapter_of(m, ad=None):
    a = (ad or adapters()).get(m['cli'])
    if not a:
        raise SystemExit("unknown harness '%s': add harnesses/%s.json (autopilot-init, bin/harness new)" % (m['cli'], m['cli']))
    return a


def effective_env(m, a):
    """The one environment a roster entry runs with, and that identity and path expansion use: the process
    environment without the account variable (a base entry is the default account), then the adapter's env, then the
    entry's account override (e.g. CODEX_HOME)."""
    env = dict(os.environ)
    if a.get('account_env') and a['account_env'] not in m.get('env', {}):
        # a base entry is the CLI's default account, whatever account the coordinator session itself runs on
        env.pop(a['account_env'], None)
    env.update({k: os.path.expanduser(str(v)) for k, v in a.get('run', {}).get('env', {}).items()})
    env.update({k: os.path.expanduser(str(v)) for k, v in m.get('env', {}).items()})
    return env


def expand_path(path, a, env):
    """~ and $VAR / ${VAR} against the effective env; the adapter's account_default only when the var is unset."""
    full = dict(env)
    k = a.get('account_env')
    if k and not full.get(k):
        full[k] = os.path.expanduser(a.get('account_default', ''))
    return os.path.expanduser(re.sub(r'\$\{?(\w+)\}?', lambda mt: full.get(mt.group(1), mt.group(0)), path))


def explicit_account(m, a):
    """The account a roster entry declares itself (its own env override), or None for the base entry."""
    k = a.get('account_env') if a else None
    return m.get('env', {}).get(k) if k else None


def account_of(m, a):
    """Account label as the CLI will see it: the declared override, else the inherited process env, else default."""
    k = a.get('account_env') if a else None
    if not k:
        return 'default'
    v = effective_env(m, a).get(k)
    default = os.path.expanduser(a.get('account_default', '')) if a.get('account_default') else ''
    if not v or (default and os.path.realpath(os.path.expanduser(v)) == os.path.realpath(default)):
        return 'default'
    return '%s=%s' % (k, v)


def account_homes(a, reg=None):
    """Every account of a harness present on this machine, as (label, home): the default home as `<cli>`, the standard
    `<default>-<letter>` homes as `<cli>-<letter>`, and any non-standard home the roster declares as `<cli>@<home>`.
    A harness without account_env has one account, label `<cli>`, home None. Only existing directories count."""
    cli = a['name']
    k = a.get('account_env')
    if not k:
        return [(cli, None)]
    default = os.path.expanduser(a.get('account_default', '')).rstrip('/')
    out, seen = [], set()
    if default and os.path.isdir(default):
        out.append((cli, default)); seen.add(os.path.realpath(default))
    for p in sorted(glob.glob(os.path.expanduser(a.get('account_detect') or (default + '-[a-z]')))):
        if os.path.isdir(p) and os.path.realpath(p) not in seen:
            out.append(('%s-%s' % (cli, os.path.basename(p).rsplit('-', 1)[-1]), p.rstrip('/'))); seen.add(os.path.realpath(p))
    for m in (reg or {}).get('models', {}).values():
        if m.get('cli') != cli:
            continue
        home = explicit_account(m, a)
        if home and os.path.isdir(os.path.expanduser(home)) and os.path.realpath(os.path.expanduser(home)) not in seen:
            out.append(('%s@%s' % (cli, home.replace(os.path.expanduser('~'), '~')), os.path.expanduser(home).rstrip('/'))); seen.add(os.path.realpath(os.path.expanduser(home)))
    return out


VENDOR_HINTS = [('claude', 'anthropic'), ('gpt', 'openai'), ('codex', 'openai'), (r'\bo\d-', 'openai'), ('gemini', 'google'),
                ('grok', 'xai'), ('deepseek', 'deepseek'), ('glm', 'zhipu'), ('mistral', 'mistral'), ('devstral', 'mistral'),
                ('qwen', 'alibaba'), ('kimi', 'moonshot'), ('llama', 'meta'), ('nemotron', 'nvidia'), ('mimo', 'xiaomi'), ('beam', 'opencode')]


def vendor_of(m, a=None):
    if m.get('vendor'):
        return m['vendor']
    a = a or adapter_of(m)
    if a.get('vendor') and a['vendor'] != 'by_model':
        return a['vendor']
    mid = m['model'].lower()
    for hint, v in VENDOR_HINTS:
        if re.search(hint, mid):
            return v
    return m['cli']


def canonical_id(model):
    """The underlying model, whatever harness exposes it: provider prefixes (`opencode/`, `openrouter/anthropic/`),
    variant suffixes (`:free`, `#max`, `-thinking`, `-high`) and separators are stripped. A roster entry may
    pin its own `canonical` when the heuristic is wrong."""
    s = str(model).lower().split('/')[-1]
    s = re.sub(r'[#:].*$', '', s)
    for _ in range(3):  # peel stacked suffixes: `-flash-free`, `-thinking-high`, ...
        s = re.sub(r'-(thinking|high|medium|low|max|latest|preview|free|beta)$', '', s)
    return re.sub(r'[^a-z0-9]+', '-', s).strip('-')


def model_identity(m):
    return m.get('canonical') or canonical_id(m['model'])


def healthy(r, key):
    h = r['health'].get(key)
    return not h or parse_time(h['until']) < now()


def cool(key, reason, minutes=None, windows=None):
    """windows: the quota windows responsible (e.g. ['5h', 'weekly']); a cooldown is cleared by `usage --apply` only
    when a newer below-quota reading covers every one of them."""
    def fn(r):
        m = minutes or r.get('cooldown_minutes', 30)
        r['health'][key] = {'until': (now() + dt.timedelta(minutes=m)).isoformat(), 'reason': reason[:200], 'set_at': now().isoformat(),
                            'windows': sorted(windows) if windows else None}
    update_reg(fn)


def record_ok(key):
    """A successful run or smoke of `key`: proof that its quota windows were open at this time. `run-model usage
    --apply` treats any reading observed before it as stale (see last_ok)."""
    update_reg(lambda r: r.setdefault('last_ok', {}).__setitem__(key, now().isoformat()))


def last_ok(r, keys):
    """Latest successful run or smoke among `keys`, as a datetime, or None."""
    ts = [parse_time(r.get('last_ok', {})[k]) for k in keys if k in r.get('last_ok', {})]
    return max(ts) if ts else None


# ---------- critical alerts (the coordinator must tell the owner; see bin/alert) ----------
# One JSON object per line: id, level, kind (vendor_out | pool_blocked), key (vendor or pool), at, message, details,
# acked_at, resolved_at. Written to <repo>/.autopilot/alerts.jsonl, or to $AUTOPILOT_CONFIG_DIR/alerts.jsonl when the
# writer runs outside a project. An alert stays listed until it is acknowledged, even once resolved, so an outage that
# ended while the owner was away is still reported.

def alerts_path(repo):
    return os.path.join(repo, '.autopilot', 'alerts.jsonl') if repo else os.path.join(CONFIG_DIR, 'alerts.jsonl')


def read_alerts(path):
    try:
        with open(path) as f:
            return [json.loads(l) for l in f if l.strip()]
    except (OSError, ValueError):
        return []


def update_alerts(repo, fn):
    """Locked read-modify-write of one alerts file. fn(alerts) mutates the list and may return a value."""
    path = alerts_path(repo)
    with locked(path):
        al = read_alerts(path)
        out = fn(al)
        d = os.path.dirname(path)
        fd, tmp = tempfile.mkstemp(prefix='.alerts.', dir=d)
        with os.fdopen(fd, 'w') as f:
            f.write(''.join(json.dumps(a) + '\n' for a in al))
        os.replace(tmp, path)
        return out


def alerts(repo, include_acked=False):
    """Alerts of the project and the machine-level ones (written outside a project), unacknowledged unless asked."""
    paths = list(dict.fromkeys([alerts_path(repo), alerts_path(None)]))
    return [dict(a, _file=p) for p in paths for a in read_alerts(p) if include_acked or not a.get('acked_at')]


def alert_line(a):
    state = 'resolved %s' % a['resolved_at'][:16] if a.get('resolved_at') else 'ACTIVE'
    return '%s: [%s] %s (since %s, %s)' % (a.get('level', 'CRITICAL'), a['id'], a['message'], a['at'][:16], state)


def issue_from_brief(path):
    mt = re.match(r'(.+?)-(impl|review|plan|diag)-', os.path.basename(path))
    return mt.group(1) if mt else None


def expand_exclusions(reg, keys=(), vendors=(), identities=(), ad=None):
    """Every roster key that must not be used: the keys given, every key whose underlying model is the same as any
    of them or of `identities` (another account, another harness, an upgraded or removed key), and every key of
    the vendors given."""
    ad = ad or adapters()
    ex = set(k for k in keys if k)
    ids = set(i for i in identities if i) | {model_identity(reg['models'][k]) for k in ex if k in reg['models']}
    for k, m in reg['models'].items():
        if model_identity(m) in ids or (vendors and vendor_of(m, ad.get(m['cli'])) in vendors):
            ex.add(k)
    return ex


def implementers_of(repo, issue):
    """(roster keys, model identities) recorded for a ticket. Identities survive roster edits."""
    st = load_state(repo) if repo else {}
    if not issue:
        return [], []
    return list(st.get('implementers', {}).get(issue, [])), list(st.get('implementer_ids', {}).get(issue, []))


def record_implementer(repo, issue, key, m, a):
    def fn(st):
        keys = st.setdefault('implementers', {}).setdefault(issue, [])
        if key not in keys:
            keys.append(key)
        ids = st.setdefault('implementer_ids', {}).setdefault(issue, [])
        ident = model_identity(m)
        if ident not in ids:
            ids.append(ident)
        st.setdefault('implementer_log', {}).setdefault(issue, []).append(
            {'key': key, 'model': m['model'], 'identity': ident, 'account': account_of(m, a), 'at': now().isoformat()})
    update_state(repo, fn)


# ---------- working tree snapshots (reviewers must not change the tree; some do) ----------

def git(cwd, *a):
    return subprocess.run(['git', '-C', cwd, *a], capture_output=True, text=True)


def is_git(cwd):
    return git(cwd, 'rev-parse', '--git-dir').returncode == 0


def untracked(cwd):
    return [f for f in git(cwd, 'ls-files', '-o', '--exclude-standard', '-z').stdout.split('\0') if f]


def head_state(cwd):
    return git(cwd, 'rev-parse', 'HEAD').stdout.strip() + ' ' + git(cwd, 'rev-parse', '--abbrev-ref', 'HEAD').stdout.strip()


def tracked_state(cwd):
    """Status + unstaged and staged diffs with full binary patches, so a rewritten binary changes it too."""
    return (git(cwd, 'status', '--porcelain').stdout + git(cwd, 'diff', '--binary').stdout + git(cwd, 'diff', '--cached', '--binary').stdout)


def file_digest(path, limit=64 * 1024 * 1024):
    h = hashlib.sha1()
    try:
        st = os.stat(path)
        if st.st_size > limit:
            return 'big:%d:%d' % (st.st_size, st.st_mtime_ns)
        with open(path, 'rb') as f:
            for chunk in iter(lambda: f.read(1 << 20), b''):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return 'missing'


def untracked_digest(cwd, ignore_prefixes=IGNORE_PREFIXES):
    return {f: file_digest(os.path.join(cwd, f)) for f in sorted(untracked(cwd)) if not f.startswith(ignore_prefixes)}


def tree_fingerprint(cwd, ignore_prefixes=IGNORE_PREFIXES):
    """HEAD + branch + tracked state (binary-safe) + content digest of every untracked file. None outside git."""
    if not is_git(cwd):
        return None
    h = hashlib.sha1()
    h.update(head_state(cwd).encode())
    h.update(tracked_state(cwd).encode(errors='ignore'))
    for f, d in untracked_digest(cwd, ignore_prefixes).items():
        h.update(('%s\0%s\n' % (f, d)).encode(errors='ignore'))
    return h.hexdigest()


def snapshot(cwd, ignore_prefixes=IGNORE_PREFIXES):
    """Tracked changes as a stash commit (does not touch files), staged state, untracked files in a tar, HEAD."""
    if not is_git(cwd):
        return None
    d = tempfile.mkdtemp(prefix='autopilot-snap-')
    snap = {'stash': git(cwd, 'stash', 'create').stdout.strip() or None, 'tar': os.path.join(d, 'untracked.tar'),
            'cached': git(cwd, 'diff', '--cached', '--binary').stdout, 'ignore': ignore_prefixes, 'head': head_state(cwd)}
    files = [f for f in untracked(cwd) if not f.startswith(ignore_prefixes)]
    with tarfile.open(snap['tar'], 'w') as tf:
        for f in files:
            try:
                tf.add(os.path.join(cwd, f), arcname=f)
            except FileNotFoundError:
                pass
    snap['untracked'] = untracked_digest(cwd, ignore_prefixes)
    snap['tracked'] = tracked_state(cwd)
    snap['fp'] = tree_fingerprint(cwd, ignore_prefixes)
    return snap


def restore(cwd, snap, junk_label='reviewer-junk'):
    """'unchanged', 'restored', 'history_changed' (HEAD or branch moved: never rewritten automatically, the caller
    stops) or 'restore_failed'. New untracked files are moved to .tmp/<junk_label>/."""
    if not snap:
        return 'unchanged'
    if tree_fingerprint(cwd, snap['ignore']) == snap['fp']:
        return 'unchanged'
    if head_state(cwd) != snap['head']:
        return 'history_changed'
    git(cwd, 'reset', '-q')
    git(cwd, 'checkout', '--', '.')
    if snap['stash']:
        git(cwd, 'stash', 'apply', '-q', snap['stash'])
    if snap['cached']:
        subprocess.run(['git', '-C', cwd, 'apply', '--cached', '--allow-empty'], input=snap['cached'], text=True, capture_output=True)
    junk = os.path.join(cwd, '.tmp', junk_label)
    for f in untracked(cwd):
        if f.startswith(snap['ignore']) or f in snap['untracked']:
            continue
        dst = os.path.join(junk, f)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        try:
            os.replace(os.path.join(cwd, f), dst)
        except FileNotFoundError:
            pass
    with tarfile.open(snap['tar']) as tf:
        tf.extractall(cwd)
    ok = tracked_state(cwd) == snap['tracked'] and untracked_digest(cwd, snap['ignore']) == snap['untracked']
    return 'restored' if ok else 'restore_failed'


# ---------- verdicts ----------

def digest_text(text):
    return hashlib.sha1(text.encode(errors='ignore')).hexdigest()


def parse_json_block(path):
    t = open(path, errors='ignore').read() if os.path.exists(path) else ''
    blocks = re.findall(r'```json\s*(\{.*?\})\s*```', t, re.S) or re.findall(r'(\{\s*"verdict".*\})', t, re.S)
    for b in reversed(blocks):
        try:
            return json.loads(b)
        except Exception:
            pass
    return None


def validate_verdict(v):
    """(status, blocking lines). status: 'approve', 'changes', or 'invalid'. Fails closed: an approve with a
    blocking finding or an unmet criterion is 'changes'; an unknown verdict or malformed findings is 'invalid'."""
    if not isinstance(v, dict) or v.get('verdict') not in VERDICTS:
        return 'invalid', ['verdict missing or not in %s: %s' % (VERDICTS, str(v)[:120])]
    findings = v.get('findings', [])
    unmet = v.get('unmet_criteria', [])
    if not isinstance(findings, list) or not isinstance(unmet, list) or any(not isinstance(f, dict) for f in findings):
        return 'invalid', ['findings/unmet_criteria malformed']
    bl = []
    for f in findings:
        sev = f.get('severity')
        if sev not in SEVERITIES:
            return 'invalid', ['finding with unknown severity %r' % sev]
        if sev in BLOCKING:
            bl.append('[%s] %s:%s %s -> %s' % (sev, f.get('file'), f.get('line'), str(f.get('problem', ''))[:300], str(f.get('fix', ''))[:200]))
    bl += ['[unmet] ' + str(u)[:300] for u in unmet]
    if v['verdict'] == 'approve' and not bl:
        return 'approve', []
    if v['verdict'] == 'changes_required' and not bl:
        return 'changes', ['[changes_required] reviewer asked for changes without a blocking finding: ' + str(v.get('summary', ''))[:300]]
    return 'changes', bl


def validate_reasons(j):
    """Pre-mortem output -> (valid reasons, dropped count). A reason needs an id or title, an allowed impact and a
    numeric probability in [0, 1]; anything else is dropped (reported, never merged)."""
    if not isinstance(j, dict) or j.get('verdict') != 'premortem' or not isinstance(j.get('reasons'), list):
        return None, 0
    good, dropped = [], 0
    for r in j['reasons']:
        try:
            if not isinstance(r, dict):
                raise ValueError
            p = float(r.get('probability'))
            text_ok = all(isinstance(r.get(f), str) and r.get(f).strip() for f in ('why', 'guardrail'))
            if not (r.get('id') or r.get('title')) or r.get('impact') not in IMPACTS or not (0.0 <= p <= 1.0) or not text_ok:
                raise ValueError
        except (TypeError, ValueError, AttributeError):
            dropped += 1
            continue
        r = dict(r); r['probability'] = p
        r['id'] = str(r.get('id') or re.sub(r'[^a-z0-9]+', '-', str(r['title']).lower())[:40])
        r['title'] = str(r.get('title') or r['id'])
        for f in ('why', 'early_signal', 'guardrail', 'kpi_link', 'source'):
            v = r.get(f)
            r[f] = v if isinstance(v, str) else ('' if v is None else str(v))
        good.append(r)
    return good, dropped


# ---------- tier policy (owner's rule, 2026-11-09; README "Tiers") ----------
# Every roster entry has a `level` (0-4) and a `vendor`. Pools are not hand-ordered lists any more: each role allows
# some levels (models.json `roles`, bounded by ROLES_ALLOWED) and `pool()` builds the candidates from the roster.
#   Tier 0 frontier ceiling: never selected automatically (owner opt-in per run: run-model --allow-tier0 --model KEY).
#   Tier 1 flagship: plan reviews, pre-mortems, milestone adversarial reviews, coordination. Never implements; reviews
#          a ticket's code only as the logged backup when no Tier 2 reviewer is eligible and healthy (REVIEW_FALLBACK).
#   Tier 2 balanced: ticket code reviews (two reviewers of distinct vendors); `escalate` implements rounds past
#          `escalate_after_round` (run-model run_role, default 3).
#   Tier 3 fast and cheap: ticket implementation and fix rounds up to `escalate_after_round`.
#   Tier 4 small: every Mistral model, every free model, old Gemini, whatever the tier table says. Trivial tasks only,
#          never a reviewer.
# Vendor -> CLI is fixed: a model is only ever reached through its vendor's own CLI (VENDOR_CLIS); any other vendor
# goes through opencode (OpenCode Go or OpenRouter). An entry that breaks it is refused, not repaired.

VENDOR_CLIS = {'anthropic': ('claude',), 'openai': ('codex',), 'google': ('agy',), 'mistral': ('vibe',), 'xai': ('grok', 'cursor')}
OTHER_VENDOR_CLIS = ('opencode',)
LEVELS = (0, 1, 2, 3, 4)
ROLES_DEFAULT = {'implement': [2], 'fix': [2], 'review': [2], 'plan_review': [1], 'premortem': [1], 'milestone_review': [1],
                 'coordinate': [1], 'trivial': [4]}
ROLES_ALLOWED = {'implement': {2, 3}, 'fix': {2, 3}, 'review': {2}, 'plan_review': {1}, 'premortem': {1}, 'milestone_review': {1},
                 'coordinate': {1}, 'trivial': {3, 4}}
PLAN_ROLES = ('plan_review', 'premortem', 'milestone_review')  # review the planner's work: the planner's vendor is excluded
REVIEW_ROLES = ('review',) + PLAN_ROLES                          # roles a `run-model run review` may take
CHEAP_ROLES = ('implement', 'fix', 'trivial')                    # the coordinator's own account may take these, last
# Owner's rule (2026-11-09, ICA-136): after escalation every Tier 2 model may have implemented a ticket. When no Tier 2
# reviewer is eligible and healthy (or every one failed), bin/review draws the ticket reviewer from this role's tier
# (Tier 1) instead of waiting: credit-weighted, never the coordinator's own account, never an implementer's model,
# never an excluded or reserved account; logged in state.json `review_fallbacks` and on stderr. Plan roles have none.
REVIEW_FALLBACK = {'review': 'plan_review'}
# Legacy pool names (before 2026-11-09) and the role they now mean. `escalate` = one level above implement, never Tier 1.
POOL_ROLE = {'implement': 'implement', 'implement_critical': 'implement', 'fix': 'fix', 'fix_mid': 'fix',
             'implement_escalation': 'escalate', 'escalate': 'escalate', 'review': 'review', 'review_mid': 'review',
             'review_high': 'review', 'plan_review': 'plan_review', 'premortem': 'premortem',
             'milestone_review': 'milestone_review', 'coordinate': 'coordinate', 'trivial': 'trivial'}
# subscription (gathered by /autopilot-init, never a default): paid (a plan the owner pays for), paid? (paid, plan not
# confirmed), free (free plan, low limits), reserved (the owner keeps it for other uses: never selected). `excluded:
# "<reason>"` on an entry, or a project's state.json `exclude` ({"<key>|<cli>/<account>|<cli>": "<reason>"}), removes
# entries too. The coordinator's own account is not a subscription: it is detected at run time (`coordinator_account`).
SUBSCRIPTIONS = ('paid', 'paid?', 'free', 'reserved')
SUB_RANK = {'paid': 0, 'paid?': 1, 'free': 2}
FREE_ID = re.compile(r'(?:[-:/]free)(?:#.*)?$|^openrouter/openrouter/free', re.I)
# The owner's tier table (Nov 2026), first match wins, matched on the model id. models.json `tier_table` entries come
# first. It assigns a level to a new entry and re-levels an upgraded id; Tier 4 overrides (Mistral, free) are in code.
# Speed variants have no row: they are refused (FAST_ID).
DEFAULT_TIER_TABLE = [
    {'match': r'mythos|fable', 'level': 0}, {'match': r'gpt-[\d.]+-astra', 'level': 0}, {'match': r'gemini-[\d.]+-carbon', 'level': 0},
    {'match': r'claude-opus', 'level': 1}, {'match': r'gpt-[\d.]+-sol', 'level': 1}, {'match': r'gemini-[\d.]+-argon', 'level': 1},
    {'match': r'muse-spark', 'level': 1}, {'match': r'kimi-k\d', 'level': 1},
    {'match': r'qwen[\d.]+-max', 'level': 1}, {'match': r'deepseek-v[\d.]+-pro', 'level': 1},
    {'match': r'claude-sonnet', 'level': 2}, {'match': r'gpt-[\d.]+-terra', 'level': 2}, {'match': r'gemini-3\.8-flash(?!-lite)', 'level': 2},
    {'match': r'grok-4\.7', 'level': 2}, {'match': r'grok-4\.3', 'level': 2}, {'match': r'qwen[\d.]+-plus', 'level': 2},
    {'match': r'claude-haiku', 'level': 3}, {'match': r'gpt-[\d.]+-luna', 'level': 3}, {'match': r'gemini-[\d.]+-flash-lite', 'level': 3},
    {'match': r'deepseek-v[\d.]+-flash', 'level': 3}, {'match': r'glm-[\d.]+-flash', 'level': 3}, {'match': r'qwen[\d.]+-flash', 'level': 3},
    {'match': r'glm-[\d.]+', 'level': 1},
    {'match': r'gemini-(?:[0-2]\.|3\.[0-4](?!\d))', 'level': 4, 'why': 'old Gemini'},
]


# Owner's rule (2026-11-09): never a speed variant of a model family ('-fast', 'build-fast', 'Fast', e.g.
# grok-4.7-build-fast), whatever its tier: it costs more for the same answers. Such an entry is refused (entry_problems:
# no pool, no --model), `harness add-model`/`init` and `run-model discover` do not add one, unless the owner passes
# --allow-fast (stored as `allow_fast: true` on the entry). "Flash" / "Flash-Lite" (Gemini, DeepSeek, GLM) are model
# families, not speed variants: allowed.
FAST_ID = re.compile(r'(?<![a-z0-9])fast(?![a-z0-9])', re.I)
FAST_WHY = 'speed variant (-fast): more expensive, no quality gain (owner rule); only with the owner\'s explicit --allow-fast'


def is_fast_model(model_id):
    return bool(FAST_ID.search(str(model_id)))


def is_free_model(m):
    return m.get('cost') == 'free' or bool(FREE_ID.search(str(m.get('model', ''))))


def hinted_vendor(model_id):
    """The vendor the model id names (provider prefixes included: `openrouter/anthropic/...`), or None."""
    mid = str(model_id).lower()
    for hint, v in VENDOR_HINTS:
        if re.search(hint, mid):
            return v
    return None


def tier_table(r):
    return list((r or {}).get('tier_table') or []) + DEFAULT_TIER_TABLE


def table_level(r, model_id):
    """(level, entry) from the tier table for a model id, or (None, None)."""
    for e in tier_table(r):
        if re.search(e['match'], str(model_id), re.I):
            return int(e['level']), e
    return None, None


def forced_four(m, a=None):
    """Why the owner's rule puts this entry at Tier 4 whatever its level says, or None."""
    if vendor_of(m, a) == 'mistral':
        return 'Mistral model'
    if is_free_model(m):
        return 'free model'
    return None


def level_of(r, m, a=None):
    """The level the policy uses: Tier 4 when forced, else the entry's `level`, else the tier table. None = unknown."""
    if forced_four(m, a):
        return 4
    if m.get('level') is not None:
        return int(m['level'])
    return table_level(r, m.get('model', ''))[0]


def entry_problems(r, key, m, ad=None):
    """Why the policy refuses a roster entry ([] = valid): unknown harness, a vendor reached through another vendor's
    CLI, a declared vendor that contradicts the model id, a speed variant without `allow_fast`, no level, an unknown
    subscription."""
    ad = ad if ad is not None else adapters()
    a = ad.get(m.get('cli'))
    if not a:
        return ["unknown harness '%s'" % m.get('cli')]
    out = []
    v = vendor_of(m, a)
    hv = hinted_vendor(m.get('model', ''))
    if hv in VENDOR_CLIS and v != hv:
        out.append('model id %s names vendor %s but the entry says %s' % (m.get('model'), hv, v))
    for vv in {v, hv} - {None}:
        clis = VENDOR_CLIS.get(vv, OTHER_VENDOR_CLIS)
        if m['cli'] not in clis:
            out.append('%s models run only through %s, not %s' % (vv, ' or '.join(clis), m['cli']))
    if is_fast_model(m.get('model', '')) and not m.get('allow_fast'):
        out.append('%s is a %s' % (m.get('model'), FAST_WHY))
    lv = level_of(r, m, a)
    if lv is None:
        out.append('no level (set `level` 0-4, or add the family to the tier table)')
    elif lv not in LEVELS:
        out.append('level %r not in 0-4' % lv)
    if m.get('subscription') is not None and m['subscription'] not in SUBSCRIPTIONS:
        out.append('subscription %r not in %s' % (m['subscription'], ', '.join(SUBSCRIPTIONS)))
    return out


def refused(r, ad=None):
    """{key: reason} of the entries the policy refuses."""
    ad = ad if ad is not None else adapters()
    out = {}
    for k, m in r.get('models', {}).items():
        p = entry_problems(r, k, m, ad)
        if p:
            out[k] = '; '.join(p)
    return out


def roles(r):
    """role -> allowed levels, from models.json `roles` (defaults filled in). A role that allows a level the policy
    forbids for it (ROLES_ALLOWED) stops the program: tiers are never reshuffled by configuration."""
    out = {k: list(v) for k, v in ROLES_DEFAULT.items()}
    for role, lv in ((r or {}).get('roles') or {}).items():
        if role not in ROLES_ALLOWED:
            sys.exit('models.json roles: unknown role %r (known: %s)' % (role, ', '.join(ROLES_ALLOWED)))
        bad = sorted(set(lv) - ROLES_ALLOWED[role])
        if bad or not lv:
            sys.exit('models.json roles.%s = %s breaks the tier policy (allowed: %s). Tier 0 is never automatic, Tier 1 only '
                     'plans/pre-mortems/milestone reviews/coordinates, ticket reviews are Tier 2, implementation and fixes '
                     'Tier 2 (owner, 2026-11-11) or Tier 3, Tier 4 only trivial tasks.' % (role, lv, sorted(ROLES_ALLOWED[role])))
        out[role] = list(lv)
    impl = min(out['implement'])
    out['escalate'] = [max(2, impl - 1)]  # one level up, never Tier 1
    return out


def role_of(pool_name):
    role = POOL_ROLE.get(pool_name)
    if not role:
        sys.exit('unknown pool or role %r (known: %s)' % (pool_name, ', '.join(sorted(POOL_ROLE))))
    return role


def account_key(m, a):
    """`<cli>/<account>`: the unit a quota belongs to."""
    return '%s/%s' % (m['cli'], account_of(m, a))


def detect_coordinator(ad=None):
    """(cli, account) of the coordinator session this process runs under, or None. $AUTOPILOT_COORDINATOR
    (`<cli>` or `<cli>/<account>`) wins; else the first adapter whose `coordinator_env` variable is set in this
    process (Claude Code sets CLAUDECODE, ...), with the account its `account_env` gives in this process (unset = the
    CLI's default home). Every bin/ script runs as a child of the coordinator, so it inherits that environment."""
    ad = ad if ad is not None else adapters()
    forced = os.environ.get('AUTOPILOT_COORDINATOR', '').strip()
    if forced:
        cli, _, acct = forced.partition('/')
        a = ad.get(cli)
        if acct or not a:
            return cli, acct or 'default'
        return cli, session_account(a)
    for name, a in sorted(ad.items()):
        if any(os.environ.get(v) for v in a.get('coordinator_env', [])):
            return name, session_account(a)
    return None


def session_account(a):
    """The account label of this process for an adapter: its `account_env` as set here (unset = default)."""
    k = a.get('account_env')
    v = os.environ.get(k) if k else None
    return account_of({'cli': a['name'], 'model': '', 'env': {k: v}} if v else {'cli': a['name'], 'model': ''}, a)


_COORD = {}


def coordinator_account(r=None, repo=None, ad=None):
    """(cli, account) to protect: detected from this process (see detect_coordinator), else the one recorded in the
    project's state.json `coordinator_account` at setup (`run-model whoami --record`), else None. Never configured in
    models.json: starting the coordinator from another account protects that one and frees the previous one."""
    if 'v' not in _COORD:
        v = detect_coordinator(ad)
        if not v:
            repo = repo or find_repo(required=False)
            ca = (load_state(repo) if repo else {}).get('coordinator_account') or {}
            v = (ca['cli'], ca.get('account') or 'default') if ca.get('cli') else None
        _COORD['v'] = v
    return _COORD['v']


def on_coordinator_account(r, m, a=None, ca=None):
    """True for an entry on the coordinator's own account: same CLI and same account as `coordinator_account`. Keyed on
    the exact account, never on the vendor: another login of the same CLI is a normal account."""
    ca = ca or coordinator_account(r)
    if not ca or m.get('cli') != ca[0]:
        return False
    a = a or adapters().get(m['cli'])
    return bool(a) and account_of(m, a) == ca[1]


def project_excludes(repo=None):
    """state.json `exclude` of the current project: {"<key>" | "<cli>/<account>" | "<cli>": "<reason>"}."""
    repo = repo or find_repo(required=False)
    return (load_state(repo) if repo else {}).get('exclude') or {}


def excluded_reason(r, k, m, a, pex=None):
    """Why an entry is never selected (owner's choice), or None."""
    if m.get('excluded'):
        return str(m['excluded'])
    if m.get('subscription') == 'reserved':
        return 'reserved by the owner'
    pex = project_excludes() if pex is None else pex
    for x in (k, account_key(m, a) if a else None, m.get('cli')):
        if x and x in pex:
            return 'project exclude %s: %s' % (x, pex[x])
    return None


def selectable(m):
    return not m.get('excluded') and m.get('subscription') != 'reserved'


_WHICH = {}


def installed(a):
    """The adapter's binary resolves to a real executable on PATH (a shell alias or function wrapping a removed
    binary does not count: run-model runs the binary, never the user's shell)."""
    b = a.get('binary', a.get('name'))
    if b not in _WHICH:
        exe = shutil.which(b)
        _WHICH[b] = bool(exe and os.path.isfile(os.path.realpath(exe)) and os.access(os.path.realpath(exe), os.X_OK))
    return _WHICH[b]


SUB_WEIGHT = {'paid': 1.0, 'paid?': 0.7, 'free': 0.25}


def credit_left(r, acct):
    """Fraction of credit left on an account (0..1) from the latest `run-model usage` reading (models.json `usage_seen`,
    the most used window wins), or None when unknown or older than 6 h."""
    u = ((r or {}).get('usage_seen') or {}).get(acct) or {}
    if u.get('used') is None or not u.get('at') or (now() - parse_time(u['at'])).total_seconds() > 6 * 3600:
        return None
    return max(0.0, min(1.0, (100 - float(u['used'])) / 100))


def weight(r, m, acct):
    """Draw weight of a candidate: its subscription (paid > paid? > free) times the remaining total usage of its
    subscription: the fraction of credit left on its account (unknown = neutral 0.5, near exhaustion = almost never)
    times the plan's relative size (models.json `capacity`, default 1; e.g. 12 for a plan with 12x the usage of the
    smallest one). A big plan at half credit is drawn more often than a small plan at half credit, so every paid
    subscription is spent in proportion to what it has left before its reset (owner, 2026-11-11)."""
    left = credit_left(r, acct)
    w = 0.5 if left is None else (0.02 if left < 0.1 else left)
    return SUB_WEIGHT.get(m.get('subscription'), 0.7) * w * max(0.0, float(m.get('capacity') or 1))


def rng(r=None):
    """Random source of the draws: seeded by $AUTOPILOT_SEED or models.json `seed` for reproducible runs and tests."""
    import random
    seed = os.environ.get('AUTOPILOT_SEED') or (r or {}).get('seed')
    return random.Random(seed) if seed not in (None, '') else random.Random()


def candidates(r, name, ad=None):
    """Every key that may take a role (or a legacy pool name): a valid, selectable entry (not `excluded`, not
    `reserved`, not in the project's `exclude`) whose policy level is allowed for the role (Tier 0 never) and whose CLI is installed. Unordered."""
    ad = ad if ad is not None else adapters()
    role = role_of(name)
    allowed = set(roles(r)[role])
    bad = refused(r, ad)
    pex = project_excludes()
    out = []
    for k, m in r.get('models', {}).items():
        a = ad.get(m.get('cli'))
        if k in bad or not a or excluded_reason(r, k, m, a, pex) or level_of(r, m, a) not in allowed or not installed(a):
            continue
        out.append(k)
    return out


def pool(r, name, ad=None, rand=None):
    """Candidates of a role in draw order: no hand-made preference. Healthy candidates off the coordinator's account
    are drawn at random weighted by `weight` (sampling without replacement: the order is the fallback chain), then the
    cooling ones (earliest reset first), then the coordinator's own account last: only for cheap roles (implement,
    fix, trivial), and for Tier 1/2 roles only when the role has no other candidate at all. run-model also checks the
    coordinator's remaining quota before using it."""
    ad = ad if ad is not None else adapters()
    role = role_of(name)
    rand = rand or rng(r)
    t = now()
    live, cooling, coord = [], [], []
    for k in candidates(r, name, ad):
        m = r['models'][k]; a = ad[m['cli']]
        if on_coordinator_account(r, m, a):
            coord.append(k); continue
        h = r.get('health', {}).get(k)
        if h and parse_time(h['until']) > t:
            cooling.append((h['until'], k))
        else:
            live.append((weight(r, m, account_key(m, a)), k))
    order = []
    while live:
        tot = sum(w for w, _ in live)
        x = rand.random() * tot
        for i, (w, k) in enumerate(live):
            x -= w
            if x <= 0 or i == len(live) - 1:
                order.append(k); live.pop(i); break
    order += [k for _, k in sorted(cooling)]
    if coord and (role in CHEAP_ROLES or not order):
        order += coord
    return order


def pools(r, ad=None):
    ad = ad if ad is not None else adapters()
    return {role: pool(r, role, ad) for role in list(ROLES_DEFAULT) + ['escalate']}


def pick_reviewers(reg, pool_names, k, excluded, ad=None):
    """k healthy keys of k distinct vendors from the roles' candidates: the first drawn at random (weighted, see
    `pool`), each next one drawn among the remaining candidates of another vendor. Never relaxes the vendor rule nor
    the tier: returns fewer than k when the vendors are not there (the caller waits or alerts)."""
    ad = ad or adapters()
    rand = rng(reg)
    pick, vendors = [], []
    for x in dict.fromkeys(x for p in pool_names for x in pool(reg, p, ad, rand)):
        m = reg['models'].get(x)
        if not m or not healthy(reg, x) or x in excluded:
            continue
        v = vendor_of(m, ad.get(m['cli']))
        if v in vendors:
            continue
        vendors.append(v); pick.append(x)
        if len(pick) == k:
            break
    return pick, vendors


def vendor_ready_at(reg, pool_names, k, excluded, ad=None):
    """When k distinct vendors of the roles' candidates (minus `excluded`) will be healthy: now when they are, the
    k-th earliest per-vendor cooldown end otherwise, None when fewer than k vendors exist at all (configuration)."""
    ad = ad or adapters()
    t = now(); best = {}
    for x in dict.fromkeys(x for p in pool_names for x in candidates(reg, p, ad)):
        if x in excluded:
            continue
        m = reg['models'][x]
        if role_of(pool_names[0]) not in CHEAP_ROLES and on_coordinator_account(reg, m, ad.get(m['cli'])):
            continue
        h = reg.get('health', {}).get(x)
        until = parse_time(h['until']) if h and parse_time(h['until']) > t else t
        v = vendor_of(m, ad.get(m['cli']))
        best[v] = min(best.get(v, until), until)
    ends = sorted(best.values())
    return ends[k - 1] if len(ends) >= k else None


def raise_alert(repo, kind, key, title, message, details=None):
    """Raise (or refresh) one CRITICAL alert outside run-model's own recomputed set (e.g. a review that cannot find two
    Tier-2 vendors, the coordinator's quota reserve). It stays until resolved by `resolve_alert` and acknowledged.
    Prints the `CRITICAL:` line; a new alert also posts a Linear project update when the project is known."""
    t = now()

    def fn(al):
        cur = next((a for a in al if a['kind'] == kind and a['key'] == key and not a.get('resolved_at')), None)
        if cur:
            cur.update(message=message, details=details or {}, updated_at=t.isoformat()); return cur, False
        al.append({'id': '%s-%s' % (t.strftime('%Y%m%d-%H%M'), re.sub(r'[^\w.-]+', '-', key)), 'level': 'CRITICAL', 'kind': kind,
                   'key': key, 'at': t.isoformat(), 'title': title, 'message': message, 'details': details or {}})
        return al[-1], True
    a, new = update_alerts(repo, fn)
    print('CRITICAL: %s (alert %s; bin/alert list)' % (message, a['id']), file=sys.stderr)
    pid = (load_state(repo) if repo else {}).get('project_id') or ''
    if new and pid and not pid.startswith('<'):
        p = subprocess.run([os.path.join(HERE, 'linear'), 'project-update', pid, '%s\n\n%s\n\nRaised at %s.' % (title, message, a['at'][:16])],
                           capture_output=True, text=True, stdin=subprocess.DEVNULL)
        update_alerts(repo, lambda al: [x.__setitem__('linear', 'posted' if p.returncode == 0 else (p.stderr or p.stdout)[-200:]) for x in al if x['id'] == a['id']])
    return a


def resolve_alert(repo, kind, key):
    if not os.path.exists(alerts_path(repo)):
        return
    t = now().isoformat()
    update_alerts(repo, lambda al: [a.__setitem__('resolved_at', t) for a in al if a['kind'] == kind and a['key'] == key and not a.get('resolved_at')])


# --- ticket shape (plan time) ------------------------------------------------------------------
# Owner, 2026-11-12: "the goal of the autopilot-plan phase is also to split the work in smaller taks
# (more atomic) and avoid very large tickets like this that could createc complex merge conflicts or
# long convergence. this is where it must be fixed." A ticket of size L took 18 rounds (22 files,
# +2051/-638 lines) while parallel tickets edited the same files. The plan is where it is prevented.

TICKET_SIZES = {'XS': 0.5, 'S': 1.0, 'M': 2.0, 'L': 3.0, 'XL': 5.0}
MAX_TICKET_UNITS = 2.0       # M: one concern, about 400 changed lines at most
MAX_TICKET_TOUCHES = 8       # files or modules one ticket may change
SHARED_OK = ('tests/', 'test/', 'docs/', 'e2e/artifacts/')  # adding tests or notes side by side is fine


def ticket_units(v):
    if isinstance(v, str) and v.strip().upper() in TICKET_SIZES:
        return TICKET_SIZES[v.strip().upper()]
    return float(v)


def _overlap(a, b):
    """Two touched paths collide when equal or when one is a directory prefix of the other."""
    a, b = a.strip().rstrip('/'), b.strip().rstrip('/')
    return a == b or a.startswith(b + '/') or b.startswith(a + '/')


def ticket_shape_errors(tickets, deps=None):
    """Errors that make a ticket list unfit to run: too big, no declared footprint, or two tickets
    that may run in parallel while changing the same file.

    `deps` maps slug -> slugs it waits on (inside this list); tickets ordered by it never run in
    parallel, so their shared files are allowed. Paths under tests/, docs/ are never a collision.
    """
    errs = []
    by = {t.get('slug'): t for t in tickets}
    deps = deps if deps is not None else {s: [b for b in (t.get('blocked_by') or []) if b in by] for s, t in by.items()}
    for s, t in by.items():
        try:
            u = ticket_units(t.get('estimate', 1))
        except (TypeError, ValueError):
            continue  # the caller reports a bad estimate
        if u > MAX_TICKET_UNITS:
            errs.append(f'{s}: size {t.get("estimate")} is larger than M: split it into tickets of one concern '
                        f'(about 400 changed lines each), chained with blocked_by where they share files')
        touches = t.get('touches')
        if not isinstance(touches, list) or not [p for p in touches if str(p).strip()]:
            errs.append(f'{s}: `touches` is required: the files or modules this ticket changes (e.g. '
                        f'["purple/api/app.py", "web/src/components/drawer/"])')
        elif len(touches) > MAX_TICKET_TOUCHES:
            errs.append(f'{s}: touches {len(touches)} files or modules (max {MAX_TICKET_TOUCHES}): split it')

    def ancestors(s, seen=None):
        seen = set() if seen is None else seen
        for b in deps.get(s, []):
            if b not in seen:
                seen.add(b); ancestors(b, seen)
        return seen

    anc = {s: ancestors(s) for s in by}
    slugs = list(by)
    for i, a in enumerate(slugs):
        for b in slugs[i + 1:]:
            if a in anc[b] or b in anc[a]:
                continue
            ta = [p for p in by[a].get('touches') or [] if not str(p).startswith(SHARED_OK)]
            tb = [p for p in by[b].get('touches') or [] if not str(p).startswith(SHARED_OK)]
            hit = sorted({x for x in ta for y in tb if _overlap(str(x), str(y))})
            if hit:
                errs.append(f'{a} and {b} can run in parallel but both change {", ".join(hit)}: order them with '
                            f'blocked_by, or split so each file has one owner per stage')
    return errs
