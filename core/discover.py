#!/usr/bin/env python3
"""tinyTV Discover: film lists for the Kino page (owner-approved concept, 2026-10-21).

Sources without keys: IMDb datasets (ratings, titles), Wikidata (awards, directors, labels, Rotten Tomatoes,
new releases), Wikipedia page images (posters). Stdlib only (the core host has Python 3.9).

  discover.py build              daily: IMDb index + awards (run in the background by the core)
  discover.py list TAB [PARAM]   JSON list for a tab: top, new, cannes, festivals, year, genre, director, foryou
  discover.py info TT [TT ...]   JSON details for IMDb ids (labels, directors, RT, poster)
"""
import gzip, json, os, re, sys, time, datetime, urllib.parse, urllib.request

UA = 'tinyTV/1.0 (personal home media remote; low-volume film lookups; Python-urllib)'
SSD = os.environ.get('TINYTV_EXTERNAL', '')   # optional external disk for the cache
CACHE = os.path.join(SSD, 'tinyTV-cache', 'discover') if SSD and os.access(SSD, os.W_OK) else os.path.expanduser('~/Library/Caches/tinyTV/discover')
os.makedirs(CACHE, exist_ok=True)
KINO = os.path.expanduser('~/Library/Application Support/tinyTV/kino.json')

AWARDS = {  # code -> (Wikidata item, tier)
    'palme': ('Q179808', 'gold'), 'oscar': ('Q102427', 'gold'),
    'cannes_gp': ('Q844804', 'silver'), 'cannes_dir': ('Q510175', 'silver'),
    'lion': ('Q209459', 'silver'), 'bear': ('Q154590', 'silver'),
}
AWARD_NAME = {'palme': 'Золота пальма', 'oscar': 'Оскар', 'cannes_gp': 'Гран-прі Канн', 'cannes_dir': 'Режисура, Канни',
              'lion': 'Золотий лев', 'bear': 'Золотий ведмідь'}


def path(n): return os.path.join(CACHE, n)
def fresh(n, hours): return os.path.exists(path(n)) and time.time() - os.path.getmtime(path(n)) < hours * 3600
def load(n, default):
    try:
        with open(path(n)) as f: return json.load(f)
    except Exception: return default
def save(n, d):
    tmp = path(n + '.tmp')
    with open(tmp, 'w') as f: json.dump(d, f, ensure_ascii=False)
    os.replace(tmp, path(n))


_last_call = [0.0]
def http(url, data=None, timeout=90, headers=None):
    # Wikimedia rate-limits per address (429 on 2026-10-21 after a busy day): at most one call a second,
    # and on 429 wait as told (Retry-After) once instead of hammering.
    wait = 1.0 - (time.time() - _last_call[0])
    if wait > 0: time.sleep(wait)
    for attempt in range(2):
        _last_call[0] = time.time()
        r = urllib.request.Request(url, data=data, headers={'User-Agent': UA, **(headers or {})})
        try:
            with urllib.request.urlopen(r, timeout=timeout) as resp: return resp.read()
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt: raise
            time.sleep(min(60, int(e.headers.get('Retry-After') or 20)))


def sparql(q):
    d = http('https://query.wikidata.org/sparql', data=urllib.parse.urlencode({'query': q, 'format': 'json'}).encode(),
             timeout=120, headers={'Content-Type': 'application/x-www-form-urlencoded', 'Accept': 'application/sparql-results+json'})
    return json.loads(d)['results']['bindings']


def val(b, k): return b[k]['value'] if k in b else None


# ---------- daily build ----------

def download(name):
    if fresh(name, 24): return
    tmp = path(name + '.part')
    with urllib.request.urlopen(urllib.request.Request('https://datasets.imdbws.com/' + name, headers={'User-Agent': UA}), timeout=900) as r, open(tmp, 'wb') as f:
        while True:
            b = r.read(1 << 20)
            if not b: break
            f.write(b)
    os.replace(tmp, path(name))


