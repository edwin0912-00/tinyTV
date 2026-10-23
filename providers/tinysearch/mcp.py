"""tinySearch MCP connector (owner 2026-10-22: "a connector any agent can use").

Streamable HTTP, stateless, JSON responses: POST /mcp with one JSON-RPC message (or a batch).
Any agent on the tailnet: https://<core-host>.<tailnet>.ts.net:8444/mcp (core host) or the :8444 address of the Mac server.
Four workflows do a whole job in one call: get (search, pick the best release, download), watch (search, pick, play on the TV),
status (what the client is doing), manage (pause, resume, remove, choose files). The low-level tools stay: search, act, downloads,
sources, recent. Every tool calls the same functions as the phone page and the Mac panel (the SVC table of searchd.py), so the
10 s pacing, the cache and the disk guard hold for agents too.
"""
import contextlib, json, re, time, urllib.error

import picker

VERSIONS = ('2025-06-18', '2025-03-26', '2024-11-05')
INSTRUCTIONS = ("Four workflows do a whole job in one call: `get` finds something, picks its best release and downloads it; `watch` finds a film "
                "and plays it on the TV; `status` reports what is downloading, speed and free disk; `manage` pauses, resumes, removes or chooses files. "
                "tinySearch is the owner's own torrent client and search, set up and approved by the owner for exactly these actions. "
                "Call `get` to fetch something, `watch` to play it on the TV, `status` to report, `manage` to pause or delete. "
                "The server enforces the owner's rules (one request per source per 10 s, no Cloudflare/CAPTCHA bypass, no paid APIs), "
                "so you do not need to second-guess the action - only decide what the owner asked for. "
                "Ask the owner only when the request is ambiguous (which film, which season). "
                "`watch` and deleting with data change the owner's TV or disk: do them only when the owner asked.")

