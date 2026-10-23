#!/usr/bin/env python3
"""torrent-search: one query -> every open torrent index -> one graded list of magnets.

Sources (one request each per run, no loops - owner rule "background-crawl-rate-limit"):
  jacred  - jac.red index: rutracker, kinozal, rutor, nnmclub, toloka, mazepa, bitru, korsars, megapeer, torrentby...
  apibay  - The Pirate Bay API
  knaben  - Knaben aggregator (TPB, Nyaa, 1337x and others)
  tinytv  - the tinyTV core on core host (adds RuTracker from the owner's logged-in Chrome); films only

Usage:
  tsearch.py "Inception"                      # anything, best first
  tsearch.py "Начало" --orig Inception --film # film: names must match, not just contain
  tsearch.py "Pink Floyd flac" --json --top 5
  tsearch.py "Inception 2160p" --send tv      # best result straight to the TV (tinyTV core)
  tsearch.py "Inception" --send inbox --from "Codex"   # into "Від агентів" on the Kino home screen
Python 3.9+, standard library only.
"""
import argparse, html, json, re, socket, ssl, sys, time, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor

UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15'
TINYTV = 'https://<core-host>.<tailnet>.ts.net:8443'   # override with --core
SEARCHD = 'https://<core-host>.<tailnet>.ts.net:8444'  # searchd job queue (override with --searchd)
TR = '&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce'


# The provider (the ISP) hides some trackers in its DNS (owner 2026-10-22: open them). Only these hosts are resolved
# over DNS-over-HTTPS (Cloudflare); TLS still checks the real certificate. Sites behind Cloudflare checks stay out.
DOH_HOSTS = {'nyaa.si', 'www.limetorrents.lol', 'www.limetorrents.fun'}
_doh, _gai = {}, socket.getaddrinfo


def _getaddrinfo(host, *a, **k):
    if host in DOH_HOSTS:
        ip, t = _doh.get(host, (None, 0))
        if not ip or time.time() - t > 3600:
            r = urllib.request.Request('https://cloudflare-dns.com/dns-query?name=%s&type=A' % host, headers={'Accept': 'application/dns-json'})
            ans = [x['data'] for x in json.loads(urllib.request.urlopen(r, timeout=8).read()).get('Answer', []) if x.get('type') == 1]
            if ans: ip = ans[0]; _doh[host] = (ip, time.time())
        if ip: return _gai(ip, *a, **k)
    return _gai(host, *a, **k)


socket.getaddrinfo = _getaddrinfo


def gib(text):   # "1.5 GiB", "49.29 GB", "300 MB" -> bytes
    m = re.match(r'([\d.]+)\s*([KMGT])i?B', text or '', re.I)
    return int(float(m.group(1)) * 1024 ** ' KMGT'.index(m.group(2).upper())) if m else 0


def page(url, timeout=20):   # HTML pages (therarbg, audiobookbay); same browser header as http()
    with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': UA}), timeout=timeout,
                                context=ssl.create_default_context()) as r:
        return r.read().decode('utf-8', 'replace')


def http(url, data=None, timeout=25):
    h = {'User-Agent': UA}   # jac.red answers 403 to a bare client (measured 2026-10-21)
    if data is not None: h['Content-Type'] = 'application/json'; data = json.dumps(data).encode()
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=h), timeout=timeout,
                                context=ssl.create_default_context()) as r:
        return json.loads(r.read().decode('utf-8', 'replace'))


def norm(s): return re.sub(r'[^0-9a-zа-яіїєґ]', '', (s or '').lower().replace('ё', 'е'))


def row(title, size, seeds, peers, tracker, magnet, **extra):
    lt = title.lower()
    q = 2160 if re.search(r'2160|\b4k\b|uhd', lt) else 1080 if '1080' in lt else 720 if '720' in lt else 0
    h = re.search(r'btih:([0-9a-zA-Z]{32,40})', magnet or '')
    num = lambda v: int(re.sub(r'[^0-9]', '', str(v)) or 0)
    r = {'title': title, 'size_gb': round(size / 1073741824, 2) if size else None, 'seeds': num(seeds),
         'peers': num(peers), 'tracker': tracker, 'quality': q, 'hdr': bool(re.search(r'hdr|dolby vision|\bdv\b', lt)),
         'ua': bool(re.search(r'\bukr\b|укр|українськ|\bua\b', lt)), 'hash': h.group(1).upper() if h else '', 'magnet': magnet}
    r.update({k: v for k, v in extra.items() if v})
    r.update(describe(title, size))
    return r