def build_movies():
    download('title.ratings.tsv.gz'); download('title.basics.tsv.gz')
    votes = {}
    with gzip.open(path('title.ratings.tsv.gz'), 'rt', encoding='utf-8') as f:
        next(f)
        for line in f:
            t, r, v = line.rstrip('\n').split('\t')
            if int(v) >= 1000: votes[t] = (float(r), int(v))
    movies = {}
    with gzip.open(path('title.basics.tsv.gz'), 'rt', encoding='utf-8') as f:
        next(f)
        for line in f:
            p = line.rstrip('\n').split('\t')
            if len(p) < 9 or p[1] not in ('movie', 'tvSeries', 'tvMiniSeries') or p[0] not in votes: continue
            r, v = votes[p[0]]
            movies[p[0]] = {'t': p[2], 'o': p[3], 'y': int(p[5]) if p[5].isdigit() else 0, 'm': int(p[7]) if p[7].isdigit() else 0,
                            **({'k': 's'} if p[1] != 'movie' else {}),
                            'g': [] if p[8] == '\\N' else p[8].split(','), 'r': r, 'v': v}
    save('movies.json', movies)


def build_awards():
    out = {}
    for code, (q, _) in AWARDS.items():
        rows = sparql('SELECT ?imdb ?year WHERE { ?f p:P166 ?s. ?s ps:P166 wd:%s. ?f wdt:P345 ?imdb. '
                      'OPTIONAL { ?s pq:P585 ?d. BIND(YEAR(?d) AS ?year) } }' % q)
        for b in rows:
            i = val(b, 'imdb')
            if i and i.startswith('tt'): out.setdefault(i, {})[code] = int(val(b, 'year') or 0)
    save('awards.json', out)


def build_new():
    since = (datetime.date.today() - datetime.timedelta(days=150)).isoformat()
    # First release in the window (re-releases of old films also carry recent dates: MIN, not MAX).
    rows = sparql('SELECT ?imdb (MIN(?d) AS ?date) (MAX(?sl) AS ?links) WHERE { ?f wdt:P31 wd:Q11424; wdt:P345 ?imdb; wdt:P577 ?d; '
                  'wikibase:sitelinks ?sl. FILTER(?sl >= 6) } GROUP BY ?imdb '
                  'HAVING(MIN(?d) >= "%sT00:00:00Z"^^xsd:dateTime && MIN(?d) <= NOW()) ORDER BY DESC(?links) LIMIT 150' % since)
    save('new.json', [{'imdb': val(b, 'imdb'), 'date': (val(b, 'date') or '')[:10]} for b in rows if (val(b, 'imdb') or '').startswith('tt')])


def build():
    for step in (build_movies, build_awards, build_new):
        try: step()
        except Exception as e: print('discover build: %s failed: %s' % (step.__name__, e), file=sys.stderr)


# ---------- details (cached per film) ----------

