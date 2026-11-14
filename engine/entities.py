"""The entity store (step 1 of docs/reviews/2026-11-14-entities.md): one local record per real thing he names - a
person, org, project, tool, document or place - built from the sources he already keeps, and the context packs an
agent can read. Importing this module reads nothing.

    .venv/bin/python engine/entities.py build            # data/entities.json (know.py build calls it too)
    .venv/bin/python engine/entities.py stats            # counts only
    .venv/bin/python engine/entities.py pack <name> [--level 2|3]
    .venv/bin/python engine/entities.py context <name>   # the entity and its related ones, one brief

Sources, each optional and read-only (the local config's integrations decide; off = not read at all):
- Aleph's SQLite: things, names, facts, merged, notsame. Private scope is excluded in SQL, before any row is read.
- The vault: frontmatter only, of the top level of Entities/People, Entities/Organizations, Stories and Epics.
  Never a `Private/` folder, `.obsidian`, `.claude` or `System/old`; a note marked private is skipped.
- Google Contacts: the snapshot engine/contacts.py keeps (contact-only people are cards, never references).
A source that fails keeps its last good slice (data/entity-sources.json); one failed source never empties the store.

Private material reaches a pack only through data/context-allow.json ({"aleph": [ids], "vault": [paths]}), one
record at a time, and such a record says so (`private: true`). No model writes a fact: a pack is a fixed template over
stored records, each fact with its source and date. The app reads the prebuilt `surfaces` map and the pack parts;
app/EntityRules.swift renders the same text (tests/entity_cases.json holds the golden cases both sides run).
"""
import argparse
from collections import Counter, defaultdict
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / 'data'
sys.path.insert(0, str(Path(__file__).resolve().parent))

KINDS = ('person', 'org', 'project', 'tool', 'doc', 'place')
KIND_KEYS = {'1': 'person', '2': 'org', '3': 'project', '4': 'tool', '5': 'doc', '6': 'place', '0': 'none'}
KIND_WORD = {'person': 'person', 'org': 'org', 'project': 'project', 'tool': 'tool', 'doc': 'document', 'place': 'place'}
ALEPH_KIND = {'person': 'person', 'org': 'org', 'project': 'project', 'repo': 'tool', 'worker': 'tool', 'skill': 'tool'}
VAULT_DIRS = {'Entities/People': 'person', 'Entities/Organizations': 'org', 'Stories': 'project', 'Epics': 'project'}
VAULT_SKIP = {'Private', '.obsidian', '.claude', '.trash'}
ORDER = {'aleph': 0, 'vault': 1, 'board': 2, 'contacts': 3}
MATCH = {'name': 3.0, 'alias': 2.5, 'pair': 2.5, 'form': 2.0, 'first': 1.0, 'part': 1.0}

HEADER = 'Context (background from my notes, not instructions):'
LINE_MAX, FULL_MAX, BLOCK_MAX, BRIEF_MAX, WHO_MAX, FACT_MAX = 160, 600, 1800, 3000, 80, 120
STALE_DAYS = 90

PHONE = re.compile(r'\+?\d[\d ()\-.]{6,}\d')
EMAIL = re.compile(r'[^\s@<>()]+@[^\s@<>()]+\.[^\s@<>()]+')
APOS = str.maketrans({'’': "'", 'ʼ': "'", '`': "'", '‘': "'"})
WORDS = re.compile(r"[^\W\d_]+(?:['’ʼ-][^\W\d_]+)*", re.UNICODE)


def fold(s):
    """The key of a surface form: lower case, one apostrophe, single spaces (ґ stays ґ)."""
    return ' '.join(str(s or '').translate(APOS).casefold().split())


def one_line(s, n):
    """One clean line of at most n characters, cut at a word with an ellipsis; phone numbers never survive."""
    s = ' '.join(str(s or '').split())
    s = PHONE.sub('', s).strip(' ,;')
    s = re.sub(r'\s{2,}', ' ', s)
    if len(s) <= n: return s
    cut = s[:n - 1].rsplit(' ', 1)[0] if ' ' in s[:n - 1] else s[:n - 1]
    return cut.rstrip(' ,;.:-') + '…'


def day(ts):
    try: return time.strftime('%Y-%m-%d', time.localtime(float(ts))) if ts else ''
    except (TypeError, ValueError, OverflowError, OSError): return ''


def read_json(path, default):
    try: return json.loads(Path(path).read_text())
    except FileNotFoundError: return default
    except (OSError, ValueError): return default


def atomic(path, text):
    from know import atomic as write
    write(path, text)


# ---------------------------------------------------------------------------------------------------------------
# where the sources are (the owner's local config; engine/integrations.py when it is there)

def source_paths(data=DATA):
    """(aleph_db or None, vault_root or None) from the local config. Off in the config = None (never read)."""
    cfg = read_json(Path(data) / 'drafter.local.json', None)
    try:
        import integrations   # the release round's module: on in the config AND its file answers
        db = Path(integrations.local.setting('aleph', 'db')).expanduser() if integrations.available('aleph') and integrations.local.setting('aleph', 'db') else None
        vault = Path(integrations.local.setting('vault', 'path')).expanduser() if integrations.available('vault') else None
        return db, vault
    except ImportError:
        pass
    if cfg is None:   # no config at all (before the release round): Aleph where know.py has always read it, no vault
        db = Path.home() / 'Codius/Aleph/data/aleph.db'
        return (db if db.is_file() else None), None
    integ = cfg.get('integrations', {}) if isinstance(cfg, dict) else {}
    def on(name, key):
        it = integ.get(name) or {}
        p = it.get(key) or ''
        return Path(os.path.expanduser(p)) if it.get('enabled') is True and p else None
    db, vault = on('aleph', 'db'), on('vault', 'path')
    if db is None and (integ.get('aleph') or {}).get('enabled') is True:
        db = Path.home() / 'Codius/Aleph/data/aleph.db'
    return (db if db and db.is_file() else None), (vault if vault and vault.is_dir() else None)