def describe(title, size, mins=120):
    """What the release is, read from its name (rules shared with kino.html tvInfo/audioTags, owner 2026-10-21).
    Hisense 55A56E plays H.264 and HEVC incl. 10-bit HDR10 up to ~36 Mbit/s without re-encoding; Dolby Vision
    profile 5 has no HDR10 base and shows purple-green on it."""
    s = ' ' + (title or '').lower() + ' '
    codec = 'av1' if re.search(r'\bav1\b', s) else 'vp9' if re.search(r'\bvp9\b', s) else \
        'hevc' if re.search(r'hevc|h\.?265|x265', s) else 'avc' if re.search(r'\bavc\b|h\.?264|x264', s) else ''
    dv = bool(re.search(r'dolby ?vision|\bdovi\b|\bdv\b', s))
    hdr10 = bool(re.search(r'hdr10|\bhdr\b', re.sub(r'dolby ?vision|\bdovi\b|\bdv\b', '', s)))
    mbps = round(size * 8 / (mins * 60) / 1e6) if size else 0
    audio = [n for n, rx in (('UA', r'укр|ukr|\bua\b|україн|украин'), ('EN', r'\beng\b|english|original|оригинал|оригінал'),
                             ('RU', r'\b(dub|mvo|dvo|avo|vo)\b|дубляж|многоголос|двухголос|рус|\brus\b'),
                             ('Коментар', r'коммент|комент|comment'), ('Суб', r'\bsub|субтит')) if re.search(rx, s)]
    return {'codec': codec, 'dv5': dv and not hdr10, 'mbps': mbps, 'tenbit': bool(re.search(r'10.?bit|hdr|main ?10', s)),
            'tv_ok': not (dv and not hdr10) and codec in ('hevc', 'avc') and 0 < mbps <= 36, 'audio': audio}


def jacred(q, orig):
    d = http('https://jac.red/api/v1.0/torrents?' + urllib.parse.urlencode({'search': orig or q}))
    out = []
    for t in d:
        voices = t.get('voices') or []
        r = row(t.get('title', ''), t.get('size') or 0, t.get('sid'), t.get('pir'), t.get('tracker', 'jacred'), t.get('magnet', ''),
                url=t.get('url'), name=t.get('name'), original=t.get('originalname'), voices=voices, seasons=t.get('seasons'))
        if voices and any(re.search(r'укр|ukr', v, re.I) for v in voices): r['ua'] = True
        if t.get('quality'): r['quality'] = t['quality']
        m = re.search(r'rutracker\.[a-z]+/forum/viewtopic\.php\?t=(\d+)', t.get('url') or '')
        if m: r['topic'] = m.group(1)
        out.append(r)
    return out


def apibay(q, orig):
    d = http('https://apibay.org/q.php?' + urllib.parse.urlencode({'q': orig or q}))
    return [row(t['name'], int(t.get('size') or 0), t.get('seeders'), t.get('leechers'), 'thepiratebay',
                'magnet:?xt=urn:btih:%s&dn=%s%s' % (t['info_hash'], urllib.parse.quote(t['name']), TR))
            for t in d if len(t.get('info_hash', '')) == 40 and t['info_hash'] != '0' * 40 and not str(t.get('category', '')).startswith('5')]


def knaben(q, orig):
    d = http('https://api.knaben.org/v1', {'search_type': '100%', 'search_field': 'title', 'query': orig or q, 'size': 100,
                                           'order_by': 'seeders', 'order_direction': 'desc', 'hide_unsafe': True, 'hide_xxx': True})
    return [row(h['title'], h.get('bytes') or 0, h.get('seeders'), h.get('peers'), (h.get('tracker') or 'knaben').lower().replace(' ', ''),
                h.get('magnetUrl') or 'magnet:?xt=urn:btih:%s%s' % (h['hash'], TR)) for h in d.get('hits', []) if h.get('hash') or h.get('magnetUrl')]