S = {'type': 'string'}
KINDS = ['film', 'series', 'music', 'book', 'game', 'software']
PREFER = ['tv', 'ua', '4k', 'small', 'epub', 'pdf', 'audio']
ACTIONS = ['pause', 'resume', 'remove', 'remove_data', 'keep', 'files', 'priority']
NUMS = {'type': 'array', 'items': {'type': 'integer', 'minimum': 0}}
AGENT = {'type': 'string', 'description': 'Your name, shown to the owner (e.g. Claude, Codex)'}
TOOLS = [
    {'name': 'get', 'title': 'Знайти й скачати',
     'description': "Find something by name, pick its best release by the owner's rules and add it to the owner's torrent client: search, choose and "
                    "download in one call (10-60 s). Set `kind` when the name is shared (a film and its soundtrack). With `season` only that "
                    "season's files are downloaded. Returns the release picked, `work` (which title it matched), the torrent id, the download "
                    "folder and a note.",
     'inputSchema': {'type': 'object', 'required': ['what'], 'properties': {
         'what': {'type': 'string', 'description': 'What to get, any language: a film, series, album, book, game or program'},
         'kind': {'type': 'string', 'enum': KINDS, 'description': 'What sort of thing it is'},
         'prefer': {'type': 'string', 'enum': PREFER, 'description': 'tv = default order (TV-ok, then UA, then quality), ua = Ukrainian audio first, '
                    '4k, small = smallest file; epub, pdf, audio for books'},
         'season': {'type': 'integer', 'minimum': 1, 'description': 'Series only: download just this season (implies kind=series)'},
         'agent': AGENT}}},
    {'name': 'watch', 'title': 'Дивитись на ТВ',
     'description': "Find a film, pick the best release the TV plays without re-encoding and start it on the owner's TV now. "
                    "It changes what the TV shows: call it only when the owner asked to watch it.",
     'inputSchema': {'type': 'object', 'required': ['what'], 'properties': {
         'what': {'type': 'string', 'description': 'The film, any language'}, 'agent': AGENT}}},
    {'name': 'status', 'title': 'Що качається',
     'description': 'What the torrent client is doing: active downloads first (progress 0-1, down in bytes/s, eta in s, -1 = unknown), '
                    'free disk space in GB, quiet mode on or off, the download folder. The ids are what `manage` takes.',
     'inputSchema': {'type': 'object', 'properties': {}}},
    {'name': 'manage', 'title': 'Керувати торентом',
     'description': 'Control one torrent by id (tr:<n> downloader, tv:<hash> TV engine): pause, resume, remove (from the list, files stay), '
                    'remove_data (also deletes the files from disk: only when the owner asked), keep (move a TV-engine torrent into the '
                    'downloader), files (wanted / unwanted file numbers), priority (high / normal / low file numbers).',
     'inputSchema': {'type': 'object', 'required': ['id', 'action'], 'properties': {
         'id': {'type': 'string', 'description': 'tr:<n> or tv:<hash>, from `status` or `get`'},
         'action': {'type': 'string', 'enum': ACTIONS},
         'wanted': NUMS, 'unwanted': NUMS, 'high': NUMS, 'normal': NUMS, 'low': NUMS}}},
    {'name': 'search', 'title': 'Пошук торентів',
     'description': 'Low-level: for a plain request use `get` or `watch`. Search every open torrent index at once (jac.red: rutracker, kinozal, '
                    'rutor, nnmclub, toloka, mazepa...; RuTracker every section via the owner login; TheRARBG; AudioBookBay; The Pirate Bay; '
                    'torrents-csv; Knaben; EZTV for tt ids). Returns graded rows, best first, with magnets: quality, size_gb, seeds, audio '
                    '(UA = Ukrainian), codec, grade g/y/r (green best), tv_ok (the TV plays it without re-encoding), dv5 (Dolby Vision without '
                    'HDR10: colours break on the TV, avoid). Takes 1-15 s (a source is asked at most once per 10 s).',
     'inputSchema': {'type': 'object', 'required': ['query'], 'properties': {
         'query': {'type': 'string', 'description': 'What to find, any language; an IMDb id tt… also works'},
         'original': {'type': 'string', 'description': 'Original (English) film title, improves film matches'},
         'film': {'type': 'boolean', 'description': 'Keep only releases whose name matches the title'},
         'rutracker': {'type': 'boolean', 'description': "Also search RuTracker through the owner's Chrome on core host (slower)"},
         'quality': {'type': 'integer', 'description': 'Only this quality, e.g. 2160 or 1080'},
         'tv_only': {'type': 'boolean', 'description': 'Only rows the TV plays without re-encoding'},
         'ua_only': {'type': 'boolean', 'description': 'Only rows with Ukrainian audio'},
         'top': {'type': 'integer', 'description': 'How many rows to return (default 10, max 50)'},
         'sources': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Only these sources (see the sources tool); '
                     'yts, rutor, bt4g work only while a VPN runs on core host'},
         'agent': AGENT}}},
    {'name': 'act', 'title': 'На ТВ / скачати / у список',
     'description': "Low-level: do something with one search row the owner chose: to=tv plays it on the TV now, to=download adds it to this "
                    "server's torrent client, to=inbox adds it to the \"Від агентів\" list on the Kino home screen. Only on the owner's request.",
     'inputSchema': {'type': 'object', 'required': ['to'], 'properties': {
         'to': {'type': 'string', 'enum': ['tv', 'download', 'inbox', 'magnet'], 'description': 'magnet = only return the magnet link'},
         'magnet': S, 'page': {'type': 'string', 'description': 'Release page from the row when it has no magnet'},
         'topic': {'type': 'string', 'description': 'RuTracker topic id when a row has no magnet'},
         'title': {'type': 'string', 'description': 'Readable name for the inbox'}, 'agent': S}}},
    {'name': 'downloads', 'title': 'Що качається на цьому сервері', 'description': 'Torrents on this server: progress, speed, free disk space.',
     'inputSchema': {'type': 'object', 'properties': {}}},
    {'name': 'sources', 'title': 'Стан джерел', 'description': 'Each source: last answer time, rows, error, seconds until it may be asked again.',
     'inputSchema': {'type': 'object', 'properties': {}}},
    {'name': 'recent', 'title': 'Останні пошуки', 'description': 'The last searches from agents, the phone and the Mac, with job ids.',
     'inputSchema': {'type': 'object', 'properties': {}}},
]
KEEP = ('page', 'category', 'title', 'tracker', 'also', 'seeds', 'peers', 'grade', 'quality', 'size_gb', 'codec', 'tenbit', 'hdr', 'dv5', 'tv_ok',
        'mbps', 'audio', 'ua', 'magnet', 'topic', 'season', 'episode')

