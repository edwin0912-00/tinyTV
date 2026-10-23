#!/usr/bin/env python3
"""searchd - torrent search and client service, one per Mac (owner 2026-10-22: core host and this Mac).

One queue for every client: agents ("пошукай в інтернеті"), the phone page, the Mac panel, the CLI.
A job is a small pipeline of nodes: sources (in parallel) -> merge by hash -> describe -> grade -> work cards -> result.
Owner rules: one request per source per search, never faster than once per 10 s per source, no background crawl,
no Cloudflare/Anubis/CAPTCHA bypass, no paid APIs. Repeated queries come from a 10 min cache.
Downloads go to Transmission (trclient.py); watching goes to the TV Cast engine and the tinyTV core. config.json
(hostcfg.py; the file named by SEARCHD_CONFIG wins) says what this host has. Importing this module binds nothing.

  POST /api/jobs   {q, orig?, film?, imdb?, rutracker?, from?, wait?}  -> job with items, works (cards) and per-row `have`
  GET  /api/jobs                -> recent jobs (no items)      GET /api/jobs/<id> -> one job
  GET  /api/sources             -> health of every source      GET /api/server -> {name, public_url, tv, peers, vpn_sources}
  GET  /api/torrents            -> one list: Transmission (id tr:<n>) + TV Cast engine (id tv:<hash>)
  GET  /api/torrents/<id>/files -> files of a Transmission torrent (index, name, size, done, wanted, priority)
  POST /api/torrents/add        {magnet|page|topic, files?: [idx], paused?, title?} -> {id, hash, name, duplicate[, warning]}
  POST /api/torrents/<id>       {action: pause|resume|remove|remove_data|keep|files|priority, wanted?, unwanted?, high?, normal?, low?}
  GET|POST /api/client          {alt_speed, speed_down, speed_up, ratio, idle_min} + free_gb (Transmission session settings)
  GET  /api/downloads           -> the same list in the old shape {free, folder, torrents}
  POST /api/act    {to: tv|download|inbox|magnet, magnet?, page?, topic?, title?, from?}
  POST /mcp                     -> MCP connector (mcp.py)         GET / -> search.html (phone and browser)
Errors are {"error": text}: 400 bad request, 404 unknown id, 409 no TV here, 502 Transmission or a peer does not answer.
Python 3.9 standard library; tsearch.py (the shared skill script) sits next to this file.
"""
import contextlib, json, os, re, subprocess, sys, threading, time, urllib.error, urllib.request, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import group, hostcfg, torrents, tsearch, mcp  # noqa: E402

CFG, PORT, CORE, ENGINE, CLIENT = None, 8896, None, None, None   # all set from config.json by configure() below
STATE = os.path.expanduser('~/Library/Application Support/tinySearch/jobs.json')
GAP, CACHE_TTL, KEEP = 10.0, 600, 60
LOW_DISK = 10 * 2 ** 30   # below this much free space a new download starts paused (spec: errors)
FILES_WAIT = 20           # seconds a magnet may take to deliver its file list when the caller wants paused / files