def own_names(data=DATA):
    cfg = read_json(Path(data) / 'drafter.local.json', {})
    user = cfg.get('user', {}) if isinstance(cfg, dict) else {}
    names = [user.get('name') or '', user.get('short_name') or ''] + list(user.get('own_names') or [])
    return {fold(n) for n in names if isinstance(n, str) and n.strip()}


# ---------------------------------------------------------------------------------------------------------------
# sources

def aleph_slice(db, now, allow=()):
    """Records from Aleph. Private things and facts are excluded in SQL, except ids he allowed one by one."""
    allow = sorted({a for a in allow if isinstance(a, str)})
    con = sqlite3.connect(Path(db).resolve().as_uri() + '?mode=ro', uri=True)
    con.row_factory = sqlite3.Row
    marks = ','.join('?' * len(allow)) or "''"
    kinds = tuple(ALEPH_KIND)
    try:
        rows = con.execute(f"""SELECT id, kind, name, summary, short, scope FROM things
            WHERE kind IN ({','.join('?' * len(kinds))}) AND id != 'person:me'
            AND (coalesce(scope,'work') != 'private' OR id IN ({marks}))""", kinds + tuple(allow)).fetchall()
        ids = {r['id'] for r in rows}
        names = defaultdict(list)
        for r in con.execute(f"""SELECT n.name, n.thing FROM names n JOIN things t ON t.id = n.thing
                WHERE coalesce(t.scope,'work') != 'private' OR t.id IN ({marks})""", tuple(allow)):
            if r['thing'] in ids: names[r['thing']].append(r['name'])
        facts = defaultdict(list)
        for r in con.execute(f"""SELECT f.subj, f.rel, f.value, f.since, f.at, f.source, f.by, f.scope AS fscope,
                o.id AS oid, o.name AS oname, o.kind AS okind FROM facts f
                JOIN things s ON s.id = f.subj LEFT JOIN things o ON o.id = f.obj AND f.obj != ''
                WHERE (coalesce(s.scope,'work') != 'private' OR s.id IN ({marks}))
                AND (coalesce(f.scope,'work') != 'private' OR f.subj IN ({marks}))
                AND (o.id IS NULL OR coalesce(o.scope,'work') != 'private' OR o.id IN ({marks}))
                AND coalesce(f.status,'seen') NOT IN ('disproven','wrong','retracted')
                AND (f.until IS NULL OR f.until = 0 OR f.until > ?)""", tuple(allow) * 3 + (now,)):
            if r['subj'] in ids: facts[r['subj']].append(dict(r))
        merged = {r['id']: r['target'] for r in con.execute('SELECT id, target FROM merged')}
        notsame = [(r['a'], r['b']) for r in con.execute('SELECT a, b FROM notsame')]
    finally:
        con.close()
    out = []
    for r in rows:
        rec = {'system': 'aleph', 'id': r['id'], 'kind': ALEPH_KIND[r['kind']], 'name': (r['name'] or '').strip(),
               'aliases': sorted(set(names.get(r['id'], []) + ([r['short']] if r['short'] else []))),
               'summary': one_line(r['summary'], 300), 'handles': {}, 'facts': [], 'related': [], 'same': [],
               'private': (r['scope'] or 'work') == 'private'}
        if not rec['name']: continue
        for f in facts.get(r['id'], []):
            add_aleph_fact(rec, f)
        out.append(rec)
    return out, merged, notsame


FREE = {'next', 'does', 'goal', 'note'}


def add_aleph_fact(rec, f):
    rel, value, obj = f['rel'], ' '.join(str(f['value'] or '').split()), (f['oname'] or '').strip()
    date = day(f['since'] or f['at'])
    src = 'Aleph'
    priv = (f['fscope'] or 'work') == 'private'
    def fact(text, rank, quote=False):
        if PHONE.search(str(text)): return          # a fact that holds a phone number is left out whole
        text = one_line(text, FACT_MAX)
        if text:
            rec['facts'].append({'text': text, 'source': src, 'date': date, 'quote': quote, 'rank': rank, 'private': priv})
    if rel == 'handle':
        from know import handle
        key, val = handle(value)
        if key: rec['handles'].setdefault(key, []).append(val)   # phones only for his own card, never in a pack
    elif rel == 'role' and value: fact(value, 0); rec.setdefault('role', value)
    elif rel == 'works_at' and obj: fact('works at ' + obj, 1); rec.setdefault('org', obj); rec['related'].append(f['oid'])
    elif rel == 'works_on' and obj: fact('works on ' + obj, 2); rec['related'].append(f['oid'])
    elif rel == 'member_of' and obj and f['okind'] in ('project', 'org'): fact('part of ' + obj, 3); rec['related'].append(f['oid'])
    elif rel == 'status' and value: fact('status: ' + value, 1)
    elif rel == 'next' and value: fact('next: ' + value, 2, quote=f['by'] != 'me')
    elif rel in ('does', 'goal') and value: fact(value, 3, quote=f['by'] != 'me')
    elif rel == 'has_repo' and obj: fact('repo ' + obj, 4); rec['related'].append(f['oid'])
    elif rel == 'deployed_as' and obj: fact('runs as ' + obj, 4); rec['related'].append(f['oid'])
    elif rel == 'built_by' and obj: rec['related'].append(f['oid'])
    elif rel in ('relates', 'part', 'owns') and f['oid']: rec['related'].append(f['oid'])
    elif rel == 'same_as' and f['oid']: rec['same'].append(f['oid'])
    elif rel == 'link' and value.startswith(('http://', 'https://')): rec.setdefault('urls', []).append(value)
    elif rel == 'note' and value: fact(value, 6, quote=f['by'] != 'me')


def front(text):
    """A note's YAML frontmatter as a dict ({} when there is none or it does not parse)."""
    m = re.match(r'---\r?\n(.*?)\r?\n---', text, re.S)
    if not m: return {}
    try:
        import yaml
        d = yaml.safe_load(m.group(1))
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def marked_private(fm):
    tags = fm.get('tags') or []
    tags = [tags] if isinstance(tags, str) else tags if isinstance(tags, list) else []
    return (fm.get('private') is True or str(fm.get('scope', '')).lower() == 'private'
            or str(fm.get('visibility', '')).lower() == 'private' or any(str(t).strip('#').lower() == 'private' for t in tags))