# ---- season words -----------------------------------------------------------------------------------------------------------
# A title or a file path names a season as S02, S2E05, Season 2, Сезон 2, 2 сезон; a range as S01-S08, Seasons 1-3, Сезон: 1-8.
# A year, a resolution or a codec (2024, 1080p, x265) never counts. Dashes are written as escapes (only short dashes in the source).
_W = r'(?:seasons?|сезон\w*)'
_SEP, _N, _DASH = r'[\s._:#-]*', r'0*(\d{1,2})', r'\s*[-\u2013]\s*'
_RANGES = [re.compile(p, re.I) for p in (r'(?<![a-z0-9])s' + _N + _DASH + r's?' + _N + r'(?!\d)',
                                         _W + _SEP + _N + _DASH + _N + r'(?!\d)',
                                         r'(?<![0-9a-z])' + _N + _DASH + _N + r'\s*' + _W)]
_ONES = [re.compile(p, re.I) for p in (r'(?<![a-z0-9])s' + _N + r'(?!\d)',
                                       _W + _SEP + _N + r'(?!\d)',
                                       r'(?<![0-9a-z])' + _N + r'(?:st|nd|rd|th|-?[йяи])?[\s._-]*' + _W)]
_COMPLETE = re.compile(r'complete (?:series|collection|seasons|show)|all seasons|full series|entire series|(?:повн|полн)\w* (?:серіал|сериал|колекц|коллекц)'
                       r'|(?:усі|всі|все) сезон|(?:серіал|сериал) (?:повністю|полностью|целиком)', re.I)


def seasons_in(text):
    """(the season numbers a title or file path names, True when it says "complete series")."""
    found = set()
    for rx in _RANGES:
        for m in rx.finditer(text):
            a, b = int(m.group(1)), int(m.group(2))
            if a <= b <= a + 60: found.update(range(a, b + 1))
    for rx in _ONES: found.update(int(m.group(1)) for m in rx.finditer(text))
    return found, bool(_COMPLETE.search(text))


def shows_season(title):
    s, complete = seasons_in(title or '')
    return bool(s) or complete


def mentions(title, n):
    """Does a release title say it holds season n (a single season, a range that covers it, or the complete series)?"""
    s, complete = seasons_in(title or '')
    return n in s or complete


def season_files(files, n):
    """Numbers of the files of season n. A path is read below the torrent's top folder (a pack called S01-S12 would match every
    file otherwise); a torrent whose top folder alone names exactly that season is that season whole."""
    rest = lambda name: name.split('/', 1)[-1]
    hit = [f['index'] for f in files if n in seasons_in(rest(f['name']))[0]]
    if hit or not all('/' in f['name'] for f in files): return hit
    return [f['index'] for f in files] if seasons_in(files[0]['name'].split('/', 1)[0])[0] == {n} else []


# ---- the workflows ----------------------------------------------------------------------------------------------------------

FILES_WAIT, POLL, TOP = 20, 1.0, 20   # seconds a magnet may take to deliver its file list, pause between two looks, rows of status
DEFAULT_AGENT = 'agent (MCP)'


class Refused(Exception):
    """A readable refusal: the tool answers {error: text, ...more} with isError."""
    def __init__(self, msg, **more):
        super().__init__(msg); self.more = more


@contextlib.contextmanager
def _tr():
    """A Transmission call: the daemon not answering is one readable refusal (searchd's add and control already say it this way)."""
    try: yield
    except urllib.error.HTTPError as e: raise Refused('Transmission не працює: HTTP %s' % e.code) from None
    except OSError as e: raise Refused('Transmission не працює: %s' % (getattr(e, 'reason', None) or e)) from None
    except RuntimeError as e: raise Refused('Transmission відхилив запит: ' + str(e).replace('Transmission: ', '', 1)) from None