def tinytv(q, orig, core):
    d = http(core + '/api/kino/torrents', {'title': q, 'original': orig}, timeout=60)   # the core joins both: no duplicate
    rows = d if isinstance(d, list) else d.get('items', []) if isinstance(d, dict) else []
    return [row(t.get('title', ''), 0, t.get('seeds'), t.get('peers'), t.get('tracker', ''), t.get('magnet', ''), topic=t.get('topic'),
                url=t.get('url'), voices=t.get('voices')) for t in rows]


def torrentscsv(q, orig):   # open JSON API over a scraped DHT index, no login (measured 2026-10-22)
    d = http('https://torrents-csv.com/service/search?' + urllib.parse.urlencode({'q': orig or q, 'size': 50}))
    return [row(t['name'], int(t.get('size_bytes') or 0), t.get('seeders'), t.get('leechers'), 'torrents-csv',
                'magnet:?xt=urn:btih:%s&dn=%s%s' % (t['infohash'].upper(), urllib.parse.quote(t['name']), TR))
            for t in d.get('torrents', []) if len(t.get('infohash', '')) == 40]


def eztv(q, orig, imdb=''):   # TV series only, looked up by IMDb id (tt1234567); skipped without one
    m = re.search(r'tt(\d{5,9})', imdb or q)
    if not m: return []
    d = http('https://eztvx.to/api/get-torrents?' + urllib.parse.urlencode({'imdb_id': m.group(1), 'limit': 100}))
    return [row(t['title'], int(t.get('size_bytes') or 0), t.get('seeds'), t.get('peers'), 'eztv', t['magnet_url'],
                season=t.get('season'), episode=t.get('episode')) for t in d.get('torrents') or [] if t.get('magnet_url')]


def therarbg(q, orig):   # open HTML list, all categories; the magnet sits on the release page -> resolve() on demand
    out, base = [], 'https://therarbg.to'
    h = page(base + '/get-posts/keywords:%s/' % urllib.parse.quote(orig or q))
    for tr in h.split('<tr class="list-entry">')[1:]:
        a = re.search(r'href="(/post-detail/[^"]+)"[^>]*>\s*([^<]+)</a>', tr)
        if not a: continue
        size = re.search(r'class="sizeCell" data-order="(\d+)"', tr); cat = re.search(r'/get-posts/category:([^/]+)/', tr)
        nums = re.findall(r'<td style="color: (?:green|red)">(\d+)</td>', tr)
        out.append(row(html.unescape(a.group(2).strip()), int(size.group(1)) if size else 0, nums[0] if nums else 0,
                       nums[1] if len(nums) > 1 else 0, 'therarbg', '', page=base + a.group(1), category=cat and cat.group(1)))
    return words_match(out, orig or q)


def audiobookbay(q, orig):   # audiobooks; no seeders in the list, the info hash is on the book page -> resolve()
    out, base = [], 'https://audiobookbay.lu'
    h = page(base + '/?s=' + urllib.parse.quote((orig or q).lower()))
    for post in h.split('<div class="post">')[1:]:
        a = re.search(r'<h2><a href="([^"]+)"[^>]*>([^<]+)</a>', post)
        if not a: continue
        mb = re.search(r"File Size: <span[^>]*>([\d.]+)</span>\s*(\w+)", post); fmt = re.search(r"Format: <span[^>]*>([^<]+)", post)
        size = float(mb.group(1)) * (1073741824 if mb.group(2).upper().startswith('G') else 1048576) if mb else 0
        out.append(row(html.unescape(a.group(2)), int(size), 0, 0, 'audiobookbay', '', page=urllib.parse.urljoin(base, a.group(1)),
                       category='Audiobook ' + (fmt.group(1) if fmt else '')))
    return words_match(out, orig or q)