def info(ids):
    cache = load('info.json', {})
    need = [i for i in dict.fromkeys(ids) if i not in cache or time.time() - cache[i].get('at', 0) > 30 * 86400 or cache[i].get('iv') != 4]
    for k in range(0, len(need), 80):
        part = need[k:k + 80]
        try:
            rows = sparql('SELECT ?imdb ?uk ?ru ?en ?dir ?dirEn ?dop ?dopEn ?rt ?wiki ?cn WHERE { VALUES ?imdb { %s } ?f wdt:P345 ?imdb. '
                          'OPTIONAL { ?f wdt:P495 ?c. ?c rdfs:label ?cn FILTER(LANG(?cn)="en") } '
                          'OPTIONAL { ?f wdt:P344 ?o. OPTIONAL { ?o rdfs:label ?dop FILTER(LANG(?dop)="uk") } OPTIONAL { ?o rdfs:label ?dopEn FILTER(LANG(?dopEn)="en") } } '
                          'OPTIONAL { ?f rdfs:label ?uk FILTER(LANG(?uk)="uk") } OPTIONAL { ?f rdfs:label ?ru FILTER(LANG(?ru)="ru") } '
                          'OPTIONAL { ?f rdfs:label ?en FILTER(LANG(?en)="en") } '
                          'OPTIONAL { ?f wdt:P57 ?d. OPTIONAL { ?d rdfs:label ?dir FILTER(LANG(?dir)="uk") } OPTIONAL { ?d rdfs:label ?dirEn FILTER(LANG(?dirEn)="en") } } '
                          'OPTIONAL { ?f p:P444 ?s. ?s ps:P444 ?rt; pq:P447 wd:Q105584. } '
                          'OPTIONAL { ?wiki schema:about ?f; schema:isPartOf <https://en.wikipedia.org/>. } }'
                          % ' '.join('"%s"' % i for i in part))
        except Exception as e:
            print('discover info: %s' % e, file=sys.stderr); continue
        got = {}
        for b in rows:
            i = val(b, 'imdb'); g = got.setdefault(i, {'dirs': [], 'at': time.time()})
            for k2 in ('uk', 'ru', 'en'):
                if val(b, k2) and k2 not in g: g[k2] = val(b, k2)
            d = val(b, 'dir') or val(b, 'dirEn')
            if d and d not in g['dirs']: g['dirs'].append(d)
            if val(b, 'dirEn') and val(b, 'dirEn') not in g.setdefault('dirsEn', []): g['dirsEn'].append(val(b, 'dirEn'))
            o = val(b, 'dop') or val(b, 'dopEn')
            if o and o not in g.setdefault('dops', []): g['dops'].append(o)
            if val(b, 'dopEn') and val(b, 'dopEn') not in g.setdefault('dopsEn', []): g['dopsEn'].append(val(b, 'dopEn'))
            if val(b, 'cn') and val(b, 'cn') not in g.setdefault('countries', []): g['countries'].append(val(b, 'cn'))
            rt = val(b, 'rt') or ''
            if rt.endswith('%') and 'rt' not in g: g['rt'] = rt
            if val(b, 'wiki') and 'wiki' not in g: g['wiki'] = urllib.parse.unquote(val(b, 'wiki').rsplit('/', 1)[-1]).replace('_', ' ')
        posters(got)
        for i in part: cache[i] = dict(got.get(i, {'dirs': [], 'at': time.time()}), pv=2, iv=4)
        save('info.json', cache)
    # Posters fetched before pilicense=any were mostly missing: fetch them once more.
    old = {i: cache[i] for i in ids if i in cache and cache[i].get('wiki') and cache[i].get('pv') != 2}
    if old:
        posters(old)
        for i in old: cache[i]['pv'] = 2
        save('info.json', cache)
    return {i: cache.get(i, {}) for i in ids}


def posters(got):
    titles = {g['wiki']: i for i, g in got.items() if g.get('wiki')}
    names = list(titles)
    for k in range(0, len(names), 50):
        # pilicense=any: film posters are non-free images, which pageimages hides by default.
        q = urllib.parse.urlencode({'action': 'query', 'format': 'json', 'prop': 'pageimages', 'piprop': 'thumbnail', 'pilicense': 'any',
                                    'pithumbsize': 360, 'redirects': 1, 'titles': '|'.join(names[k:k + 50])})
        try: d = json.loads(http('https://en.wikipedia.org/w/api.php?' + q))['query']
        except Exception: continue
        alias = {}
        for kind in ('normalized', 'redirects'):
            for m in d.get(kind, []): alias[m['to']] = alias.get(m['from'], m['from'])
        for p in d.get('pages', {}).values():
            src = (p.get('thumbnail') or {}).get('source')
            orig = alias.get(p.get('title'), p.get('title'))
            if src and orig in titles: got[titles[orig]]['poster'] = src


# ---------- lists ----------

def norm(s): return re.sub(r'[^0-9a-zа-яіїєґё]', '', (s or '').lower().replace('ё', 'е'))


def seen_titles():
    try:
        with open(KINO) as f: h = json.load(f).get('history', [])
    except Exception: h = []
    return {norm(x.get('title')) for x in h if x.get('title')}


def weighted(m, minv):
    def score(x): v, r = x['v'], x['r']; return v / (v + minv) * r + minv / (v + minv) * 6.9
    return score


AVAIL_DAYS = 7
def availability():
    """Written by the core (HDRezka + torrent check per film): {imdb: {rz, tor, k4, at}}."""
    return load('avail.json', {})