# name -> (label, what it covers, function(q, orig, job))
SOURCES = {
    'jacred': ('jac.red', 'rutracker, kinozal, rutor, nnmclub, toloka, mazepa…', lambda j: tsearch.jacred(j['q'], j['orig'])),
    'apibay': ('The Pirate Bay', 'apibay.org', lambda j: tsearch.apibay(j['q'], j['orig'])),
    'torrentscsv': ('torrents-csv', 'DHT index', lambda j: tsearch.torrentscsv(j['q'], j['orig'])),
    'knaben': ('Knaben', '1337x, Nyaa, YTS, TPB…', lambda j: tsearch.knaben(j['q'], j['orig'])),
    'eztv': ('EZTV', 'serials by IMDb id', lambda j: tsearch.eztv(j['q'], j['orig'], j.get('imdb', ''))),
    'rutracker': ('RuTracker', "every section, owner's Chrome on core host", lambda j: rutracker(j['orig'] or j['q'])),
    'therarbg': ('TheRARBG', 'films, series, books, games, software', lambda j: tsearch.therarbg(j['q'], j['orig'])),
    'audiobookbay': ('AudioBookBay', 'audiobooks', lambda j: tsearch.audiobookbay(j['q'], j['orig'])),
    'nyaa': ('Nyaa', 'anime, manga, books, music', lambda j: tsearch.nyaa(j['q'], j['orig'])),
    'limetorrents': ('LimeTorrents', 'games, software, films, music', lambda j: tsearch.limetorrents(j['q'], j['orig'])),
    # only while a VPN runs on core host (owner 2026-10-22); without it they fail fast and show as an error chip
    'yts': ('YTS', 'films, small encodes (VPN)', lambda j: tsearch.yts(j['q'], j['orig'])),
    'rutor': ('rutor', 'films, music, software, books (VPN)', lambda j: tsearch.rutor(j['q'], j['orig'])),
    'bt4g': ('BT4G', 'DHT search, no seeders (VPN)', lambda j: tsearch.bt4g(j['q'], j['orig'])),
}
# yts, rutor, bt4g answer only through a VPN, and through it rutracker.org shows a Cloudflare check: off by default
# (owner 2026-10-22). Ask for them explicitly: {"sources": [..., "yts", "rutor", "bt4g"]}.
DEFAULT = ['jacred', 'rutracker', 'apibay', 'torrentscsv', 'knaben', 'therarbg', 'limetorrents', 'nyaa', 'audiobookbay']
NODE = '/opt/homebrew/bin/node'


def rt(*args):   # rutracker.mjs: the request runs inside the owner's logged-in rutracker.org tab (no Cloudflare bypass)
    r = subprocess.run([NODE, os.path.join(HERE, 'rutracker.mjs'), *args], capture_output=True, text=True, timeout=30)
    d = json.loads(r.stdout or 'null')
    if d is None or (isinstance(d, dict) and d.get('error')): raise RuntimeError((d or {}).get('error') or r.stderr[-200:] or 'RuTracker: порожня відповідь')
    return d


def rutracker(q):
    return [tsearch.row(t['title'], t['bytes'], t['seeds'], t['peers'], 'rutracker', '', topic=t['topic'], category=t.get('forum'),
                        url='https://rutracker.org/forum/viewtopic.php?t=' + t['topic']) for t in rt('search', q)]

gates = {s: threading.Lock() for s in SOURCES}
health = {s: {'last': 0.0, 'ms': None, 'ok': None, 'err': '', 'n': None} for s in SOURCES}
cache, jobs, jlock = {}, {}, threading.Lock()


def load():
    try:
        for j in json.load(open(STATE)): jobs[j['id']] = j
    except Exception: pass


def save():
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with jlock: data = sorted(jobs.values(), key=lambda j: j['created'])[-KEEP:]
    tmp = STATE + '.tmp'
    with open(tmp, 'w') as f: json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, STATE)


def fetch(src, job):
    """One request to one source, through its 10 s gate; the same query within 10 min comes from the cache."""
    key = (src, job['q'].lower().strip(), job['orig'].lower().strip(), job.get('imdb', ''))
    hit = cache.get(key)
    if hit and time.time() - hit[0] < CACHE_TTL: return hit[1], True
    with gates[src]:   # queued jobs wait here; the gate is the only pacing, there is no retry loop
        wait = GAP - (time.time() - health[src]['last'])
        if wait > 0:
            job['sources'][src]['state'] = 'wait'; time.sleep(wait)
        job['sources'][src]['state'] = 'run'
        t = time.time(); health[src]['last'] = t
        try:
            rows = SOURCES[src][2](job)
            health[src].update(ok=True, err='', ms=int((time.time() - t) * 1000), n=len(rows))
            cache[key] = (time.time(), rows); return rows, False
        except Exception as e:
            health[src].update(ok=False, err=str(e)[:120], ms=int((time.time() - t) * 1000)); raise


def publish(job, items):
    """Put merged rows into the job: a row whose hash is already in the client gets `have`, and the rows are folded into
    work cards (top 30, each with at most 40 rows). Rows are copied: the originals sit in the 10 min cache and keep no mark."""
    try: hv = CLIENT.have([r.get('hash') for r in items])
    except Exception: hv = {}   # Transmission is down: the search still works, its rows just have no mark
    rows = [dict(r, have=hv[r['hash'].lower()]) if r.get('hash') and r['hash'].lower() in hv else dict(r) for r in items]
    try: works = [dict(w, rows=w['rows'][:40]) for w in group.works(rows)[:30]]
    except Exception as e: works = []; job['works_error'] = str(e)[:120]   # a grouping bug must not hide the rows
    with jlock: job['count'] = len(rows); job['items'] = rows[:80]; job['works'] = works