def nyaa(q, orig):   # anime, manga, books, music, games; RSS with info hash (via DoH)
    h = page('https://nyaa.si/?' + urllib.parse.urlencode({'page': 'rss', 'q': orig or q, 's': 'seeders', 'o': 'desc'}))
    out = []
    for it in h.split('<item>')[1:]:
        g = lambda tag: (re.search(r'<%s>([^<]*)</%s>' % (tag, tag), it) or [None, ''])[1]
        ih = g('nyaa:infoHash'); t = html.unescape(g('title'))
        if len(ih) == 40: out.append(row(t, gib(g('nyaa:size')), g('nyaa:seeders'), g('nyaa:leechers'), 'nyaa',
                                         'magnet:?xt=urn:btih:%s&dn=%s%s' % (ih.upper(), urllib.parse.quote(t), TR), category=g('nyaa:category')))
    return out


def limetorrents(q, orig):   # games, software, films, music; the hash is in the list (via DoH)
    h = page('https://www.limetorrents.fun/search/all/%s/seeds/1/' % urllib.parse.quote((orig or q).replace(' ', '-')))
    out = []
    for tr in re.split(r'<tr bgcolor="#[0-9A-F]{6}">', h)[1:]:
        m = re.search(r'itorrents\.net/torrent/([0-9A-F]{40})\.torrent\?title=([^"]+)"', tr)
        if not m: continue
        t = urllib.parse.unquote(m.group(2)).replace('-', ' ').strip()
        cells = re.findall(r'<td class="td(?:normal|seed|leech)">([^<]*)', tr); cat = re.search(r'- in ([^<]+)</a>', tr)
        out.append(row(t, gib(cells[1] if len(cells) > 1 else ''), cells[2] if len(cells) > 2 else 0, cells[3] if len(cells) > 3 else 0,
                       'limetorrents', 'magnet:?xt=urn:btih:%s&dn=%s%s' % (m.group(1), urllib.parse.quote(t), TR), category=cat and cat.group(1)))
    return out


# These three answer only while a VPN runs on core host (the provider resets the connection otherwise; measured 2026-10-22).
def yts(q, orig):   # films, small encodes; JSON API (yts.mx moved to yts.gg)
    d = http('https://yts.gg/api/v2/list_movies.json?' + urllib.parse.urlencode({'query_term': orig or q, 'limit': 20}))
    out = []
    for m in (d.get('data') or {}).get('movies') or []:
        for t in m.get('torrents') or []:
            name = '%s %s %s %s' % (m.get('title_long', ''), t.get('quality', ''), t.get('type', ''), t.get('video_codec', ''))
            out.append(row(name, gib(t.get('size')), t.get('seeds'), t.get('peers'), 'yts',
                           'magnet:?xt=urn:btih:%s&dn=%s%s' % (t['hash'], urllib.parse.quote(m.get('title', '')), TR), imdb=m.get('imdb_code')))
    return out


def rutor(q, orig):   # rutor.info directly: films, music, software, books; magnets in the list
    h = page('https://rutor.info/search/0/0/000/0/' + urllib.parse.quote(q))
    out = []
    for tr in re.split(r'<tr class="(?:gai|tum)">', h)[1:]:
        m = re.search(r'href="(magnet:\?xt=urn:btih:[0-9a-fA-F]{40}[^"]*)"', tr); t = re.search(r'<a href="/torrent/\d+/[^"]*">([^<]+)</a>', tr)
        if not (m and t): continue
        size = re.search(r'<td align="right">([\d.]+)&nbsp;([KMGT]B)</td>', tr)
        sd = re.search(r'class="green">.*?&nbsp;(\d+)</span>', tr); le = re.search(r'class="red">&nbsp;(\d+)</span>', tr)
        out.append(row(html.unescape(t.group(1).strip()), gib(size.group(1) + ' ' + size.group(2)) if size else 0,
                       sd.group(1) if sd else 0, le.group(1) if le else 0, 'rutor', html.unescape(m.group(1))))
    return words_match(out, q)