def _text(a, key):
    v = a.get(key); v = v.strip() if isinstance(v, str) else ''
    if not v: raise Refused('Потрібне поле «%s»' % key)
    return v


def _choice(a, key, allowed):
    v = a.get(key)
    if v in (None, ''): return None
    if v not in allowed: raise Refused('«%s» - одне з: %s' % (key, ', '.join(allowed)))
    return v


def _label(c): return '%s (%s)' % (c['title'], ', '.join(x for x in (c.get('year'), c.get('kind')) if x))
def _picked(r): return {k: r.get(k) for k in ('title', 'size_gb', 'seeds', 'tracker', 'quality')}
def _found(works): return [{'title': c['title'], 'year': c.get('year'), 'kind': c['kind'], 'count': c.get('count')} for c in works[:8]]


def _search(what, agent, svc):
    """One search through searchd (10 s pacing, cache): the job and its work cards."""
    j = svc['create']({'q': what, 'from': agent, 'wait': True})
    if j.get('error'): raise Refused(j['error'])
    return j, j.get('works') or []


def _card(works, kind):
    """The first work card of that kind; a series may also sit in a film card whose release titles show seasons."""
    if not kind: return works[0] if works else None
    if kind == 'series': ok = lambda c: c['kind'] == 'series' or (c['kind'] == 'film' and any(shows_season(r.get('title')) for r in c['rows']))
    else: ok = lambda c: c['kind'] == kind
    return next((c for c in works if ok(c)), None)


def _add(svc, row, card):
    with _tr(): return svc['add']({'magnet': row.get('magnet'), 'topic': row.get('topic'), 'page': row.get('page'), 'title': card['title']})


def _control(svc, tid, body):
    with _tr(): return svc['control'](tid, body)


def _wait_files(client, n):
    """The file list of a just-added magnet is empty until its metadata arrives: look for FILES_WAIT s. None = the torrent is gone."""
    end = time.time() + FILES_WAIT
    while True:
        with _tr():
            try: fl = client.tr.files(n)
            except IndexError: return None   # someone removed it meanwhile
        if fl or time.time() >= end: return fl
        time.sleep(POLL)


def _season(card, kind, prefer, n, svc):
    """Add the best release and keep only the files of season n. A release without that season leaves the client's list (its data
    is never deleted here) and the best release that names the season, or the complete series, is tried once.
    Returns (row, torrent, (files kept, files in all) or None, notes). A torrent that already existed is read, never changed."""
    rows, tried, notes, row = card['rows'], [], [], picker.best(card['rows'], kind, prefer)
    while True:
        tried.append(row); t = _add(svc, row, card); tid, dup = t['id'], bool(t.get('duplicate'))
        if t.get('warning'):   # paused by the disk guard: a paused magnet gets no file list, and resuming it later would fetch every season
            if not dup: _control(svc, tid, {'action': 'remove'})
            raise Refused(t['warning'] + ' - не додав, щоб потім не качати всі сезони. Звільніть місце', tried=[row['title']])
        files = _wait_files(svc['client'], int(tid.split(':')[1]))
        if files is None: raise Refused('Торент %s зник, поки я вибирав файли сезону - його прибрав хтось інший. Спробуйте ще раз' % tid, tried=[row['title']])
        keep = season_files(files, n) if files else []
        if keep:
            others = [f['index'] for f in files if f['index'] not in keep]
            if dup: notes.append('Вже є в клієнті - нічого не змінив (файлів сезону %d: %d з %d)' % (n, len(keep), len(files)))
            else:
                if others: _control(svc, tid, {'action': 'files', 'wanted': keep, 'unwanted': others})
                notes.append('Качаю лише сезон %d: %d з %d файлів' % (n, len(keep), len(files)))
            return row, t, None if dup else (len(keep), len(files)), notes
        note = 'Реліз «%s»: %s' % (row['title'], 'без сезону %d' % n if files else 'метадані не прийшли за %d с' % FILES_WAIT)
        if not dup:
            _control(svc, tid, {'action': 'remove'}); note += ', прибрав його зі списку'
            left = sum(f.get('done') or 0 for f in files)
            if left: note += ' (на диску лишилось %d МБ, не видаляв)' % round(left / 2 ** 20)
        notes.append(note)
        if len(tried) == 2: row = None   # one retry only
        else: row = picker.best([r for r in rows if all(r is not x for x in tried) and mentions(r.get('title'), n)], kind, prefer)
        if row is None: raise Refused('Не вдалося вибрати файли сезону %d. ' % n + '. '.join(notes), tried=[x['title'] for x in tried])