def item(i, movies, awards, inf, top250, newset, seen, av=None):
    m = movies.get(i, {}); a = awards.get(i, {}); d = inf.get(i, {})
    a2 = (av or {}).get(i)
    if a2 and time.time() - a2.get('at', 0) > AVAIL_DAYS * 86400: a2 = None
    badges = []
    for code in ('palme', 'oscar', 'cannes_gp', 'cannes_dir', 'lion', 'bear'):
        if code in a: badges.append({'k': AWARDS[code][1], 'n': AWARD_NAME[code] + (' %d' % a[code] if a[code] else '')})
    if i in top250: badges.append({'k': 'top', 'n': 'Топ-250 IMDb'})
    if i in newset: badges.append({'k': 'new', 'n': 'новий'})
    names = [d.get('uk'), d.get('ru'), d.get('en'), m.get('t'), m.get('o')]
    clean = lambda t: re.sub(r'\s*\((фільм|film|фильм)[^)]*\)$', '', t or '')
    return {'imdb': i, 'title': clean(d.get('uk') or d.get('en') or m.get('t') or i), 'ru': d.get('ru') or '', 'orig': d.get('en') or m.get('o') or '',
            'year': m.get('y') or 0, 'dirs': d.get('dirs', [])[:2], 'dirsEn': d.get('dirsEn', [])[:2],
            'dops': d.get('dops', [])[:2], 'dopsEn': d.get('dopsEn', [])[:2], 'imdbR': m.get('r'), 'votes': m.get('v'), 'rt': d.get('rt'),
            'poster': d.get('poster'), 'genres': m.get('g', []), 'badges': badges, 'mins': m.get('m', 0), 'countries': d.get('countries', [])[:2],
            'av': ({'rz': bool(a2.get('rz')), 'rzUrl': a2.get('rz') or '', 'tor': a2.get('tor', 0), 'k4': a2.get('k4', False), 'ua': a2.get('ua', False)} if a2 else None),
            'gold': any(b['k'] == 'gold' for b in badges), 'fresh': i in newset, 'seen': any(norm(n) in seen for n in names if n)}


REGIONS = {
    'hollywood': {'United States', 'United States of America', 'United Kingdom', 'Canada', 'Australia', 'Ireland', 'New Zealand'},
    'europe': {'France', 'Italy', 'Germany', 'Spain', 'Belgium', 'Netherlands', 'Austria', 'Switzerland', 'Poland', 'Czech Republic', 'Portugal',
               'Greece', 'Romania', 'Hungary', 'Turkey', 'West Germany', 'Soviet Union', 'Russia', 'Georgia'},
    'asia': {'Japan', 'South Korea', 'China', "People's Republic of China", 'Hong Kong', 'Taiwan', 'India', 'Iran', 'Thailand'},
    'ukraine': {'Ukraine', 'Ukrainian Soviet Socialist Republic'},
    'nordic': {'Sweden', 'Norway', 'Denmark', 'Finland', 'Iceland'},
    'latam': {'Mexico', 'Argentina', 'Brazil', 'Chile', 'Colombia', 'Cuba'},
}
MOOD = {'light': {'Comedy', 'Animation', 'Adventure', 'Family', 'Romance', 'Music'}, 'serious': {'Drama', 'History', 'Biography', 'War'},
        'dark': {'Crime', 'Thriller', 'Horror', 'Mystery'}, 'mind': {'Sci-Fi', 'Mystery', 'Fantasy'}}
GENRE_UK = {'Drama': 'драма', 'Comedy': 'комедія', 'Thriller': 'трилер', 'Crime': 'кримінал', 'Sci-Fi': 'фантастика', 'Mystery': 'детектив',
            'Romance': 'мелодрама', 'Horror': 'жахи', 'Animation': 'анімація', 'Documentary': 'документальне', 'Adventure': 'пригоди',
            'Action': 'бойовик', 'Biography': 'біографія', 'History': 'історія', 'War': 'війна', 'Western': 'вестерн', 'Music': 'музика',
            'Fantasy': 'фентезі', 'Family': 'сімейне'}