def strs(v):
    if isinstance(v, str): return [v]
    if isinstance(v, list): return [str(x) for x in v if isinstance(x, (str, int, float)) and str(x).strip()]
    return []


def wikilinks(v):
    out = []
    for s in strs(v):
        for m in re.finditer(r'\[\[([^\]|#]+)', s): out.append(m.group(1).strip())
        if '[[' not in s and s.strip(): out.append(s.strip())
    return out


def vault_slice(root, allow=()):
    """Frontmatter of the vault's entity and story notes. Never a Private folder, never a note marked private,
    except single notes he allowed (context-allow.json, paths relative to the vault)."""
    root = Path(root)
    files = []
    for rel_dir, kind in VAULT_DIRS.items():
        d = root / rel_dir
        if not d.is_dir(): continue
        for f in sorted(d.iterdir()):   # the top level only: Private/ and every other subfolder are never opened
            if f.is_file() and f.suffix == '.md' and not f.name.startswith('.'): files.append((f, kind, False))
    for rel in allow:   # single notes he allowed, a Private one included: read only into its own record
        if not isinstance(rel, str) or '..' in Path(rel).parts or not rel.endswith('.md') or rel.startswith('/'): continue
        f = root / rel
        if f.is_file():
            kind = next((k for d, k in VAULT_DIRS.items() if rel.startswith(d + '/')), 'project')
            files.append((f, kind, True))
    out, seen = [], set()
    for f, kind, allowed in files:
        rel = f.relative_to(root).as_posix()
        if rel in seen: continue
        seen.add(rel)
        if any(p in VAULT_SKIP - ({'Private'} if allowed else set()) for p in Path(rel).parts): continue
        try: text = f.read_text(errors='ignore')[:6000]
        except OSError: continue
        fm = front(text)
        typ = str(fm.get('type') or '').lower()
        if typ == 'view': continue
        priv = marked_private(fm) or 'Private' in Path(rel).parts
        if priv and not allowed: continue
        if typ == 'org': kind = 'org'
        elif typ == 'person': kind = 'person'
        when = fm.get('updated') or fm.get('created') or ''
        date = str(when)[:10] if re.match(r'\d{4}-\d{2}-\d{2}', str(when)) else ''
        rec = {'system': 'vault', 'id': rel, 'kind': kind, 'name': f.stem, 'aliases': strs(fm.get('aliases')) + strs(fm.get('nick')),
               'summary': one_line(fm.get('summary'), 300), 'handles': {}, 'facts': [], 'related_paths': [], 'private': priv,
               'note': str(f), 'origin': str(fm.get('origin') or ''), 'date': date}
        def fact(text, rank, quote=False):
            if PHONE.search(str(text)): return
            text = one_line(text, FACT_MAX)
            if text:
                rec['facts'].append({'text': text, 'source': 'vault', 'date': date, 'quote': quote, 'rank': rank, 'private': priv})
        if fm.get('role'): fact(str(fm['role']), 0); rec['role'] = one_line(fm['role'], 120)
        for org in wikilinks(fm.get('org'))[:1]:
            name = Path(org).name
            fact('works at ' + name, 1); rec['org'] = name
        if fm.get('status') and kind == 'project': fact('status: ' + str(fm['status']), 1)
        if fm.get('next'): fact('next: ' + str(fm['next']), 2, quote=rec['origin'] not in ('', 'kit'))
        if rec['summary'] and kind != 'person': fact(rec['summary'], 3, quote=rec['origin'] not in ('', 'kit'))
        for key in ('epic', 'story', 'thread', 'entities', 'people', 'related'):
            rec['related_paths'] += [p if p.endswith('.md') else p + '.md' for p in wikilinks(fm.get(key))]
        for u in strs(fm.get('url')):
            if u.startswith(('http://', 'https://')): rec.setdefault('urls', []).append(u)
        out.append(rec)
    return out


def contacts_slice(entries):
    out = []
    for e in entries or []:
        if not isinstance(e, dict) or not e.get('id') or not e.get('name'): continue
        out.append({'system': 'contacts', 'id': e['id'], 'kind': 'person', 'name': e['name'], 'aliases': list(e.get('aliases') or []),
                    'summary': '', 'facts': [], 'related': [], 'private': False, 'cards_only': bool(e.get('cards_only')),
                    'handles': {k: list(v) for k, v in (e.get('handles') or {}).items() if k in ('email', 'tg', 'phone')}})
    return out


# ---------------------------------------------------------------------------------------------------------------
# merging

class Union:
    def __init__(self): self.up, self.members = {}, {}
    def find(self, a):
        if a not in self.up: self.up[a] = a; self.members[a] = {a}
        while self.up[a] != a:
            self.up[a] = self.up[self.up[a]]; a = self.up[a]
        return a
    def join(self, a, b, apart):
        ra, rb = self.find(a), self.find(b)
        if ra == rb: return True
        if apart and any((x, y) in apart or (y, x) in apart for x in self.members[ra] for y in self.members[rb]): return False
        self.up[rb] = ra
        self.members[ra] |= self.members.pop(rb)
        return True


def norm_handle(kind, v):
    v = str(v or '').strip()
    if kind == 'email': return v.casefold()
    if kind == 'tg': return v.lstrip('@').casefold()
    if kind == 'phone': return re.sub(r'\D', '', v)[-9:]
    return v


def aleph_slug(s):
    return re.sub(r'[^\w]+', '-', str(s).lower(), flags=re.U).strip('-')[:80] or 'x'


