#!/usr/bin/env python3
"""Offline stand-in for the Linear GraphQL API, for tests/selftest.sh (bin/linear honours LINEAR_API_URL).

  fake_linear.py <store.json> <port-file>

Serves 127.0.0.1 on a free port (written to <port-file>). The store holds teams, projects, milestones, issues,
relations, project updates, and optionally labels ([{"id", "name", "team": {"id"} | null}]), workflow states (a default
Backlog/Todo/Done/Canceled/Duplicate set) and "fail": {"<mutation>": n} (the next n calls of that mutation answer
"Entity not found", Linear's eventual consistency); every mutation is appended to <store>.log as one JSON line {"op": ..., "input": ...},
so a test counts the calls. It answers only the operations bin/linear sends, matched by name in the query text.
"""
import json, re, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STORE, PORT_FILE = sys.argv[1], sys.argv[2]
LOCK = threading.Lock()


def load():
    return json.load(open(STORE))


def save(s):
    json.dump(s, open(STORE, 'w'), indent=1)


def log(op, inp):
    with open(STORE + '.log', 'a') as f:
        f.write(json.dumps({'op': op, 'input': inp}) + '\n')


def find_issue(s, ref):
    return next((i for i in s['issues'] if ref in (i['id'], i['identifier'])), None)


STATES = [{'id': 'st-backlog', 'name': 'Backlog', 'type': 'backlog', 'position': 0},
          {'id': 'st-todo', 'name': 'Todo', 'type': 'unstarted', 'position': 1},
          {'id': 'st-progress', 'name': 'In Progress', 'type': 'started', 'position': 2},
          {'id': 'st-done', 'name': 'Done', 'type': 'completed', 'position': 3},
          {'id': 'st-canceled', 'name': 'Canceled', 'type': 'canceled', 'position': 4},
          {'id': 'st-duplicate', 'name': 'Duplicate', 'type': 'canceled', 'position': 5}]


def view_issue(s, i):
    rels = [{'type': r['type'], 'issue': {'identifier': find_issue(s, r['issueId'])['identifier']}}
            for r in s['relations'] if r['relatedIssueId'] == i['id']]
    out_rels = [{'type': r['type'], 'relatedIssue': {'identifier': find_issue(s, r['relatedIssueId'])['identifier']}}
                for r in s['relations'] if r['issueId'] == i['id']]
    st = next((x for x in s.get('states', STATES) if x['id'] == i.get('stateId')), None)
    ms = next((m for m in s['milestones'] if m['id'] == i.get('projectMilestoneId')), None)
    labels = [l for l in s.get('labels', []) if l['id'] in (i.get('labelIds') or [])]
    return {'id': i['id'], 'identifier': i['identifier'], 'url': 'https://linear.test/' + i['identifier'], 'title': i['title'],
            'estimate': i.get('estimate'),
            'state': {'id': st['id'], 'name': st['name'], 'type': st['type']} if st else {'id': None, 'name': 'Todo', 'type': i.get('state', 'unstarted')},
            'team': {'id': 'team-1', 'key': s['team']}, 'project': {'id': i.get('projectId'), 'name': 'P'},
            'projectMilestone': {'id': ms['id'], 'name': ms['name']} if ms else None,
            'labels': {'nodes': [{'id': l['id'], 'name': l['name']} for l in labels]},
            'description': i.get('description', ''), 'inverseRelations': {'nodes': rels}, 'relations': {'nodes': out_rels}}


def project_known(s, pid):
    if not pid:
        return False
    if pid == s.get('project_id'):
        return True
    if any(p.get('id') == pid for p in s.get('projects') or []):
        return True
    if any(i.get('projectId') == pid for i in s.get('issues') or []):
        return True
    if any(m.get('projectId') == pid for m in s.get('milestones') or []):
        return True
    return False


def connection(items, q, v):
    """Honor first/after. The cursor is the index of the last item returned (Linear returns an opaque cursor;
    the client only threads it back as $after)."""
    firsts = [int(x) for x in re.findall(r'first:\s*(\d+)', q)]
    first = firsts[0] if firsts else (len(items) or 1)
    after = (v or {}).get('after')
    start = int(after) + 1 if after not in (None, '') else 0
    chunk = items[start:start + first]
    has_next = start + len(chunk) < len(items)
    end = start + len(chunk) - 1
    return chunk, {'hasNextPage': has_next, 'endCursor': str(end) if has_next else None}


def wants_archived(q):
    """Linear hides archived issues unless the field asks includeArchived: true."""
    return re.search(r'includeArchived\s*:\s*true', q) is not None