def run(job):
    lists, names = {}, [tsearch.norm(x) for x in (job['q'], job['orig']) if x] if job['film'] else []

    def merged():   # jac.red indexes only video: if it found the title, this is a film or a series and quality ranks first
        return tsearch.merge([lists[s] for s in job['sources'] if s in lists], names, video=bool(lists.get('jacred')) or job['film'])

    def one(src):
        st = job['sources'][src]; t = time.time()
        try:
            rows, cached = fetch(src, job)
            # Owner 2026-10-22: a Latin title that RuTracker does not know gets ONE more request with its Russian
            # translation, through the same 10 s gate ("Under Saturn's Shadow" -> "Под тенью Сатурна").
            if src == 'rutracker' and not rows and re.search(r'[A-Za-z]', job['q']) and not re.search(r'[А-Яа-яІіЇїЄєҐґ]', job['q']):
                ru = tsearch.translate(job['orig'] or job['q'])
                if ru and re.search(r'[А-Яа-я]', ru):
                    st['translated'] = ru; rows, cached = fetch(src, dict(job, q=ru, orig=''))
            lists[src] = rows
            st.update(state='ok', n=len(rows), cached=cached)
        except Exception as e:
            st.update(state='err', err=str(e)[:120])
        st['ms'] = int((time.time() - t) * 1000)
        publish(job, merged())
    ts = [threading.Thread(target=one, args=(s,), daemon=True) for s in job['sources']]
    for t in ts: t.start()
    for t in ts: t.join()
    # the final merge: sources finish in any order (cached ones within milliseconds), so a progressive merge can land last
    try: publish(job, merged())
    except Exception: pass   # keep what the progressive merges produced
    job['state'] = 'done'; job['ms'] = int((time.time() - job['created']) * 1000); save()


def create(b):
    q = re.sub(r'^\s*(пошукай|знайди|шукай)( в інтернеті| в мережі| торент(ом)?)?\s*[:,-]?\s*', '', (b.get('q') or '').strip(), flags=re.I)
    if not q: return {'error': 'Порожній запит'}
    srcs = [s for s in (b.get('sources') or DEFAULT) if s in SOURCES]
    if b.get('imdb') or re.search(r'tt\d{5,9}', q): srcs.append('eztv')
    if b.get('rutracker') and 'rutracker' not in srcs: srcs.append('rutracker')
    job = {'id': uuid.uuid4().hex[:8], 'q': q, 'orig': (b.get('orig') or '').strip(), 'film': bool(b.get('film')),
           'imdb': b.get('imdb') or '', 'from': (b.get('from') or 'web')[:40], 'created': time.time(), 'state': 'run',
           'count': 0, 'items': [], 'sources': {s: {'state': 'queue', 'label': SOURCES[s][0]} for s in dict.fromkeys(srcs)}}
    with jlock: jobs[job['id']] = job
    th = threading.Thread(target=run, args=(job,), daemon=True); th.start()
    if b.get('wait'): th.join(90)
    return job


def summary(j):
    top = j['items'][0] if j.get('items') else None
    return {k: j.get(k) for k in ('id', 'q', 'from', 'created', 'state', 'count', 'ms')} | \
        {'top': top and {k: top.get(k) for k in ('title', 'quality', 'seeds', 'size_gb', 'tv_ok')}}