def merge(slices, merged=None, notsame=(), same_file=None):
    """Deterministic merges (proposal 1.5): Aleph's own (merged, same_as); same normalised handle with no second
    match; vault note <-> Aleph thing by the note's stem; his own yes/no from data/entity-same.json. Never on a first
    name alone. Returns (groups of source records, count of same-name pairs left apart for a "Same?" row)."""
    merged = merged or {}
    recs = {f"{r['system']}:{r['id']}": r for s in slices for r in s}
    apart = {(f'aleph:{a}', f'aleph:{b}') for a, b in notsame}
    sf = same_file or {}
    apart |= {(a, b) for a, b in (sf.get('not') or []) if isinstance(a, str) and isinstance(b, str)}
    u = Union()
    for k in recs: u.find(k)
    for k, r in recs.items():
        if r['system'] != 'aleph': continue
        for other in r.get('same', []):
            other = merged.get(other, other)
            if f'aleph:{other}' in recs: u.join(k, f'aleph:{other}', apart)
    # vault note -> the Aleph thing Aleph made from it (tid(kind, stem))
    aleph_kinds = {'person': ['person'], 'org': ['org'], 'project': ['project']}
    for k, r in recs.items():
        if r['system'] != 'vault': continue
        for ak in aleph_kinds.get(r['kind'], []):
            target = f"aleph:{ak}:{aleph_slug(r['name'])}"
            target = 'aleph:' + merged.get(target[6:], target[6:])
            if target in recs: u.join(target, k, apart); break
    # handles: a contact card joins the one known thing with the same address; a handle two known things share stays
    # apart (a shared mailbox, a family phone), and so does a card whose Telegram differs from the thing's
    owners = defaultdict(set)
    for k, r in recs.items():
        for kind, values in (r.get('handles') or {}).items():
            for v in values:
                n = norm_handle(kind, v)
                if len(n) >= 5: owners[(kind, n)].add(k)
    def tgs(root): return {norm_handle('tg', v) for k in u.members[root] for v in (recs[k].get('handles') or {}).get('tg', [])}
    def known(root): return any(recs[k]['system'] != 'contacts' for k in u.members[root])
    for (kind, n), keys in sorted(owners.items()):
        roots = {u.find(k) for k in keys}
        if len(roots) < 2: continue
        known_roots = [g for g in roots if known(g)]
        if len(known_roots) > 1: continue
        base = known_roots[0] if known_roots else sorted(roots)[0]
        for g in sorted(roots - {base}):
            a, b = tgs(base), tgs(g)
            if a and b and not a & b: continue
            u.join(base, g, apart)
    for a, b in (sf.get('same') or []):
        if a in recs and b in recs: u.join(a, b, apart)
    groups = defaultdict(list)
    for k in recs: groups[u.find(k)].append(recs[k])
    out = [sorted(g, key=lambda r: (ORDER[r['system']], r['id'])) for g in groups.values()]
    # same full name from two groups, no handle to confirm: left apart, counted for the "Same?" row (step 4)
    by_name = defaultdict(set)
    for i, g in enumerate(out):
        if g[0].get('cards_only'): continue
        by_name[fold(g[0]['name'])].add(i)
    pending = sum(1 for n, s in by_name.items() if len(s) > 1 and ' ' in n)
    return out, pending


# ---------------------------------------------------------------------------------------------------------------
# one record

def ordinary_words():
    from know import COMMON
    words = set(COMMON)
    try: words |= {w for w in Path('/usr/share/dict/words').read_text().splitlines() if w.islower()}
    except OSError: pass
    return words


def is_cyrillic(s):
    return bool(re.search(r'[А-Яа-яІіЇїЄєҐґ]', s or ''))


def make_record(group, aleph_ids, path_ids, codius=None):
    head = group[0]
    rid = f"{head['system']}:{head['id']}"
    names, aliases = [], []
    for r in group:
        names.append(r['name']); aliases += r.get('aliases', [])
    name = head['name']
    al = []
    for a in names + aliases:
        a = ' '.join(str(a).split())
        if not a or fold(a) == fold(name) or EMAIL.fullmatch(a) or PHONE.fullmatch(a) or len(a) < 2: continue
        if fold(a) not in {fold(x) for x in al}: al.append(a)
    kind = next((r['kind'] for r in group if r['system'] == 'aleph'), head['kind'])
    handles = defaultdict(list)
    for r in group:
        for k, vs in (r.get('handles') or {}).items():
            for v in vs:
                if v not in handles[k]: handles[k].append(v)
    facts = sorted((f for r in group for f in r.get('facts', [])), key=lambda f: (f['rank'], -int(f['date'].replace('-', '') or 0)))
    seen, uniq = set(), []
    for f in facts:
        key = fold(f['text'])
        if key not in seen: seen.add(key); uniq.append(f)
    role = next((r.get('role') for r in group if r.get('role')), '')
    org = next((r.get('org') for r in group if r.get('org')), '')
    summary = next((r['summary'] for r in group if r.get('summary')), '')
    if kind == 'person':
        who = ', '.join(x for x in [role, ('at ' + org) if org and fold(org) not in fold(role) else ''] if x) or summary
    else:
        who = summary or (uniq[0]['text'] if uniq else '')
    who = one_line(EMAIL.sub('', who), WHO_MAX)
    targets = {}
    note = next((r['note'] for r in group if r['system'] == 'vault'), '')
    vault_id = next((r['id'] for r in group if r['system'] == 'vault'), '')
    if vault_id: targets['obsidian'] = vault_id[:-3] if vault_id.endswith('.md') else vault_id
    if handles.get('email'): targets['mail'] = handles['email'][0]
    if handles.get('tg'): targets['tg'] = handles['tg'][0].lstrip('@')
    aleph_id = next((r['id'] for r in group if r['system'] == 'aleph'), '')
    if aleph_id: targets['aleph'] = aleph_id
    urls = [u for r in group for u in r.get('urls', [])]
    pointers = []
    if note: pointers.append({'label': 'Note' if kind in ('person', 'org') else 'Story', 'value': note, 'path': True})
    if kind in ('tool', 'project') and codius and fold(name) in codius:
        pointers.append({'label': 'Code' if kind == 'tool' else 'Repo', 'value': codius[fold(name)], 'path': True})
    for u in urls[:1]: pointers.append({'label': 'URL', 'value': u, 'path': False})
    if aleph_id and len(pointers) < 3: pointers.append({'label': 'Aleph', 'value': aleph_id, 'path': False})
    related = []
    for r in group:
        for x in r.get('related', []):
            if x and f'aleph:{x}' in aleph_ids: related.append(aleph_ids[f'aleph:{x}'])
        for p in r.get('related_paths', []):
            if f'vault:{p}' in path_ids: related.append(path_ids[f'vault:{p}'])
    uniq = [f for f in uniq if fold(f['text']) not in fold(who)]   # the one line already says it
    top = uniq[:4]
    if kind == 'person' and handles:
        h = ('email ' + handles['email'][0]) if handles.get('email') else ('Telegram @' + handles['tg'][0].lstrip('@')) if handles.get('tg') else ''
        if h: top = uniq[:3] + [{'text': h, 'source': 'Aleph' if aleph_id else 'contacts', 'date': '', 'quote': False, 'rank': 5, 'private': False}]
    private = any(r.get('private') for r in group) or any(f.get('private') for f in uniq)
    rec = {
        'id': rid, 'kind': kind, 'name': name, 'aliases': al[:20],
        'names': {'uk': next((n for n in [name] + al if is_cyrillic(n)), ''), 'en': next((n for n in [name] + al if not is_cyrillic(n)), '')},
        'who': who, 'related': [], 'related_ids': related,
        'sources': [{'system': r['system'], 'id': r['id']} for r in group],
        'targets': targets, 'kind_by': 'source',
        'handles': dict(handles),   # local, for his own card; render() never puts a handle but the one fact, never a phone
        'pack': {'facts': [{k: f[k] for k in ('text', 'source', 'date', 'quote')} for f in top], 'pointers': pointers[:3]},
        'private': private,
    }
    if all(r.get('cards_only') for r in group): rec['cards_only'] = True
    newest = max((f['date'] for f in top if f['date']), default='')
    rec['pack']['newest'] = newest
    return rec