def issues_for(s, q, pred):
    items = [i for i in s['issues'] if pred(i)]
    if not wants_archived(q):
        items = [i for i in items if not i.get('archived')]
    return items


def list_issue(s, i):
    st = next((x for x in s.get('states', STATES) if x['id'] == i.get('stateId')), None)
    ms = next((m for m in s['milestones'] if m['id'] == i.get('projectMilestoneId')), None)
    if st:
        state = {'id': st['id'], 'name': st['name'], 'type': st['type']}
    else:
        state = {'id': None, 'name': 'Todo', 'type': i.get('state', 'unstarted')}
    return {'id': i['id'], 'identifier': i['identifier'], 'title': i['title'], 'state': state,
            'projectMilestone': {'name': ms['name']} if ms else None}


def inverse_rels(s, i):
    out = []
    for r in s['relations']:
        if r.get('relatedIssueId') != i['id']:
            continue
        other = find_issue(s, r.get('issueId'))
        if other:
            out.append({'type': r['type'], 'issue': {'identifier': other['identifier']}})
    return out


def too_complex(q):
    """Linear's cap is 10,000. issues(first:N) nested with inverseRelations(first:M) costs about N*(8+3*M).
    The old issues query (100 x 100) is ~30,000 and the real API answers HTTP 400."""
    if 'issues(' not in q or 'inverseRelations' not in q:
        return False
    firsts = [int(x) for x in re.findall(r'first:\s*(\d+)', q)]
    n = firsts[0] if firsts else 50
    m = firsts[1] if len(firsts) > 1 else 50
    return n * (8 + m * 3) > 10000


