"""Shared rules of the linear-autopilot runtime. Every bin/ script imports this so that identity, exclusions,
config transactions, tree snapshots and verdict validation are enforced in exactly one place.

Config: $AUTOPILOT_CONFIG_DIR (default ~/.config/linear-autopilot): models.json (roster, accounts, pools, health),
harnesses/ (adapter overrides), prompts/ (template overrides). Per project: <repo>/.autopilot/state.json.
Python 3.9+ (no match statements, no nested same-quote f-strings).
"""
import contextlib, datetime as dt, fcntl, glob, hashlib, json, os, re, subprocess, sys, tarfile, tempfile

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


def load_reg():
    if not os.path.exists(REG):
        sys.exit('no roster at %s. Run the autopilot-init skill (bin/harness init).' % REG)
    return read_json(REG)


def update_reg(fn):
    """Locked read-modify-write of the roster. fn(r) mutates r and may return a value."""
    with locked(REG):
        r = load_reg()
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
    """The one environment a roster entry runs with, and that identity and path expansion use:
    the process environment, then the adapter's env, then the account override (e.g. CODEX_HOME)."""
    env = dict(os.environ)
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


def pick_reviewers(reg, pools, k, excluded, ad=None, cost_floor=None):
    """k healthy keys from the pools in order, with k distinct vendors. Never relaxes the vendor rule:
    returns fewer than k when the vendors are not there. cost_floor: set of allowed `cost` values."""
    ad = ad or adapters()
    pick, vendors = [], []
    for x in dict.fromkeys(x for p in pools for x in reg['pools'].get(p, [])):
        m = reg['models'].get(x)
        if not m or not healthy(reg, x) or x in excluded:
            continue
        if cost_floor and m.get('cost', 'mid') not in cost_floor:
            continue
        v = vendor_of(m, ad.get(m['cli']))
        if v in vendors:
            continue
        vendors.append(v); pick.append(x)
        if len(pick) == k:
            break
    return pick, vendors