def bt4g(q, orig):   # DHT search engine; RSS has no seeders, so these rows sort last
    h = page('https://bt4gprx.com/search?' + urllib.parse.urlencode({'q': orig or q, 'page': 'rss'}))
    out = []
    for it in h.split('<item>')[1:]:
        t = re.search(r'<title>(.*?)</title>', it, re.S); ln = re.search(r'<link>(magnet:[^<]+)</link>', it)
        d = re.search(r'<br>([\d.]+\s*[KMGT]B)<br>([^<]*)<br>', it)
        if t and ln: out.append(row(html.unescape(t.group(1)), gib(d.group(1)) if d else 0, 0, 0, 'bt4g', html.unescape(ln.group(1)),
                                    category=d and d.group(2)))
    return words_match(out, orig or q)


def translate(q, pair='en|ru'):
    """Free MyMemory API (no key): a book or film known only by its Russian title on RuTracker."""
    d = http('https://api.mymemory.translated.net/get?' + urllib.parse.urlencode({'q': q, 'langpair': pair}), timeout=10)
    t = html.unescape((d.get('responseData') or {}).get('translatedText') or '')
    return t if t and t.lower() != q.lower() and 'MYMEMORY' not in t.upper() else ''


def words_match(rows, q):
    """therarbg and audiobookbay match ANY word ("Under Saturn's Shadow" -> "Under Siege"): keep rows with every word."""
    ws = [norm(w) for w in re.split(r"[\s.,:;!?/()\[\]-]+", q.replace("'", '').replace('’', '')) if len(norm(w)) > 1]
    return [r for r in rows if all(w in norm(r['title'].replace("'", '').replace('’', '')) for w in ws)]


def resolve(url):
    """One request to a release page when the owner picks the row: its magnet (therarbg) or info hash (audiobookbay)."""
    h = page(url)
    m = re.search(r'magnet:\?xt=urn:btih:[0-9A-Za-z]{32,40}[^"\'<\s]*', h)
    if m: return html.unescape(m.group(0))
    m = re.search(r'Info Hash:</td>\s*<td[^>]*>\s*([0-9a-fA-F]{40})', h)
    return 'magnet:?xt=urn:btih:%s%s' % (m.group(1).upper(), TR) if m else ''


SOURCES = {'jacred': jacred, 'apibay': apibay, 'knaben': knaben, 'torrentscsv': torrentscsv}


def grade(r):   # owner's colours: green >= 20 seeders, yellow >= 5, red below; mazepa shows only its own seeders
    s = r['seeds']
    return 'u' if r['tracker'] == 'mazepa' and s < 20 else 'g' if s >= 20 else 'y' if s >= 5 else 'r'


def merge(lists, film_names, video=True):
    out, idx = [], {}
    for rows in lists:
        for r in rows:
            if film_names and not any(n and (norm(r.get('name')) == n or norm(r.get('original')).startswith(n) or norm(r['title']).startswith(n))
                                      for n in film_names):
                continue
            keys = [k for k in (r['hash'], r.get('topic') and 't' + str(r['topic']), r.get('page')) if k] or [r['title']]
            k = next((k for k in keys if k in idx), None)
            if k:   # the same release on several trackers: keep one, take the higher counts
                o = out[idx[k]]; o['seeds'] = max(o['seeds'], r['seeds']); o['peers'] = max(o['peers'], r['peers'])
                if r['tracker'] != o['tracker'] and r['tracker'] not in o.get('also', []): o.setdefault('also', []).append(r['tracker'])
                continue
            for k in keys: idx[k] = len(out)
            out.append(r)
    for r in out: r['grade'] = grade(r)
    rank = {'g': 0, 'y': 1, 'u': 1, 'r': 2}
    return sorted(out, key=lambda r: (rank[r['grade']], -r['ua'], -r['quality'] if video else 0, -r['seeds']))


def send(r, how, core, who):
    if how == 'tv': return http(core + '/api/kino/torrent/use', {'magnet': r['magnet']} if r['magnet'] else {'topic': r.get('topic')})
    if how == 'download': return http(core + '/api/kino/download/add', {'magnet': r['magnet']})
    return http(core + '/api/kino/inbox', {'add': {'title': r['title'], 'magnet': r['magnet'], 'from': who, 'note': r['tracker']}})