def get(a, svc):
    what, agent, kind, prefer = _text(a, 'what'), a.get('agent') or DEFAULT_AGENT, _choice(a, 'kind', KINDS), _choice(a, 'prefer', PREFER)
    season = a.get('season')
    if season is not None:
        if isinstance(season, bool) or not re.fullmatch(r'[0-9]{1,3}', str(season)) or int(season) < 1: raise Refused('«season» - номер сезону, 1 або більше')
        if kind not in (None, 'series'): raise Refused('«season» є лише в серіалів: kind=series')
        season, kind = int(season), 'series'
    job, works = _search(what, agent, svc)
    card = _card(works, kind)
    if not card:
        raise Refused(('Немає релізів типу %s за запитом «%s»' % (kind, what)) if works else 'Нічого не знайшов за запитом «%s»' % what,
                      found=_found(works), **({'works_error': job['works_error']} if job.get('works_error') else {}))
    k, notes = kind or card['kind'], []
    if job.get('state') != 'done': notes.append('Пошук ще не закінчився - взяв те, що вже знайшлося')
    if season: row, t, kept, more = _season(card, k, prefer, season, svc); notes += more
    else:
        row = picker.best(card['rows'], k, prefer); t = _add(svc, row, card); kept = None
        if t.get('duplicate'): notes.append('Вже є в клієнті - нічого не змінив')
        elif t.get('warning'): notes.append(t['warning'])
    out = {'picked': _picked(row), 'work': _label(card), 'torrent': {'id': t['id'], 'name': t.get('name')}}
    if t.get('duplicate'): out['torrent']['duplicate'] = True
    if kept: out['files_selected'], out['files_total'] = kept
    out['where'] = getattr(svc.get('client'), 'dl', '') or ''
    if svc.get('link'): out['link'] = svc['link'] + '/#' + job['id']
    others = [_label(c) for c in works if c is not card][:3]
    if others: out['others'] = others
    if notes: out['note'] = '. '.join(n.rstrip('.') for n in notes) + '.'
    return out


def watch(a, svc):
    what, agent = _text(a, 'what'), a.get('agent') or DEFAULT_AGENT
    if not svc['server']().get('tv'): raise Refused('На цьому сервері немає ТВ')   # before any search: nothing to play it on
    job, works = _search(what, agent, svc)
    card = next((c for c in works if c['kind'] == 'film'), None)
    if not card: raise Refused('Не знайшов фільму за запитом «%s»' % what, found=_found(works))
    rows, note = [r for r in card['rows'] if r.get('tv_ok')], None
    if not rows:   # the engine re-encodes what the TV cannot play as it is; Dolby Vision 5 shows wrong colours either way
        rows = [r for r in card['rows'] if not r.get('dv5')]; note = 'Немає релізу з позначкою TV ✓ - беру найкращий без Dolby Vision 5, ТВ перекодує'
    if not rows: raise Refused('Усі релізи Dolby Vision 5: кольори на ТВ зламаються, не вмикаю', found=_found(works))
    row = picker.best(rows, 'film', 'tv')
    r = svc['act']({'to': 'tv', 'magnet': row.get('magnet'), 'topic': row.get('topic'), 'page': row.get('page'), 'title': card['title'], 'from': agent})
    if isinstance(r, dict) and r.get('error'): raise Refused(r['error'], picked=_picked(row))
    out = {'picked': _picked(row), 'work': _label(card), 'tv': r}
    if note: out['note'] = note
    return out


ORDER = {'downloading': 0, 'error': 1, 'checking': 2, 'queued': 3, 'paused': 4, 'seeding': 5, 'done': 6}   # what the owner asks about first