def post(url, data, timeout=30):
    r = urllib.request.Request(url, data=json.dumps(data).encode(), headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(r, timeout=timeout) as x: return json.loads(x.read() or b'{}')


class Bad(Exception):
    """A refusal with a readable reason and an HTTP code: the handler sends {'error': reason}, MCP shows the text."""
    def __init__(self, msg, code=400):
        super().__init__(msg); self.code = code


@contextlib.contextmanager
def trerr():
    """Wrap every Transmission call: the daemon not answering is one readable 502, a request it refuses is a 400."""
    try: yield
    except urllib.error.HTTPError as e: raise Bad('Transmission не працює: HTTP %s' % e.code, 502) from None
    except OSError as e: raise Bad('Transmission не працює: %s' % (getattr(e, 'reason', None) or e), 502) from None
    except RuntimeError as e: raise Bad('Transmission відхилив запит: ' + str(e).replace('Transmission: ', '', 1), 400) from None


def tv_peer():
    """The tinySearch of another host, asked to play on its TV when this host has no tinyTV core (spec: errors)."""
    return next((p['url'].rstrip('/') for p in CFG['peers'] if isinstance(p, dict) and p.get('url')), '')


def magnet_of(b, by_topic=True):
    """The magnet of the row the owner chose: sent with it, or fetched now from its release page (therarbg, audiobookbay)
    or RuTracker topic - once, only for the row that was picked."""
    m = b.get('magnet') or ''
    if not m and b.get('page'): m = tsearch.resolve(b['page'])
    if not m and by_topic and b.get('topic'): m = rt('magnet', str(b['topic'])).get('magnet', '')
    return m


def core_call(to, path, data, b, m):
    """tv / inbox: the tinyTV core on this host. A host without one asks the first peer's tinySearch, whose /api/act reaches
    its core; `hop` marks that forwarded call so two hosts without a core never bounce it between them."""
    if CORE: return post(CORE + path, data)
    peer = tv_peer()
    if not peer or b.get('hop'): raise Bad('На цьому сервері немає ТВ', 409)
    body = {k: v for k, v in (('to', to), ('magnet', m), ('topic', b.get('topic')), ('title', b.get('title')),
                              ('from', b.get('from') or 'search'), ('hop', 1)) if v}
    try: return post(peer + '/api/act', body, timeout=40)
    except urllib.error.HTTPError as e:   # the peer answered {error} with 4xx/5xx: pass its reason on
        try: return json.loads(e.read())
        except ValueError: raise Bad('Сервер-сусід: HTTP %s' % e.code, 502) from None
    except OSError as e: raise Bad('Сервер-сусід не відповідає: %s' % (getattr(e, 'reason', None) or e), 502) from None


def act(b):
    """download = Transmission on this host; tv / inbox = the tinyTV core, through a peer when this host has none."""
    to = b.get('to')
    if to == 'download': return add(b)
    m = magnet_of(b, by_topic=to != 'tv')   # a RuTracker topic goes to the core as it is for tv; the others need the magnet
    if to == 'magnet': return {'magnet': m} if m else {'error': 'Не знайшов магнет'}
    if not m and not b.get('topic'): return {'error': 'Не знайшов магнет'}
    if to == 'tv': return core_call(to, '/api/kino/torrent/use', {'magnet': m, 'from': b.get('from', 'search')} if m else {'topic': b.get('topic')}, b, m)
    if to == 'inbox': return core_call(to, '/api/kino/inbox', {'add': {'title': b.get('title') or 'Торент', 'magnet': m, 'from': b.get('from', 'search')}}, b, m)
    return {'error': 'Невідома дія'}


def idx(v):
    """A JSON list of file numbers, or None."""
    if v is None: return None
    if not isinstance(v, list) or any(not isinstance(i, int) or isinstance(i, bool) or i < 0 for i in v): raise Bad('Файли - це список номерів')
    return v


def parse_id(tid):
    """'tr:12' -> ('tr', 12); 'tv:<40 hex>' -> ('tv', hash). Anything else is refused: the hash goes into an engine URL."""
    kind, _, ref = str(tid).partition(':')
    if kind == 'tr' and re.fullmatch(r'[0-9]{1,9}', ref): return kind, int(ref)
    if kind == 'tv' and re.fullmatch(r'[0-9a-f]{40}', ref): return kind, ref
    raise Bad('Невідомий id: ' + str(tid)[:60], 404)


def free_bytes():
    """Free space of the download folder; None when Transmission cannot tell (the folder is not created yet)."""
    try: return CLIENT.tr.free_space(CFG['download_dir'])
    except RuntimeError: return None


def wait_files(tid):
    """The file list of a just-added magnet is empty until its metadata arrives (seconds): poll for at most FILES_WAIT s."""
    end = time.time() + FILES_WAIT
    while True:
        try: fl = CLIENT.tr.files(tid)
        except IndexError: return []   # removed meanwhile
        if fl or time.time() >= end: return fl
        time.sleep(0.5)


def settle(tid, stopping):
    """torrent-stop lands about 0.2 s late (measured, Transmission 4.1.3) and a start sent before it lands is lost, so after
    a stop wait until the torrent reads stopped (3 s at most). Returns its row; the real name comes with the metadata."""
    end = time.time() + 3
    while True:
        row = CLIENT.tr.list([tid])
        if not stopping or not row or row[0]['state'] in ('paused', 'error', 'done') or time.time() >= end: return row
        time.sleep(0.05)


def add(b):
    """POST /api/torrents/add {magnet|page|topic, files?: [idx to download], paused?, title?} -> {id, hash, name, duplicate[, warning]}.
    A paused magnet never fetches its file list (measured, Transmission 4.1.3), so `paused` or `files` first start the
    torrent, wait for the list (FILES_WAIT s), apply the selection and stop it again. Under 10 GB free it is added paused."""
    m = magnet_of(b).strip()
    if not m: raise Bad('Не знайшов магнет')
    if not m.lower().startswith('magnet:?'): raise Bad('Це не магнет')
    pick, paused, out = idx(b.get('files')), bool(b.get('paused')), {}
    with trerr():
        free = free_bytes(); low = free is not None and free < LOW_DISK
        t = CLIENT.tr.add(m, download_dir=CLIENT.dl, paused=low)
        if low and not t['duplicate']: out['warning'] = 'Менше 10 ГБ вільно - поставив на паузу'
        if not low and not t['duplicate'] and (paused or pick):
            fl = wait_files(t['id']); want = [f['index'] for f in fl if f['index'] in (pick or [])]
            if want: CLIENT.tr.set_files(t['id'], wanted=want, unwanted=[f['index'] for f in fl if f['index'] not in want])
            if not fl: out['warning'] = 'Метадані ще не прийшли - торент на паузі; «Продовжити» отримає список файлів'
            elif pick and not want: out['warning'] = 'Немає файлів з такими номерами - торент на паузі'
            stopped = bool(paused or (pick and not want))
            if stopped: CLIENT.tr.stop([t['id']])
            row = settle(t['id'], stopped)
            if row: t['name'] = row[0]['name']
    out.update(id='tr:%d' % t['id'], hash=t['hash'], name=t['name'] or b.get('title') or '', duplicate=t['duplicate'])
    return out


def engine_remove(h, files):
    """tv:<hash> -> the TV Cast engine's own /remove (files=1 deletes the data too)."""
    if not ENGINE: raise Bad('На цьому сервері немає рушія ТВ', 404)
    req = urllib.request.Request(ENGINE + '/remove?hash=%s&files=%d' % (h, 1 if files else 0), data=b'', method='POST')
    try: urllib.request.urlopen(req, timeout=10).close()
    except urllib.error.HTTPError as e:
        if e.code == 404: raise Bad('Немає такого торента на рушії ТВ', 404) from None
        raise Bad('Рушій ТВ: HTTP %s' % e.code, 502) from None
    except OSError: raise Bad('Рушій ТВ не відповідає', 502) from None


def control(tid, b):
    """POST /api/torrents/<id> {action: pause|resume|remove|remove_data|keep|files|priority, wanted?, unwanted?, high?, normal?, low?}.
    tr:<n> is a Transmission torrent; tv:<hash> lives on the TV Cast engine, which here only supports keep and remove."""
    a, (kind, ref) = b.get('action'), parse_id(tid)
    if a not in ('pause', 'resume', 'remove', 'remove_data', 'keep', 'files', 'priority'): raise Bad('Невідома дія: ' + str(a)[:30])
    out = {'ok': True, 'id': tid, 'action': a}
    if kind == 'tv':
        if a == 'keep':
            with trerr():
                try: out['torrent'] = CLIENT.keep(ref)
                except ValueError as e: raise Bad(str(e), 404) from None
        elif a in ('remove', 'remove_data'): engine_remove(ref, a == 'remove_data')
        else: raise Bad('Рушій ТВ цього не вміє - натисніть «Залишити собі»')
        return out
    if a == 'keep': raise Bad('Це вже торент Transmission')
    sets = {k: idx(b.get(k)) for k in ('wanted', 'unwanted', 'high', 'normal', 'low')}
    with trerr():
        if a == 'pause': CLIENT.tr.stop([ref]); settle(ref, True)   # so that a resume right after it is not lost
        elif a == 'resume': CLIENT.tr.start([ref])
        elif a in ('remove', 'remove_data'): CLIENT.tr.remove([ref], delete_data=a == 'remove_data')
        else: CLIENT.tr.set_files(ref, **sets)
    return out


def torrent_files(tid):
    kind, ref = parse_id(tid)
    if kind == 'tv': raise Bad('Файли видно лише в торентів Transmission - для рушія ТВ натисніть «Залишити собі»')
    with trerr():
        try: return CLIENT.tr.files(ref)
        except IndexError: raise Bad('Немає такого торента', 404) from None


ORDER = {'downloading': 0, 'checking': 1, 'queued': 2, 'paused': 3, 'error': 0, 'seeding': 4, 'done': 5}


def torrent_list():   # active first, so a new download is not lost under finished ones
    with trerr(): return sorted(CLIENT.list(), key=lambda r: ORDER.get(r['state'], 6))


def downloads():
    """The old /api/downloads shape ({free bytes, folder, torrents}) that the phone page, the Mac panel and the MCP tool read."""
    with trerr(): rows = CLIENT.list(); free = free_bytes()
    return {'free': free, 'folder': CFG['download_dir'],
            'torrents': [dict(r, done=r['progress'] >= 1, paused=r['state'] == 'paused') for r in rows]}


# API name, Transmission setting, its on/off switch, type. 0 = no limit, same as in config.json.
LIMITS = (('speed_down', 'speed-limit-down', 'speed-limit-down-enabled', int), ('speed_up', 'speed-limit-up', 'speed-limit-up-enabled', int),
          ('ratio', 'seedRatioLimit', 'seedRatioLimited', float), ('idle_min', 'idle-seeding-limit', 'idle-seeding-limit-enabled', int))


def client_get():
    with trerr(): s = CLIENT.tr.session(); free = free_bytes()
    out = {'alt_speed': bool(s.get('alt-speed-enabled'))}
    for k, key, flag, typ in LIMITS: out[k] = typ(s.get(key) or 0) if s.get(flag) else 0
    out['free_gb'] = None if free is None else round(free / 2 ** 30, 1)
    return out


def client_set(b):
    kw = {}
    if b.get('alt_speed') is not None:
        if not isinstance(b['alt_speed'], bool): raise Bad('«alt_speed» - true або false')
        kw['alt-speed-enabled'] = b['alt_speed']
    for k, key, flag, typ in LIMITS:
        if b.get(k) is None: continue
        try: v = typ(b[k])
        except (TypeError, ValueError): raise Bad('«%s» - число' % k) from None
        if not 0 <= v < 1e9: raise Bad('«%s» - число від 0 (0 = без ліміту)' % k)
        kw[key], kw[flag] = v, v > 0
    if kw:
        with trerr(): CLIENT.tr.set_session(**kw)
    return client_get()


def server():
    """What this server can do, for the UI: the TV button needs a core here or a peer that has one."""
    return {'name': CFG['name'], 'public_url': CFG['public_url'], 'tv': bool(CORE or tv_peer()), 'peers': CFG['peers'],
            'vpn_sources': [s for s, v in SOURCES.items() if '(VPN)' in v[1]]}


def recent():
    with jlock: js = sorted(jobs.values(), key=lambda j: -j['created'])[:30]
    return [summary(j) for j in js]


def sources():
    now = time.time()
    return [{'id': s, 'label': v[0], 'covers': v[1], 'default': s in DEFAULT, 'cooldown': max(0, round(GAP - (now - health[s]['last']), 1)),
             **{k: health[s][k] for k in ('ok', 'ms', 'err', 'n')}, 'ago': round(now - health[s]['last']) if health[s]['last'] else None}
            for s, v in SOURCES.items()]


# What the MCP connector (mcp.py) may call: the same functions as the phone and the Mac panel use. add, control and server
# are the code behind /api/torrents/add, /api/torrents/<id> and /api/server; configure() adds `client` and `link`.
SVC = {'create': create, 'act': act, 'downloads': downloads, 'sources': sources, 'recent': recent,
       'add': add, 'control': control, 'server': server}


def configure(path=None):
    """(Re)read config.json - or the file named by SEARCHD_CONFIG - and rebuild the client. Runs once when the module is
    imported; the tests call it with a temp config. Nothing here opens a port."""
    global CFG, PORT, CORE, ENGINE, CLIENT
    CFG = hostcfg.load(path or os.environ.get('SEARCHD_CONFIG'))
    PORT, CORE, ENGINE = CFG['port'], CFG['core'], CFG['engine']
    CLIENT = torrents.Client(CFG)
    SVC.update(client=CLIENT, link=CFG['public_url'])
    # RuTracker works only where the owner's logged-in Chrome runs (DevTools 18850 - core host): elsewhere it would always be red
    try: urllib.request.urlopen('http://127.0.0.1:18850/json', timeout=2).close(); rt_ok = True
    except Exception: rt_ok = False
    if not rt_ok and 'rutracker' in DEFAULT: DEFAULT.remove('rutracker')
    elif rt_ok and 'rutracker' not in DEFAULT: DEFAULT.insert(1, 'rutracker')


configure()


class H(BaseHTTPRequestHandler):
    def send(self, obj, code=200, ctype='application/json; charset=utf-8'):
        body = obj if isinstance(obj, bytes) else json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code); self.send_header('Content-Type', ctype); self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store'); self.send_header('Access-Control-Allow-Origin', '*'); self.end_headers(); self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204); self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type'); self.end_headers()

    def fail(self, e):   # Bad carries its own HTTP code; anything unexpected is a 502 with its text
        self.send({'error': str(e)[:300]}, e.code if isinstance(e, Bad) else 502)

    def do_GET(self):
        p = self.path.split('?')[0]
        try:
            if p in ('/', '/search', '/index.html'):
                return self.send(open(os.path.join(HERE, 'search.html'), 'rb').read(), ctype='text/html; charset=utf-8')
            if p == '/api/jobs': return self.send(recent())
            if p.startswith('/api/jobs/'):
                j = jobs.get(p.rsplit('/', 1)[1]); return self.send(j) if j else self.send({'error': 'Немає такого пошуку'}, 404)
            if p == '/api/sources': return self.send(sources())
            if p == '/mcp': return self.send({'error': 'POST JSON-RPC here (MCP streamable HTTP, no SSE stream)'}, 405)
            if p == '/api/downloads': return self.send(downloads())
            if p == '/api/server': return self.send(server())
            if p == '/api/torrents': return self.send(torrent_list())
            if p == '/api/client': return self.send(client_get())
            m = re.fullmatch(r'/api/torrents/([^/]+)/files', p)
            if m: return self.send(torrent_files(unquote(m.group(1))))
            self.send({'error': 'not found'}, 404)
        except Exception as e: self.fail(e)

    def do_POST(self):
        p = self.path.split('?')[0]
        try:
            try: b = json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)) or b'{}')
            except ValueError: raise Bad('Некоректний JSON') from None
            if p != '/mcp' and not isinstance(b, dict): raise Bad('Очікую JSON-обʼєкт')
            if p == '/api/jobs': return self.send(create(b))
            if p == '/api/act': return self.send(act(b))
            if p == '/api/torrents/add': return self.send(add(b))
            if p == '/api/client': return self.send(client_set(b))
            m = re.fullmatch(r'/api/torrents/([^/]+)', p)
            if m: return self.send(control(unquote(m.group(1)), b))
            if p == '/mcp':
                out = [r for r in (mcp.handle(x, SVC) for x in (b if isinstance(b, list) else [b])) if r]
                if not out: self.send_response(202); self.send_header('Content-Length', '0'); self.end_headers(); return
                return self.send(out if isinstance(b, list) else out[0])
            self.send({'error': 'not found'}, 404)
        except Exception as e: self.fail(e)

    def log_message(self, *a): pass


if __name__ == '__main__':
    load()
    for j in jobs.values():
        if j['state'] == 'run': j['state'] = 'done'   # interrupted by a restart
    ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