def answer(q, v):
    s = load()
    page = {'hasNextPage': False, 'endCursor': None}
    if 'mutation' in q:
        op = re.search(r'\{\s*(\w+)\(', q).group(1); inp = v.get('i', {})
        log(op, dict(inp, **({'id_arg': v['id']} if 'id' in v else {})))
        if s.get('fail', {}).get(op):
            s['fail'][op] -= 1; save(s)
            return {'errors': [{'message': 'Entity not found: Issue', 'extensions': {'code': 'INVALID_INPUT'}}]}
        if op == 'projectMilestoneCreate':
            s['milestones'].append({'id': inp['id'], 'name': inp['name'], 'projectId': inp['projectId'], 'targetDate': None})
            out = {'projectMilestone': {'id': inp['id']}}
        elif op == 'projectMilestoneUpdate':
            m = next(m for m in s['milestones'] if m['id'] == v['id']); m['targetDate'] = inp['targetDate']; out = {'success': True}
        elif op == 'issueCreate':
            n = max([int(i['identifier'].split('-')[1]) for i in s['issues']] or [0]) + 1
            i = dict(inp, identifier='%s-%d' % (s['team'], n)); s['issues'].append(i)
            out = {'issue': {'id': i['id'], 'identifier': i['identifier'], 'url': 'https://linear.test/' + i['identifier']}}
        elif op == 'issueUpdate':
            i = find_issue(s, v['id']); inp = dict(inp)
            added = inp.pop('addedLabelIds', [])
            i.update(inp); i['labelIds'] = list(dict.fromkeys((i.get('labelIds') or []) + added)); out = {'success': True}
        elif op == 'issueRelationCreate':
            inp = dict(inp)
            inp['issueId'] = find_issue(s, inp['issueId'])['id']; inp['relatedIssueId'] = find_issue(s, inp['relatedIssueId'])['id']
            s['relations'].append(inp); out = {'success': True}
        elif op == 'issueLabelCreate':
            l = {'id': 'lbl-%d' % (len(s.get('labels', [])) + 1), 'name': inp['name'], 'team': {'id': inp['teamId']} if inp.get('teamId') else None}
            s.setdefault('labels', []).append(l); out = {'issueLabel': {'id': l['id']}}
        elif op == 'commentCreate':
            s.setdefault('comments', []).append(inp); out = {'success': True}
        elif op == 'projectUpdateCreate':
            u = {'id': 'pu-%d' % (len(s['updates']) + 1), 'body': inp['body']}; s['updates'].append(u)
            out = {'success': True, 'projectUpdate': {'id': u['id'], 'url': 'https://linear.test/update/' + u['id']}}
        elif op == 'projectUpdateUpdate':
            u = next(u for u in s['updates'] if u['id'] == v['id']); u['body'] = inp['body']
            out = {'success': True, 'projectUpdate': {'id': u['id'], 'url': 'https://linear.test/update/' + u['id']}}
        elif op == 'projectUpdate':
            s['content'] = inp.get('content'); out = {'success': True}
        elif op == 'projectMilestoneDelete':
            before = len(s['milestones'])
            s['milestones'] = [m for m in s['milestones'] if m['id'] != v.get('id')]
            if len(s['milestones']) == before:
                return {'errors': [{'message': 'not found'}]}
            out = {'success': True}
        elif op == 'projectArchive':
            s.setdefault('archived', [])
            if v.get('id') not in s['archived']:
                s['archived'].append(v['id'])
            out = {'success': True}
        else:
            return {'errors': [{'message': 'fake: unsupported mutation ' + op}]}
        save(s)
        return {'data': {op: out}}
    if 'teams(' in q:
        return {'data': {'teams': {'nodes': [{'id': 'team-1', 'key': s['team'], 'name': 'Team'}], 'pageInfo': page}}}
    if 'issueLabels' in q:
        return {'data': {'issueLabels': {'nodes': s.get('labels', []), 'pageInfo': page}}}
    if 'states(' in q:
        return {'data': {'team': {'states': {'nodes': s.get('states', STATES), 'pageInfo': page}}}}
    if 'projectMilestones' in q:
        raw = [m for m in s['milestones'] if m['projectId'] == v['id']]
        nodes = []
        for m in raw:
            hit = issues_for(s, q, lambda i, m=m: i.get('projectMilestoneId') == m['id'])
            nodes.append({'id': m['id'], 'name': m['name'], 'targetDate': m.get('targetDate'),
                          'issues': {'nodes': [{'id': hit[0]['id']}] if hit else []}})
        chunk, info = connection(nodes, q, v)
        return {'data': {'project': {'projectMilestones': {'nodes': chunk, 'pageInfo': info}}}}
    if 'projectMilestone(' in q:
        m = next((m for m in s['milestones'] if m['id'] == v['id']), None)
        return {'data': {'projectMilestone': {'id': m['id']}}} if m else {'errors': [{'message': 'not found'}]}
    if 'issueRelation(' in q:
        r = next((r for r in s['relations'] if r.get('id') == v['id']), None)
        return {'data': {'issueRelation': {'id': r['id']}}} if r else {'errors': [{'message': 'not found'}]}
    if 'issues(' in q and 'project(' in q and 'identifier' in q:
        if not project_known(s, v.get('id')):
            return {'errors': [{'message': 'not found'}]}
        items = [list_issue(s, i) for i in issues_for(s, q, lambda i: i.get('projectId') == v['id'])]
        chunk, info = connection(items, q, v)
        return {'data': {'project': {'issues': {'nodes': chunk, 'pageInfo': info}}}}
    if 'archivedAt' in q and 'project(' in q:
        if not project_known(s, v.get('id')):
            return {'errors': [{'message': 'not found'}]}
        items = issues_for(s, q, lambda i: i.get('projectId') == v['id'])
        return {'data': {'project': {'id': v['id'],
                                    'archivedAt': '2020-01-01T00:00:00.000Z' if v['id'] in s.get('archived', []) else None,
                                    'issues': {'nodes': [{'id': items[0]['id']}] if items else []}}}}
    if 'inverseRelations' in q and 'pageInfo' in q:
        i = find_issue(s, v.get('id'))
        if not i:
            return {'errors': [{'message': 'not found'}]}
        chunk, info = connection(inverse_rels(s, i), q, v)
        return {'data': {'issue': {'inverseRelations': {'nodes': chunk, 'pageInfo': info}}}}
    if 'project(' in q:
        return {'data': {'project': {'id': v['id'], 'url': 'https://linear.test/project/' + v['id']}}} if project_known(s, v.get('id')) \
            else {'errors': [{'message': 'not found'}]}
    if 'issue(' in q:
        i = find_issue(s, v['id'])
        return {'data': {'issue': view_issue(s, i)}} if i else {'errors': [{'message': 'not found'}]}
    return {'errors': [{'message': 'fake: unsupported query'}]}


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        q = body.get('query') or ''
        if too_complex(q):
            data = json.dumps({'errors': [{'message': 'Query too complex'}]}).encode()
            self.send_response(400)
            self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data)))
            self.end_headers(); self.wfile.write(data)
            return
        with LOCK:
            out = answer(q, body.get('variables') or {})
        data = json.dumps(out).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data)))
        self.end_headers(); self.wfile.write(data)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(('127.0.0.1', 0), H)
open(PORT_FILE, 'w').write(str(srv.server_address[1]))
srv.serve_forever()