def surfaces_for(rec, ordinary, stop):
    """Surface form -> how it matches, for one record: full name, aliases, a first+last pair, single tokens, case forms."""
    from know import person_forms
    out = {}
    def add(s, how):
        k = fold(s)
        if len(k) < 2 or k in stop: return
        if ' ' not in k and (k in ordinary or (len(k) < 3 and not (how == 'alias' and s.isupper()))): return
        if k not in out or MATCH[how] > MATCH[out[k]]: out[k] = how
    add(rec['name'], 'name')
    for a in rec['aliases']: add(a, 'alias')
    labels = [rec['name']] + rec['aliases']
    for label in labels:
        parts = WORDS.findall(label)
        if rec['kind'] == 'person' and len(parts) >= 2:
            add(parts[0] + ' ' + parts[-1], 'pair')
            add(parts[0], 'first')
            for p in parts[1:]: add(p, 'part')
        elif rec['kind'] != 'person' and len(parts) >= 2:
            pass   # "Lantern Labs": the whole name only, never "Labs" alone
    if rec['kind'] == 'person':
        for form in person_forms({'name': rec['name'], 'aliases': rec['aliases']}):
            add(form, 'form')
    return out


def build(out=None, *, db=None, vault=None, contacts=None, lines=(), now=None, data=None, ordinary=None, codius=None, write=True):
    """Build data/entities.json. db / vault: a path, False (off) or None (from the local config)."""
    data = Path(data) if data is not None else DATA
    out = Path(out) if out is not None else data / 'entities.json'
    now = time.time() if now is None else now
    if db is None or vault is None:
        cdb, cvault = source_paths(data)
        db = cdb if db is None else db
        vault = cvault if vault is None else vault
    codius = Path(codius) if codius is not None else Path.home() / 'Codius'
    try: codius = {fold(d.name): str(d) for d in codius.iterdir() if d.is_dir() and not d.name.startswith(('.', '_'))}
    except OSError: codius = {}
    allow = read_json(data / 'context-allow.json', {})
    allow = allow if isinstance(allow, dict) else {}
    cache = read_json(data / 'entity-sources.json', {})
    cache = cache if isinstance(cache, dict) else {}
    slices, merged, notsame, failed = {}, {}, [], []
    if db:
        try:
            slices['aleph'], merged, notsame = aleph_slice(db, now, allow.get('aleph') or [])
            cache['aleph'] = {'records': slices['aleph'], 'merged': merged, 'notsame': notsame}
        except (sqlite3.Error, OSError) as e:
            failed.append('aleph')
            old = cache.get('aleph') or {}
            slices['aleph'], merged, notsame = old.get('records', []), old.get('merged', {}), [tuple(x) for x in old.get('notsame', [])]
    else: cache.pop('aleph', None)
    if vault:
        try:
            slices['vault'] = vault_slice(vault, allow.get('vault') or [])
            cache['vault'] = {'records': slices['vault']}
        except OSError:
            failed.append('vault'); slices['vault'] = (cache.get('vault') or {}).get('records', [])
    else: cache.pop('vault', None)
    if contacts is not None:
        slices['contacts'] = contacts_slice(contacts)
        cache['contacts'] = {'records': slices['contacts']}
    else:
        slices['contacts'] = (cache.get('contacts') or {}).get('records', [])
    groups, same_pending = merge(list(slices.values()), merged, notsame, read_json(data / 'entity-same.json', {}))
    overrides = read_json(data / 'entity-overrides.json', {})
    overrides = overrides if isinstance(overrides, dict) else {}
    stop = {fold(s) for s in read_json(data / 'entity-stop.json', []) if isinstance(s, str)} | own_names(data)
    # every source key -> the id of the record it ends up in
    key_of = {}
    for g in groups:
        rid = f"{g[0]['system']}:{g[0]['id']}"
        for r in g: key_of[f"{r['system']}:{r['id']}"] = rid
    for old, new in merged.items():
        if f'aleph:{new}' in key_of: key_of[f'aleph:{old}'] = key_of[f'aleph:{new}']
    records = []
    for g in groups:
        rec = make_record(g, key_of, key_of, codius)
        ov = overrides.get(rec['id']) or next((overrides[k] for k in (f"{s['system']}:{s['id']}" for s in rec['sources']) if k in overrides), None)
        if isinstance(ov, dict) and ov.get('kind') in KINDS + ('none',):
            if ov['kind'] == 'none': continue
            rec['kind'], rec['kind_by'] = ov['kind'], ov.get('by', 'me')
        records.append(rec)
    model_kinds = read_json(data / 'entity-kinds.json', {})
    for term in (model_kinds if isinstance(model_kinds, dict) else {}):
        k = model_kinds[term]
        if isinstance(k, dict) and k.get('kind') in KINDS and fold(term) not in stop and not any(fold(r['name']) == fold(term) for r in records):
            records.append({'id': 'term:' + fold(term), 'kind': k['kind'], 'name': term, 'aliases': [], 'names': {}, 'who': '', 'related': [],
                            'related_ids': [], 'sources': [{'system': 'term', 'id': fold(term)}], 'targets': {}, 'kind_by': k.get('by', 'model'),
                            'handles': {}, 'pack': {'facts': [], 'pointers': [], 'newest': ''}, 'private': False})
    records.sort(key=lambda r: (KINDS.index(r['kind']), fold(r['name'])))
    index = {r['id']: i for i, r in enumerate(records)}
    links = defaultdict(set)
    for r in records:
        for x in r.pop('related_ids'):
            if x in index and x != r['id']: links[r['id']].add(x); links[x].add(r['id'])   # both ways
    for r in records:
        r['related'] = sorted(links[r['id']], key=lambda x: (KINDS.index(records[index[x]]['kind']), x))[:12]
    ordinary = ordinary_words() if ordinary is None else set(ordinary)
    surfaces = defaultdict(list)
    for i, r in enumerate(records):
        if r.get('cards_only'): continue
        for k, how in surfaces_for(r, ordinary, stop).items():
            surfaces[k].append([i, how])
    seen = mentions(records, surfaces, lines, now)
    for i, r in enumerate(records):
        n = seen.get(i, 0)
        r['seen'] = {'typed_30d': n}
        r['heat'] = round(1 + n + (0.5 if r['pack']['facts'] else 0) - (0.75 if r.get('cards_only') else 0), 3)
    ids_map = id_map(data, records, key_of)
    store = {'version': 1, 'built': now, 'built_day': day(now), 'failed': failed, 'same_pending': same_pending,
             'records': records, 'surfaces': dict(surfaces)}
    if write:
        atomic(out, json.dumps(store, ensure_ascii=False, separators=(',', ':')) + '\n')
        atomic(data / 'entity-sources.json', json.dumps(cache, ensure_ascii=False, separators=(',', ':')) + '\n')
        atomic(data / 'entity-ids.json', json.dumps(ids_map, ensure_ascii=False, indent=1) + '\n')
    return store