SEED_FILMS = ['tt0062622', 'tt0075314', 'tt0110912', 'tt0118715', 'tt0211915', 'tt0245429', 'tt6751668', 'tt0364569', 'tt1375666', 'tt0816692',
              'tt2582802', 'tt0405094', 'tt0264464', 'tt0109830', 'tt0338013', 'tt1798709', 'tt0477348', 'tt0457430', 'tt2278388', 'tt0050083',
              'tt0099685', 'tt5052448', 'tt1675434', 'tt0078748']


def kino_data():
    try:
        with open(KINO) as f: return json.load(f)
    except Exception: return {}


def history_ids(hist):
    """History has titles (HDRezka, Russian): map them to IMDb ids once, cached."""
    cache = load('hist_map.json', {})
    labels = [x.get('title') for x in hist if x.get('title') and x.get('title') not in cache][:40]
    if labels:
        try:
            rows = sparql('SELECT DISTINCT ?l ?imdb WHERE { VALUES ?l { %s } ?f rdfs:label ?l; wdt:P345 ?imdb. ?f wdt:P31/wdt:P279* wd:Q11424. }'
                          % ' '.join('"%s"@ru "%s"@uk' % (l.replace('"', ''), l.replace('"', '')) for l in labels))
            for b in rows: cache[val(b, 'l')] = val(b, 'imdb')
        except Exception as e: print('discover hist: %s' % e, file=sys.stderr)
        for l in labels: cache.setdefault(l, '')
        save('hist_map.json', cache)
    return {cache.get(x.get('title')) for x in hist if cache.get(x.get('title'))}


def pool_ids(movies, awards, new):
    big = [i for i, m in movies.items() if m['v'] >= 25000 and m.get('k') != 's']
    score = weighted(movies, 25000)
    top = sorted(big, key=lambda i: -score(movies[i]))[:400]
    gen = []
    for g in GENRE_UK:
        gen += sorted([i for i in big if g in movies[i]['g']], key=lambda i: -score(movies[i]))[:40]
    return list(dict.fromkeys(top + [n['imdb'] for n in new] + [i for i in awards if i in movies] + gen))


