"""Search rows -> work cards: one film / album / game = one card with its best release (owner 2026-10-22)."""
import re
import picker

def _name_year(t):
    t = re.sub(r'^(\s*[\[(][^\])]*[\])])+', '', t)   # leading tags: (Progressive Rock) [CD]
    y = re.search(r'\b(19[2-9]\d|20[0-4]\d)\b', t); year = y.group(1) if y else ''
    parts = [p for p in t.split(' / ') if p.strip()] or [t]
    n = next((p for p in parts if re.search(r'[A-Za-z]', p)), parts[0])   # prefer the first Latin title
    if '.' in n and ' ' not in n.strip(): n = n.replace('.', ' ')
    n = re.split(r'\s*[\[(|]|\s(19|20)\d{2}\b|\.\(|\.(19|20)\d{2}\.|\b(2160p|1080p|720p|S\d\d)\b'
                 r'|\s-\s(Update|Patch|Hotfix)\b|\sv\.?\s?\d|\s\d+x(CD|LP)\b', n)[0]
    return (n or '').strip(' -:._'), year

def _key(name, year):
    return re.sub(r'[^0-9a-zа-яіїєґ]', '', name.lower()) + ':' + year

def works(rows):
    cards = {}
    for r in rows:
        n, y = _name_year(r.get('title', '')); k = _key(n, y)
        c = cards.setdefault(k, {'key': k, 'title': n, 'year': y, 'kind': '', 'rows': [], 'kinds': []}); c['rows'].append(r)
        c['kinds'].append(picker.kind(r))
    for k in [k for k, c in cards.items() if not c['year']]:   # a year-less row set folds into the biggest same-name card with a year
        c = cards[k]; host = [h for h in cards.values() if h['year'] and h['key'].split(':')[0] == k.split(':')[0]]
        if host:
            h = max(host, key=lambda x: len(x['rows'])); h['rows'] += c['rows']; h['kinds'] += c['kinds']; del cards[k]
    out = []
    for c in cards.values():
        # One name can be a film and its soundtrack: rows split by kind (film/series together), 'other' joins the biggest part.
        # Measured 2026-10-22: one OST row turned the 342-row "Dune: Part Two" card into music with a CD as best.
        ks, parts = c.pop('kinds'), {}
        for r, k in zip(c['rows'], ks):
            if k == 'film' and not r.get('quality'): k = 'other'   # only a year in the name: a guess, not video
            parts.setdefault('video' if k in ('film', 'series') else k, []).append((r, k))
        if 'other' in parts and len(parts) > 1:
            rest = parts.pop('other'); max(parts.values(), key=len).extend(rest)
        for cls, items in parts.items():
            pk = [k for _, k in items if k != 'other'] or ['other']
            d = dict(c, rows=[r for r, _ in items], kind=max(set(pk), key=pk.count))
            if len(parts) > 1: d['key'] = c['key'] + ':' + cls
            d['count'] = len(d['rows']); d['best'] = picker.best(d['rows'], d['kind']); out.append(d)
    g = {'g': 0, 'y': 1, 'u': 1, 'r': 2}
    return sorted(out, key=lambda c: (g.get(c['best'].get('grade'), 2), -sum(x.get('seeds', 0) for x in c['rows'])))