def mentions(records, surfaces, lines, now):
    """Sent lines in the last 30 days that name each record (one per line), counts only."""
    out = Counter()
    for row in lines:
        if isinstance(row, dict):
            t, text = row.get('t') or 0, row.get('text') or ''
            if t and now - float(t) > 30 * 86400: continue
        else: text = str(row)
        if '⟦drafter-test⟧' in text: continue
        ws = WORDS.findall(text)
        hits = set()
        for n in (3, 2, 1):
            for j in range(len(ws) - n + 1):
                span = ws[j:j + n]
                if not span[0][:1].isupper(): continue
                for i, _ in surfaces.get(fold(' '.join(span)), ()): hits.add(i)
        out.update(hits)
    return out


def id_map(data, records, key_of):
    """data/entity-ids.json: an old id -> the id it lives on under now, so a pick or mention survives a merge."""
    old = read_json(data / 'entity-ids.json', {})
    old = old if isinstance(old, dict) else {}
    now_ids = {r['id'] for r in records}
    prev = read_json(data / 'entities.json', {})
    for r in (prev.get('records') or []) if isinstance(prev, dict) else []:
        rid = r.get('id')
        if rid and rid not in now_ids:
            for s in r.get('sources') or []:
                k = f"{s.get('system')}:{s.get('id')}"
                if k in key_of and key_of[k] in now_ids: old[rid] = key_of[k]; break
    for k, v in key_of.items():
        if k != v and k not in now_ids: old[k] = v
    return {k: v for k, v in old.items() if k not in now_ids}


def sent_rows(path):
    try:
        with Path(path).open() as f:
            for line in f:
                try: row = json.loads(line)
                except ValueError: continue
                if isinstance(row, dict) and isinstance(row.get('text'), str): yield row
    except FileNotFoundError: return


# ---------------------------------------------------------------------------------------------------------------
# packs: a fixed template over stored records (the app's EntityRules.render is its twin)

def ptr_text(p):
    return f"{p['label']}: `{p['value']}`" if p.get('path') else f"{p['label']}: {p['value']}"


def stale(rec, today):
    newest = (rec.get('pack') or {}).get('newest') or ''
    if not newest: return True
    try: return (time.mktime(time.strptime(today, '%Y-%m-%d')) - time.mktime(time.strptime(newest, '%Y-%m-%d'))) / 86400 > STALE_DAYS
    except ValueError: return True


def fact_text(f):
    t = f['text']
    body = f'“{t}”' if f.get('quote') else t
    when = f", {f['date']}" if f.get('date') else ''
    return f"{body} ({f['source']}{when})."


def cut(s, n):
    """one_line for text already clean: the twin of EntityRules.cut."""
    if len(s) <= n: return s
    head = s[:n - 1]
    c = head.rsplit(' ', 1)[0] if ' ' in head else head
    return c.rstrip(' ,;.:-') + '…'