def for_you(movies, awards, new):
    """Owner's taste (questionnaire) + his lists + what he watched -> score per film, with the reasons that made it."""
    kd = kino_data(); t = kd.get('taste') or {}
    if not t: return [], '', {}
    hist = kd.get('history', [])
    seen_ids = history_ids(hist)
    rated = t.get('films', {})
    liked_films = [i for i, v in rated.items() if v > 0]; disliked_films = [i for i, v in rated.items() if v < 0]
    listed = [x.get('imdb') for x in kd.get('watch', []) + kd.get('fav', []) if x.get('imdb')]
    anchors = set(liked_films) | set(listed) | seen_ids
    pool = pool_ids(movies, awards, new)
    inf = info(list(dict.fromkeys(pool + list(anchors) + disliked_films)))
    # Directors he likes: picked in the questionnaire, or behind films he liked / listed / watched.
    fav_dirs = set(t.get('directors', []))
    why_dir = {}
    for i in anchors:
        for d in inf.get(i, {}).get('dirsEn', [])[:1]:
            fav_dirs.add(d); why_dir.setdefault(d, (inf.get(i, {}).get('uk') or movies.get(i, {}).get('t') or ''))
    bad_dirs = {d for i in disliked_films for d in inf.get(i, {}).get('dirsEn', [])[:1]} - fav_dirs
    genres = t.get('genres', {})
    liked_g = {}
    for i in liked_films + listed:
        for g in movies.get(i, {}).get('g', []): liked_g[g] = liked_g.get(g, 0) + 1
    eras = set(t.get('eras', [])); regions = set(t.get('regions', [])); mood = set(t.get('mood', []))
    maxlen = t.get('maxlen') or 0
    out = []
    for i in pool:
        if i in anchors or i in rated or i not in movies: continue
        m = movies[i]; d = inf.get(i, {}); a = awards.get(i, {})
        if maxlen and m.get('m') and m['m'] > maxlen: continue
        sc = max(-1.0, min(1.0, (m['r'] - 7.0) / 1.5)) * 1.5; why = []
        if any(c in a for c in ('palme', 'oscar')): sc += 0.8
        elif a: sc += 0.4
        gs = [genres.get(g, 0) for g in m['g']]
        if any(x < 0 for x in gs): sc -= 2.0
        gp = [g for g in m['g'] if genres.get(g, 0) > 0]
        if gp: sc += 0.9 * len(gp); why.append((0.9 * len(gp), 'ваш жанр: ' + ', '.join(GENRE_UK.get(g, g) for g in gp[:2])))
        sim = sum(liked_g.get(g, 0) for g in m['g'])
        if sim: sc += min(1.2, 0.2 * sim)
        dl = [x for x in d.get('dirsEn', [])[:1] if x in fav_dirs]
        if dl:
            sc += 2.2
            src = why_dir.get(dl[0])
            why.append((2.2, ('режисер %s, як у «%s»' % ((d.get('dirs') or dl)[0], src)) if src else 'улюблений режисер ' + (d.get('dirs') or dl)[0]))
        if any(x in bad_dirs for x in d.get('dirsEn', [])[:1]): sc -= 1.5
        dec = '%ds' % (m['y'] // 10 * 10) if m['y'] else ''
        if dec in eras: sc += 0.7; why.append((0.7, 'ваша епоха: ' + dec))
        reg = [r for r in regions if set(d.get('countries', [])) & REGIONS.get(r, set())]
        if reg: sc += 0.7; why.append((0.7, {'hollywood': 'англомовне', 'europe': 'європейське', 'asia': 'азійське', 'ukraine': 'українське',
                                              'nordic': 'скандинавське', 'latam': 'латиноамериканське'}.get(reg[0], reg[0]) + ' кіно'))
        md = [x for x in mood if MOOD.get(x, set()) & set(m['g'])]
        if md: sc += 0.5
        if a: why.append((0.5, 'премія: ' + ', '.join(AWARD_NAME[c] for c in a)[:40]))
        if m['r'] >= 8.0: why.append((0.3, 'IMDb %.1f' % m['r']))
        out.append((sc, i, [w for _, w in sorted(why, key=lambda x: -x[0])[:2]]))
    out.sort(key=lambda x: -x[0])
    per_dir, picked, reasons = {}, [], {}
    for sc, i, why in out:
        dkey = (inf.get(i, {}).get('dirsEn') or [''])[0]
        if dkey and per_dir.get(dkey, 0) >= 3: continue
        per_dir[dkey] = per_dir.get(dkey, 0) + 1; picked.append(i); reasons[i] = why
        if len(picked) >= 150: break
    note = 'За вашим смаком: опитувальник, списки (%d), історія (%d), оцінені фільми (%d)' % (len(listed), len(seen_ids), len(rated))
    return picked, note, reasons


def seed():
    """The questionnaire's material: films to rate, directors to pick."""
    movies = load('movies.json', {})
    inf = info(SEED_FILMS)
    films = [{'imdb': i, 'title': inf.get(i, {}).get('uk') or movies.get(i, {}).get('t', i), 'year': movies.get(i, {}).get('y', 0),
              'poster': inf.get(i, {}).get('poster')} for i in SEED_FILMS]
    return {'films': films, 'directors': directors()[:36], 'genres': [[g, GENRE_UK[g]] for g in GENRE_UK]}


def lst(tab, param):
    movies = load('movies.json', {}); awards = load('awards.json', {}); new = load('new.json', [])
    if not movies: return {'error': 'Готую базу IMDb, спробуйте за хвилину', 'items': []}
    big = [i for i, m in movies.items() if m['v'] >= 25000 and m.get('k') != 's']
    score = weighted(movies, 25000)
    top250 = set(sorted(big, key=lambda i: -score(movies[i]))[:250])
    newset = {n['imdb'] for n in new}
    note = ''
    if tab == 'top': ids = sorted(big, key=lambda i: -score(movies[i]))[:100]
    elif tab == 'new': ids = [n['imdb'] for n in new][:80]
    elif tab == 'cannes':
        codes = ('palme',) if param == 'palme' else ('palme', 'cannes_gp', 'cannes_dir')
        ids = sorted([i for i, a in awards.items() if any(c in a for c in codes)], key=lambda i: -max(awards[i].get(c, 0) for c in codes))[:120]
    elif tab == 'festivals':
        code = param if param in AWARDS else 'oscar'
        ids = sorted([i for i, a in awards.items() if code in a], key=lambda i: -awards[i][code])[:120]
    elif tab == 'year':
        y = int(param) if (param or '').isdigit() else datetime.date.today().year - 1
        s5 = weighted(movies, 5000)
        ids = sorted([i for i, m in movies.items() if m['y'] == y and m['v'] >= 3000 and m.get('k') != 's'], key=lambda i: -s5(movies[i]))[:80]
    elif tab == 'genre':
        g = param or 'Drama'
        ids = sorted([i for i in big if g in movies[i]['g']], key=lambda i: -score(movies[i]))[:80]
    elif tab in ('director', 'dop'):
        # All films of one person: director (P57) or cinematographer (P344), by the English name.
        rows = sparql('SELECT DISTINCT ?imdb WHERE { ?d rdfs:label "%s"@en. ?f wdt:%s ?d; wdt:P345 ?imdb. }'
                      % ((param or '').replace('"', ''), 'P57' if tab == 'director' else 'P344'))
        ids = sorted([val(b, 'imdb') for b in rows if val(b, 'imdb') in movies], key=lambda i: -movies[i]['y'])
    elif tab == 'foryou':
        ids, note, reasons = for_you(movies, awards, new)
        if not note: return {'items': [], 'needTaste': True}
    elif tab == 'ids': ids = [i for i in (param or '').split(',') if i.startswith('tt')]
    else: return {'error': 'Немає такої вкладки', 'items': []}
    inf = info(ids)
    seen = seen_titles(); av = availability()
    items = [item(i, movies, awards, inf, top250, newset, seen, av) for i in ids]
    if tab == 'foryou':
        for x in items: x['why'] = reasons.get(x['imdb'], [])
    # Owner: only what can be watched. Checked and found = shown; not checked yet = "pending" for the core's checker.
    if not av:   # no source provider checks availability: show everything
        return {'items': items, 'pending': [], 'hidden': 0, 'total': len(items), 'note': note}
    ok = [x for x in items if x['av'] and (x['av']['rz'] or x['av']['tor'] > 0)]
    pending = [{'imdb': x['imdb'], 'title': x['title'], 'ru': x['ru'], 'orig': x['orig'], 'year': x['year']} for x in items if not x['av']]
    return {'items': ok, 'pending': pending, 'hidden': len(items) - len(ok) - len(pending), 'total': len(items), 'note': note}


def pool():
    """Everything the tabs can show, for the core's background availability check after "Оновити"."""
    movies = load('movies.json', {}); awards = load('awards.json', {}); new = load('new.json', [])
    ids = pool_ids(movies, awards, new); inf = info(ids); av = availability()
    stale = [i for i in ids if i not in av or time.time() - av[i].get('at', 0) > AVAIL_DAYS * 86400]
    return [{'imdb': i, 'title': inf.get(i, {}).get('uk') or movies[i]['t'], 'ru': inf.get(i, {}).get('ru') or '',
             'orig': inf.get(i, {}).get('en') or movies[i].get('o', ''), 'year': movies[i]['y']} for i in stale if i in movies]


def search(q):
    """Film search that doesn't depend on HDRezka: Wikidata (uk / ru / en names) + the IMDb index."""
    movies = load('movies.json', {})
    q = (q or '').strip()
    if not q: return {'items': []}
    # Local first, no network: IMDb titles (films and series) and the cached Ukrainian / Russian names.
    n = norm(q); words = [norm(w) for w in q.split() if len(norm(w)) >= 2]
    cache = load('info.json', {})
    def hit(names): return any(n and n in norm(x) for x in names if x) or (words and any(all(w in norm(x) for w in words) for x in names if x))
    local = [i for i, m in movies.items() if hit([m.get('t'), m.get('o')] + [cache.get(i, {}).get(k) for k in ('uk', 'ru', 'en')])]
    ids = sorted(local, key=lambda i: -movies[i]['v'])[:24]
    if ids:
        awards = load('awards.json', {}); new = load('new.json', [])
        inf = info(ids); seen = seen_titles(); av = availability()
        return {'items': [item(i, movies, awards, inf, set(), {x['imdb'] for x in new}, seen, av) for i in ids]}
    def claims_to_ids(qids):
        if not qids: return
        try:
            e = json.loads(http('https://www.wikidata.org/w/api.php?' + urllib.parse.urlencode(
                {'action': 'wbgetentities', 'ids': '|'.join(qids[:50]), 'props': 'claims', 'format': 'json'})))
        except Exception: return
        for qid in qids:
            c = e.get('entities', {}).get(qid, {}).get('claims', {}).get('P345', [])
            v = c and c[0].get('mainsnak', {}).get('datavalue', {}).get('value')
            if v and v.startswith('tt') and v not in ids: ids.append(v)
    # Full text first: words in any order, commas don't matter; only items with an IMDb id.
    try:
        d = json.loads(http('https://www.wikidata.org/w/api.php?' + urllib.parse.urlencode(
            {'action': 'query', 'list': 'search', 'srsearch': q + ' haswbstatement:P345', 'srlimit': 20, 'format': 'json'})))
        claims_to_ids([x['title'] for x in d.get('query', {}).get('search', [])])
    except Exception: pass
    for lang in ('uk', 'ru', 'en'):
        if len(ids) >= 12: break
        try:
            d = json.loads(http('https://www.wikidata.org/w/api.php?' + urllib.parse.urlencode(
                {'action': 'wbsearchentities', 'search': q, 'language': lang, 'uselang': lang, 'type': 'item', 'limit': 20, 'format': 'json'})))
            qids = [x['id'] for x in d.get('search', [])]
        except Exception: qids = []
        if qids:
            try:
                e = json.loads(http('https://www.wikidata.org/w/api.php?' + urllib.parse.urlencode(
                    {'action': 'wbgetentities', 'ids': '|'.join(qids), 'props': 'claims', 'format': 'json'})))
                for qid in qids:
                    c = e.get('entities', {}).get(qid, {}).get('claims', {}).get('P345', [])
                    v = c and c[0].get('mainsnak', {}).get('datavalue', {}).get('value')
                    if v and v.startswith('tt') and v not in ids: ids.append(v)
            except Exception: pass
    # Plain title match in the IMDb index too (English or original names).
    n = norm(q)
    if len(n) >= 3:
        hits = [i for i, m in movies.items() if norm(m.get('t')) == n or norm(m.get('o')) == n]
        ids += [i for i in sorted(hits, key=lambda i: -movies[i]['v'])[:8] if i not in ids]
    ids = [i for i in ids if i in movies][:24] or ids[:12]
    ids.sort(key=lambda i: -(movies.get(i, {}).get('v', 0)))
    awards = load('awards.json', {}); new = load('new.json', [])
    inf = info(ids); seen = seen_titles(); av = availability()
    return {'items': [item(i, movies, awards, inf, set(), {x['imdb'] for x in new}, seen, av) for i in ids]}


def directors():
    """Directors with festival wins: the "Режисери" tab's picker."""
    awards = load('awards.json', {})
    inf = info([i for i, a in awards.items() if 'palme' in a or 'oscar' in a or 'cannes_dir' in a][:300])
    count = {}
    for d in inf.values():
        for n in d.get('dirsEn', [])[:1]: count[n] = count.get(n, 0) + 1
    return sorted(count, key=lambda n: (-count[n], n))[:80]


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'build': build(); print('{"ok":true}')
    elif cmd == 'list': print(json.dumps(lst(sys.argv[2] if len(sys.argv) > 2 else 'top', sys.argv[3] if len(sys.argv) > 3 else ''), ensure_ascii=False))
    elif cmd == 'info': print(json.dumps(info(sys.argv[2:]), ensure_ascii=False))
    elif cmd == 'directors': print(json.dumps(directors(), ensure_ascii=False))
    elif cmd == 'pool': print(json.dumps(pool(), ensure_ascii=False))
    elif cmd == 'search': print(json.dumps(search(' '.join(sys.argv[2:])), ensure_ascii=False))
    elif cmd == 'seed': print(json.dumps(seed(), ensure_ascii=False))
    elif cmd == 'avail-path': print(path('avail.json'))
    else: print(__doc__); sys.exit(2)
