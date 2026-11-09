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
          {'id': 'st-done', 'name': 'Done', 'type': 'completed', 'position': 2},
          {'id': 'st-canceled', 'name': 'Canceled', 'type': 'canceled', 'position': 3},
          {'id': 'st-duplicate', 'name': 'Duplicate', 'type': 'canceled', 'position': 4}]


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
            'state': {'name': st['name'], 'type': st['type']} if st else {'name': 'Todo', 'type': i.get('state', 'unstarted')},
            'team': {'id': 'team-1', 'key': s['team']}, 'project': {'id': i.get('projectId'), 'name': 'P'},
            'projectMilestone': {'id': ms['id'], 'name': ms['name']} if ms else None,
            'labels': {'nodes': [{'id': l['id'], 'name': l['name']} for l in labels]},
            'description': i.get('description', ''), 'inverseRelations': {'nodes': rels}, 'relations': {'nodes': out_rels}}


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
        ms = [{'id': m['id'], 'name': m['name'], 'targetDate': m['targetDate']} for m in s['milestones'] if m['projectId'] == v['id']]
        return {'data': {'project': {'projectMilestones': {'nodes': ms, 'pageInfo': page}}}}
    if 'projectMilestone(' in q:
        m = next((m for m in s['milestones'] if m['id'] == v['id']), None)
        return {'data': {'projectMilestone': {'id': m['id']}}} if m else {'errors': [{'message': 'not found'}]}
    if 'issueRelation(' in q:
        r = next((r for r in s['relations'] if r.get('id') == v['id']), None)
        return {'data': {'issueRelation': {'id': r['id']}}} if r else {'errors': [{'message': 'not found'}]}
    if 'project(' in q:
        return {'data': {'project': {'id': v['id'], 'url': 'https://linear.test/project/' + v['id']}}} if v['id'] == s['project_id'] \
            else {'errors': [{'message': 'not found'}]}
    if 'issue(' in q:
        i = find_issue(s, v['id'])
        return {'data': {'issue': view_issue(s, i)}} if i else {'errors': [{'message': 'not found'}]}
    return {'errors': [{'message': 'fake: unsupported query'}]}


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with LOCK:
            out = answer(body['query'], body.get('variables') or {})
        data = json.dumps(out).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data)))
        self.end_headers(); self.wfile.write(data)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(('127.0.0.1', 0), H)
open(PORT_FILE, 'w').write(str(srv.server_address[1]))
srv.serve_forever()