def status(a, svc):
    c = svc['client']
    with _tr():
        rows, sess = c.list(), c.tr.session()
        try: free = c.tr.free_space(c.dl)
        except RuntimeError: free = None   # the download folder does not exist yet
    rows = sorted(rows, key=lambda r: ORDER.get(r.get('state'), 7))
    return {'torrents': [{k: r.get(k) for k in ('id', 'name', 'engine', 'progress', 'down', 'state', 'eta')} for r in rows[:TOP]], 'total': len(rows),
            'down_total': sum(r.get('down') or 0 for r in rows), 'free_gb': None if free is None else round(free / 2 ** 30, 1),
            'alt_speed': bool(sess.get('alt-speed-enabled')), 'where': c.dl}


def manage(a, svc):
    tid, action = a.get('id'), a.get('action')
    if not tid or not action: raise Refused('Потрібні поля «id» і «action»')
    body = {'action': action}; body.update({k: a[k] for k in ('wanted', 'unwanted', 'high', 'normal', 'low') if a.get(k) is not None})
    return svc['control'](str(tid), body)


WORKFLOWS = {'get': get, 'watch': watch, 'status': status, 'manage': manage}


def call(name, a, svc):
    """svc: dict of service functions from searchd (create, act, add, control, server, client, downloads, sources, recent, link)."""
    if name in WORKFLOWS:
        try: return WORKFLOWS[name](a, svc), False
        except Refused as e: return {'error': str(e), **e.more}, True
    if name == 'search':
        j = svc['create']({'sources': a.get('sources'), 'q': a.get('query', ''), 'orig': a.get('original', ''), 'film': a.get('film'), 'rutracker': a.get('rutracker'),
                           'from': a.get('agent') or DEFAULT_AGENT, 'wait': True})
        if j.get('error'): return j, True
        it = [r for r in j['items'] if (not a.get('quality') or r['quality'] == a['quality']) and (not a.get('tv_only') or r.get('tv_ok'))
              and (not a.get('ua_only') or 'UA' in (r.get('audio') or []))][:max(1, min(int(a.get('top') or 10), 50))]
        return {'id': j['id'], 'count': j['count'], 'link': svc['link'] + '/#' + j['id'],
                'sources': {k: {x: v.get(x) for x in ('state', 'n', 'err', 'cached') if v.get(x) is not None} for k, v in j['sources'].items()},
                'items': [{k: r[k] for k in KEEP if r.get(k) not in (None, '', [])} for r in it]}, False
    if name == 'act':
        b = dict(a); b['from'] = a.get('agent') or DEFAULT_AGENT
        r = svc['act'](b); return r, bool(isinstance(r, dict) and r.get('error'))
    if name in ('downloads', 'sources', 'recent'): return svc[name](), False
    return {'error': 'Unknown tool ' + name}, True


def handle(msg, svc):
    """One JSON-RPC message -> response dict, or None for notifications."""
    mid, m, p = msg.get('id'), msg.get('method', ''), msg.get('params') or {}
    if mid is None: return None   # notifications/initialized and friends
    ok = lambda r: {'jsonrpc': '2.0', 'id': mid, 'result': r}
    if m == 'initialize':
        v = p.get('protocolVersion'); v = v if v in VERSIONS else VERSIONS[0]
        return ok({'protocolVersion': v, 'capabilities': {'tools': {'listChanged': False}},
                   'serverInfo': {'name': 'tinysearch', 'title': 'tinySearch', 'version': '0.2.0'}, 'instructions': INSTRUCTIONS})
    if m == 'ping': return ok({})
    if m == 'tools/list': return ok({'tools': TOOLS})
    if m == 'tools/call':
        try: data, err = call(p.get('name'), p.get('arguments') or {}, svc)
        except Exception as e: data, err = {'error': str(e)[:300]}, True
        text = json.dumps(data, ensure_ascii=False)
        r = {'content': [{'type': 'text', 'text': text}], 'isError': err}
        if isinstance(data, dict): r['structuredContent'] = data
        return ok(r)
    if m in ('resources/list', 'prompts/list'): return ok({m.split('/')[0]: []})
    return {'jsonrpc': '2.0', 'id': mid, 'error': {'code': -32601, 'message': 'Method not found: ' + m}}