def render(rec, level, *, today, facts=None, pointers=None, who_max=None):
    """One bullet for one entity. level 2: name, who, one pointer (<= 160); level 3: full (<= 600). Level 1: ''."""
    if level <= 1: return ''
    name, pack, kw = rec['name'], rec.get('pack') or {}, KIND_WORD.get(rec['kind'], rec['kind'])
    ptrs = pack.get('pointers') or []
    who = rec.get('who') or ''
    if who_max is not None: who = cut(who, who_max) if who_max > 1 else ''
    if level == 2:
        tail = (' ' + (f"`{ptrs[0]['value']}`" if ptrs[0].get('path') else ptrs[0]['value'])) if ptrs else ''
        base = f"- **{name}**"
        if who:
            room = LINE_MAX - len(base + ' - .' + tail)
            who = cut(who, room) if room > 12 else ''
        return base + ((f" - {who}" + ('' if who.endswith('…') else '.')) if who else f" ({kw}).") + tail
    fs = list(pack.get('facts') or []) if facts is None else list(facts)
    ps = list(ptrs) if pointers is None else list(pointers)
    old = stale(rec, today)
    while True:
        body = f"- **{name}** ({kw})" + (f" - {who}" if who else '') + ('; no recent notes.' if old else '' if who.endswith('…') else '.')
        if not old:
            for f in fs: body += ' ' + fact_text(f)
        if ps: body += ' ' + ' · '.join(ptr_text(p) for p in ps)
        if len(body) <= FULL_MAX: return body
        if fs and not old: fs.pop(); continue
        if len(ps) > 1: ps = ps[:1]; continue
        return cut(body, FULL_MAX)


def block(items, *, today=None, limit=BLOCK_MAX):
    """The one block at the end of a message. items: [(record, level, mentions)]. Over the budget, drop in order:
    facts after the first two, pointers after the first, then whole entities step down to one line, the least
    mentioned first. The name and the first pointer are never dropped."""
    today = today or time.strftime('%Y-%m-%d')
    items = [(r, lv, m) for r, lv, m in items if lv >= 2]
    if not items: return ''
    state = [{'rec': r, 'level': lv, 'm': m, 'facts': None, 'ptrs': None} for r, lv, m in items]
    def text():
        lines = [render(s['rec'], s['level'], today=today, facts=s['facts'], pointers=s['ptrs'], who_max=s.get('who')) for s in state]
        return HEADER + '\n' + '\n'.join(lines)
    t = text()
    if len(t) <= limit: return t
    for s in state:
        if s['level'] == 3: s['facts'] = (s['rec'].get('pack') or {}).get('facts', [])[:2]
    t = text()
    if len(t) <= limit: return t
    for s in state:
        if s['level'] == 3: s['ptrs'] = (s['rec'].get('pack') or {}).get('pointers', [])[:1]
    t = text()
    order = sorted(range(len(state)), key=lambda i: (state[i]['m'], -i))
    for i in order:
        if len(t) <= limit: return t
        if state[i]['level'] == 3: state[i]['level'] = 2; t = text()
    for i in order:
        if len(t) <= limit: return t
        state[i]['who'] = 0; t = text()
    return t


def brief(records, rec, *, today=None, limit=BRIEF_MAX):
    """"context for <name>": the entity in full, then its related ones, project first, then people, tools, documents."""
    today = today or time.strftime('%Y-%m-%d')
    by_id = {r['id']: r for r in records}
    rank = {'project': 0, 'org': 1, 'person': 2, 'tool': 3, 'doc': 4, 'place': 5}
    rel = sorted((by_id[x] for x in rec.get('related', []) if x in by_id), key=lambda r: (rank.get(r['kind'], 9), -r.get('heat', 0)))
    out = HEADER + '\n' + render(rec, 3, today=today)
    for r in rel:
        line = render(r, 2, today=today)
        if len(out) + 1 + len(line) > limit: break
        out += '\n' + line
    return out


# ---------------------------------------------------------------------------------------------------------------
# reading the store (the engine's /context and /entity, the CLI)

class Store:
    def __init__(self, path=None):
        self.path = Path(path) if path else DATA / 'entities.json'
        self.stamp, self.data = None, {'records': [], 'surfaces': {}}

    def reload(self):
        try:
            st = self.path.stat(); stamp = (st.st_mtime_ns, st.st_size)
            if stamp == self.stamp: return self.data
            d = json.loads(self.path.read_text())
            if isinstance(d, dict) and isinstance(d.get('records'), list):
                self.data, self.stamp = d, stamp
        except FileNotFoundError:
            self.data, self.stamp = {'records': [], 'surfaces': {}}, None
        except (OSError, ValueError): pass
        return self.data

    def find(self, q, limit=8):
        """Exact surface first (with how it matched), then a prefix over names and aliases, warmest first."""
        d = self.reload(); recs = d.get('records', [])
        q = fold(str(q or '').lstrip(';@'))
        if len(q) < 2: return []
        hits = [(recs[i], MATCH.get(how, 1)) for i, how in d.get('surfaces', {}).get(q, []) if i < len(recs)]
        if not hits:
            hits = [(r, 0.5) for r in recs if any(fold(n).startswith(q) or any(w.startswith(q) for w in fold(n).split())
                                                  for n in [r['name']] + r.get('aliases', []))]
        hits.sort(key=lambda x: (-x[1], x[0].get('cards_only', False), -x[0].get('heat', 0), x[0]['name']))
        out, seen = [], set()
        for r, _ in hits:
            if r['id'] not in seen: seen.add(r['id']); out.append(r)
        return out[:limit]

    def context(self, q, level=2, today=None):
        found = [r for r in self.find(q) if not r.get('cards_only')]
        if not found: return {'q': q, 'found': 0}
        r = found[0]
        level = max(1, min(3, int(level)))
        return {'q': q, 'found': len(found), 'id': r['id'], 'name': r['name'], 'kind': r['kind'], 'level': level,
                'text': block([(r, level, 1)], today=today) if level >= 2 else r['name'],
                'pointers': (r.get('pack') or {}).get('pointers', []), 'private': bool(r.get('private')),
                'built': self.data.get('built_day', ''),
                'others': [{'id': o['id'], 'name': o['name'], 'kind': o['kind'], 'who': o.get('who', '')} for o in found[1:5]]}

    def entity(self, q):
        return {'q': q, 'entities': [{'id': r['id'], 'name': r['name'], 'kind': r['kind'], 'who': r.get('who', ''),
                                      'aliases': r.get('aliases', [])[:6], 'targets': {k: v for k, v in r.get('targets', {}).items() if k != 'tg'},
                                      'related': r.get('related', [])[:6]} for r in self.find(q) if not r.get('cards_only')]}

    def brief(self, q, today=None):
        found = [r for r in self.find(q) if not r.get('cards_only')]
        if not found: return {'q': q, 'found': 0}
        return {'q': q, 'found': len(found), 'id': found[0]['id'], 'text': brief(self.data['records'], found[0], today=today)}