def main():
    a = argparse.ArgumentParser(description='Search every open torrent index at once.')
    a.add_argument('query'); a.add_argument('--orig', default='', help='original (English) title for films')
    a.add_argument('--film', action='store_true', help='keep only releases whose name matches the title')
    a.add_argument('--sources', default='jacred,apibay,knaben,torrentscsv', help='comma list; add "tinytv" for RuTracker via the owner Chrome')
    a.add_argument('--top', type=int, default=20); a.add_argument('--json', action='store_true')
    a.add_argument('--min-seeds', type=int, default=0); a.add_argument('--quality', type=int, default=0, help='e.g. 2160 or 1080')
    a.add_argument('--send', choices=['tv', 'download', 'inbox'], help='send the best result to tinyTV')
    a.add_argument('--pick', type=int, default=1, help='which result to send (1 = best)')
    a.add_argument('--from', dest='who', default='agent'); a.add_argument('--core', default=TINYTV)
    a.add_argument('--job', action='store_true', help='run through searchd on core host (agents: use this); prints the top and a phone link')
    a.add_argument('--searchd', default=SEARCHD)
    o = a.parse_args()
    if o.job:
        j = http(o.searchd + '/api/jobs', {'q': o.query, 'orig': o.orig, 'film': o.film, 'from': o.who, 'wait': True,
                                           'rutracker': 'tinytv' in o.sources}, timeout=100)
        if 'error' in j: print(j['error'], file=sys.stderr); sys.exit(2)
        items = [r for r in j['items'] if r['seeds'] >= o.min_seeds and (not o.quality or r['quality'] == o.quality)][:o.top]
        if o.json: print(json.dumps({'id': j['id'], 'link': o.searchd + '/#' + j['id'], 'count': j['count'], 'items': items}, ensure_ascii=False, indent=1)); return
        for i, r in enumerate(items, 1):
            print('%2d %5s сід %4s %-7s %s %s' % (i, r['seeds'], r['quality'] or '', 'TV ✓' if r.get('tv_ok') else 'DV5 ✕' if r.get('dv5') else '',
                                                 ' '.join(r.get('audio') or []), r['title'][:80]))
        print('— %d знайдено; на телефоні: %s/#%s' % (j['count'], o.searchd, j['id'])); return
    names = [norm(x) for x in (o.query, o.orig) if x] if o.film else []
    wanted = [s.strip() for s in o.sources.split(',') if s.strip()]
    errors = {}

    def run(s):
        try: return tinytv(o.query, o.orig, o.core) if s == 'tinytv' else SOURCES[s](o.query, o.orig)
        except Exception as e: errors[s] = str(e)[:120]; return []
    with ThreadPoolExecutor(len(wanted)) as ex: lists = list(ex.map(run, wanted))
    res = [r for r in merge(lists, names) if r['seeds'] >= o.min_seeds and (not o.quality or r['quality'] == o.quality)]
    if o.send:
        if len(res) < o.pick: print('Нічого не знайшов для відправки', file=sys.stderr); sys.exit(2)
        print(json.dumps({'sent': res[o.pick - 1]['title'], 'reply': send(res[o.pick - 1], o.send, o.core, o.who)}, ensure_ascii=False)); return
    if o.json:
        print(json.dumps({'query': o.query, 'count': len(res), 'errors': errors, 'items': res[:o.top]}, ensure_ascii=False, indent=1)); return
    dot = {'g': '🟢', 'y': '🟡', 'u': '🔵', 'r': '🔴'}
    for i, r in enumerate(res[:o.top], 1):
        print('%2d %s %4s %-12s %5s сід %s%s' % (i, dot[r['grade']], r['quality'] or '', r['tracker'][:12], r['seeds'],
                                              'UA ' if r['ua'] else '', r['title'][:90]))
    print('— %d знайдено%s' % (len(res), ('; помилки: ' + ', '.join('%s: %s' % e for e in errors.items())) if errors else ''))


if __name__ == '__main__':
    main()