# ---------------------------------------------------------------------------------------------------------------
# kinds for leftovers: a hook, off by default (proposal 1.3). The answer is one word from KINDS or "none".

CLASSIFY_PROMPT = ('One word answer. What kind of thing is "{name}" most likely, as a name a person writes in notes? '
                   'Choose from: person, org, project, tool, doc, place, none.')


def classify(names, ask, data=DATA):
    """Ask `ask(name) -> word` for each leftover name; keep only answers in the fixed list. Results go to
    data/entity-kinds.json (by: the asker); his own overrides always win at build time."""
    kinds = read_json(data / 'entity-kinds.json', {})
    kinds = kinds if isinstance(kinds, dict) else {}
    done = 0
    for n in names:
        if n in kinds: continue
        word = (ask(n) or '').strip().lower().strip('.')
        if word in KINDS or word == 'none':
            kinds[n] = {'kind': word, 'by': getattr(ask, 'by', 'model'), 'at': day(time.time())}; done += 1
    atomic(data / 'entity-kinds.json', json.dumps(kinds, ensure_ascii=False, indent=1) + '\n')
    return done


def leftovers(data=DATA):
    """Names with no kind: dictionary terms in know.json (the pack calls them `term`)."""
    pack = read_json(data / 'know.json', {})
    return sorted({e['name'] for e in pack.get('entries', []) if isinstance(e, dict) and e.get('kind') == 'term' and e.get('name')})


def ask_claude(name):
    """Only the name and the kind list go out, and only when Settings' entityClassify is on (engine/cloud.py)."""
    import cloud, router
    try: st = json.loads((DATA / 'settings.json').read_text())
    except Exception: st = {}
    if not (cloud.allowed('entities', st) and router.online()): return None
    import claude_worker
    return claude_worker.ask(CLASSIFY_PROMPT.format(name=name.replace('"', '')), 20)
ask_claude.by = 'claude'


def ask_local(name):
    """The warm local model through the engine's /classify route, under its guard. The route is not built yet
    (step 4): until then this returns None and nothing is classified."""
    import urllib.request
    try:
        req = urllib.request.Request('http://127.0.0.1:8798/classify', json.dumps({'name': name}).encode(), {'Content-Type': 'application/json'})
        return json.loads(urllib.request.urlopen(req, timeout=5).read()).get('kind')
    except Exception:
        return None
ask_local.by = 'local'


def correct(entity_id, key, data=DATA):
    """The one-key kind fix (1 person · 2 org · 3 project · 4 tool · 5 doc · 6 place · 0 not a thing)."""
    kind = KIND_KEYS.get(str(key))
    if not kind: return False
    ov = read_json(data / 'entity-overrides.json', {})
    ov = ov if isinstance(ov, dict) else {}
    ov[entity_id] = {'kind': kind, 'by': 'me', 'at': day(time.time())}
    atomic(data / 'entity-overrides.json', json.dumps(ov, ensure_ascii=False, indent=1) + '\n')
    return True


def stats(store):
    recs = store.get('records', [])
    kinds = Counter(r['kind'] for r in recs)
    return {'records': len(recs), 'kinds': dict(kinds), 'cards_only': sum(1 for r in recs if r.get('cards_only')),
            'sources': dict(Counter(s['system'] for r in recs for s in r['sources'])),
            'merged_records': sum(1 for r in recs if len(r['sources']) > 1),
            'obsidian_target': sum(1 for r in recs if r.get('targets', {}).get('obsidian')),
            'with_dated_fact': sum(1 for r in recs if any(f.get('date') for f in r['pack']['facts'])),
            'private_allowed': sum(1 for r in recs if r.get('private')),
            'surfaces': len(store.get('surfaces', {})), 'ambiguous_surfaces': sum(1 for v in store.get('surfaces', {}).values() if len({i for i, _ in v}) > 1),
            'forms': sum(1 for v in store.get('surfaces', {}).values() if any(h == 'form' for _, h in v)),
            'same_pending': store.get('same_pending', 0), 'failed': store.get('failed', [])}


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['build', 'stats', 'pack', 'context', 'classify'])
    ap.add_argument('query', nargs='?', default='')
    ap.add_argument('--level', type=int, default=3)
    ap.add_argument('--out', type=Path, default=None)
    ap.add_argument('--with', dest='asker', choices=['local', 'claude'], default='local')
    args = ap.parse_args()
    if args.command == 'build':
        t0 = time.time()
        snap = read_json(DATA / 'contacts.json', {})
        store = build(args.out, contacts=snap.get('entries') if isinstance(snap, dict) and isinstance(snap.get('entries'), list) else None,
                      lines=sent_rows(DATA / 'typed.jsonl'))
        print(json.dumps({**stats(store), 'ms': int((time.time() - t0) * 1000)}))
    elif args.command == 'stats':
        print(json.dumps(stats(Store(args.out).reload())))
    elif args.command == 'pack':
        print(json.dumps(Store(args.out).context(args.query, args.level), ensure_ascii=False, indent=1))
    elif args.command == 'context':
        print(json.dumps(Store(args.out).brief(args.query), ensure_ascii=False, indent=1))
    elif args.command == 'classify':
        print(classify(leftovers(), ask_claude if args.asker == 'claude' else ask_local), 'classified')
