# tests/test_api.py
"""HTTP API of searchd (Task 5) against a fake Transmission: torrents, client settings, server info, jobs with works + have."""
import atexit, itertools, json, os, shutil, subprocess, sys, tempfile, threading, unittest, urllib.error, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SEARCH = os.path.dirname(HERE)
sys.path.insert(0, SEARCH)
sys.path.insert(0, HERE)
from fake_transmission import Fake

TMP = tempfile.mkdtemp(prefix='searchd-test-')
atexit.register(shutil.rmtree, TMP, True)
BOOT = os.path.join(TMP, 'boot.json')
with open(BOOT, 'w') as f: json.dump({'name': 'Boot', 'transmission': {'rpc': 'http://127.0.0.1:1/transmission/rpc'}}, f)
os.environ['SEARCHD_CONFIG'] = BOOT       # searchd reads its config when it is imported
import searchd                            # importing must not start a server or bind a port
searchd.STATE = os.path.join(TMP, 'jobs.json')   # tests never write the real job history

M = 'magnet:?xt=urn:btih:DD8255ECDC7CA55FB0BBF81323D87062DB1F6D1C&dn=Big+Buck+Bunny'
H = 'dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c'
COUNT = itertools.count(1)


class Stub:
    """A tiny HTTP server: answer(method, path, body) -> (code, obj); every call is kept in .seen as (method, path, body)."""
    def __init__(self, answer):
        self.seen, me = [], self

        class Hd(BaseHTTPRequestHandler):
            def go(self, method):
                n = int(self.headers.get('Content-Length') or 0); raw = self.rfile.read(n) if n else b''
                body = json.loads(raw) if raw else None
                me.seen.append((method, self.path, body)); code, obj = answer(method, self.path, body)
                out = json.dumps(obj).encode()
                self.send_response(code); self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)
            def do_GET(self): self.go('GET')
            def do_POST(self): self.go('POST')
            def log_message(self, *a): pass
        self.srv = ThreadingHTTPServer(('127.0.0.1', 0), Hd)
        self.url = 'http://127.0.0.1:%d' % self.srv.server_port
        threading.Thread(target=self.srv.serve_forever, kwargs={'poll_interval': 0.01}, daemon=True).start()

    def close(self): self.srv.shutdown(); self.srv.server_close()


def engine_answer(method, path, body):   # the TV Cast engine: one finished torrent, /remove knows only H
    if path == '/list':
        return 200, {'folder': '/tmp/tv', 'free': 1, 'torrents': [{
            'hash': H, 'name': 'BBB', 'size': 100, 'progress': 1, 'down': 0, 'up': 5, 'peers': 3, 'active': True, 'paused': False,
            'done': True, 'magnet': 'magnet:?xt=urn:btih:' + H}]}
    if path.startswith('/remove?'): return (200, {}) if 'hash=' + H in path else (404, {})
    return 404, {}


def rel(title, seeds, h):
    return searchd.tsearch.row(title, 3 * 2 ** 30, seeds, 5, 'fake', 'magnet:?xt=urn:btih:%s&dn=x' % h)


class Api(unittest.TestCase):
    def setUp(self):
        self.patch(searchd, 'GAP', 0)       # no 10 s pause between two test searches of the fake source
        searchd.cache.clear()

    def patch(self, obj, name, value):
        old = getattr(obj, name); setattr(obj, name, value); self.addCleanup(setattr, obj, name, old)

    def stub(self, answer):
        s = Stub(answer); self.addCleanup(s.close); return s

    def boot(self, tr=True, **over):
        """Point searchd at a fresh config (fake Transmission, or a dead port) and serve its handler on a free port."""
        self.fake = Fake() if tr else None
        cfg = {'name': 'Test', 'public_url': 'https://test.example', 'download_dir': '/tmp/dl-test', 'engine': None, 'core': None,
               'peers': [], 'transmission': {'rpc': self.fake.url if tr else 'http://127.0.0.1:1/transmission/rpc'}}
        cfg.update(over); path = os.path.join(TMP, 'c%d.json' % next(COUNT))
        with open(path, 'w') as f: json.dump(cfg, f)
        searchd.configure(path)
        srv = ThreadingHTTPServer(('127.0.0.1', 0), searchd.H)
        threading.Thread(target=srv.serve_forever, kwargs={'poll_interval': 0.01}, daemon=True).start()
        self.addCleanup(lambda: (srv.shutdown(), srv.server_close()))
        self.base = 'http://127.0.0.1:%d' % srv.server_port
        if tr: self.free(50 * 2 ** 30)

    def wrap(self, pred, answer):
        """Make the fake Transmission answer the RPC calls matching pred(method, args) itself."""
        before = self.fake.handle
        self.fake.handle = lambda m, a: answer(m, a) if pred(m, a) else before(m, a)

    def free(self, n): self.wrap(lambda m, a: m == 'free-space', lambda m, a: {'path': a['path'], 'size-bytes': n})

    def sent(self, method): return [c['arguments'] for c in self.fake.calls if c['method'] == method]

    def call(self, method, path, body=None):
        data = body if isinstance(body, bytes) else None if body is None else json.dumps(body).encode()
        r = urllib.request.Request(self.base + path, data=data, method=method, headers={'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(r, timeout=20) as x: return x.status, json.loads(x.read())
        except urllib.error.HTTPError as e: return e.code, json.loads(e.read())

    def fake_source(self, rows):
        searchd.SOURCES['fake'] = ('Fake', 'test rows', lambda j: rows)
        searchd.gates['fake'] = threading.Lock()
        searchd.health['fake'] = {'last': 0.0, 'ms': None, 'ok': None, 'err': '', 'n': None}

        def undo():
            for d in (searchd.SOURCES, searchd.gates, searchd.health): d.pop('fake', None)
            searchd.cache.clear()
        self.addCleanup(undo)

    # ---- server info -------------------------------------------------------------------------------------------------

    def test_server_info(self):
        self.boot()
        code, d = self.call('GET', '/api/server')
        self.assertEqual(code, 200)
        self.assertEqual((d['name'], d['public_url'], d['tv'], d['peers']), ('Test', 'https://test.example', False, []))
        self.assertEqual(d['vpn_sources'], ['yts', 'rutor', 'bt4g'])

    def test_server_tv_flag_follows_core_or_peer(self):
        core = self.stub(lambda m, p, b: (200, {}))
        self.boot(core=core.url); self.assertTrue(self.call('GET', '/api/server')[1]['tv'])
        self.boot(peers=[{'name': 'core host', 'url': 'http://j'}]); d = self.call('GET', '/api/server')[1]
        self.assertTrue(d['tv']); self.assertEqual(d['peers'], [{'name': 'core host', 'url': 'http://j'}])

    # ---- Transmission torrents ---------------------------------------------------------------------------------------

    def test_torrent_lifecycle(self):
        self.boot()
        code, a = self.call('POST', '/api/torrents/add', {'magnet': M})
        self.assertEqual(code, 200)
        self.assertEqual((a['id'], a['hash'], a['duplicate']), ('tr:1', H, False)); self.assertNotIn('warning', a)
        add = self.sent('torrent-add')[0]
        self.assertEqual((add['filename'], add['paused'], add['download-dir']), (M, False, '/tmp/dl-test'))
        code, rows = self.call('GET', '/api/torrents')
        self.assertEqual(code, 200)
        self.assertEqual([(r['id'], r['engine'], r['state']) for r in rows], [('tr:1', 'transmission', 'downloading')])
        code, d = self.call('POST', '/api/torrents/tr:1', {'action': 'pause'})
        self.assertEqual((code, d['ok']), (200, True)); self.assertEqual(self.sent('torrent-stop'), [{'ids': [1]}])
        self.assertEqual(self.call('GET', '/api/torrents')[1][0]['state'], 'paused')
        self.call('POST', '/api/torrents/tr:1', {'action': 'resume'}); self.assertEqual(self.sent('torrent-start'), [{'ids': [1]}])
        self.assertEqual(self.call('GET', '/api/torrents')[1][0]['state'], 'downloading')
        self.assertTrue(self.call('POST', '/api/torrents/add', {'magnet': M})[1]['duplicate'])
        self.call('POST', '/api/torrents/tr:1', {'action': 'remove_data'})
        self.assertTrue(self.sent('torrent-remove')[-1]['delete-local-data']); self.assertEqual(self.call('GET', '/api/torrents')[1], [])

    def test_remove_keeps_the_data(self):
        self.boot(); self.call('POST', '/api/torrents/add', {'magnet': M})
        self.call('POST', '/api/torrents/tr:1', {'action': 'remove'})
        self.assertFalse(self.sent('torrent-remove')[-1]['delete-local-data'])

    def test_files_and_priority(self):
        self.boot(); self.call('POST', '/api/torrents/add', {'magnet': M})
        code, fl = self.call('GET', '/api/torrents/tr:1/files')
        self.assertEqual((code, [(f['index'], f['wanted']) for f in fl]), (200, [(0, True), (1, True)]))
        self.assertEqual(self.call('POST', '/api/torrents/tr:1', {'action': 'files', 'unwanted': [1]})[0], 200)
        self.assertEqual(self.sent('torrent-set')[-1], {'ids': [1], 'files-unwanted': [1]})
        self.assertFalse(self.call('GET', '/api/torrents/tr:1/files')[1][1]['wanted'])
        self.call('POST', '/api/torrents/tr:1', {'action': 'priority', 'high': [0]})
        self.assertEqual(self.call('GET', '/api/torrents/tr:1/files')[1][0]['priority'], 1)
        self.assertEqual(self.call('POST', '/api/torrents/tr:1', {'action': 'files', 'unwanted': ['x']})[0], 400)

    def test_low_disk_adds_paused_with_a_warning(self):
        self.boot(); self.free(3 * 2 ** 30)
        code, a = self.call('POST', '/api/torrents/add', {'magnet': M})
        self.assertEqual(code, 200); self.assertEqual(a['warning'], 'Менше 10 ГБ вільно - поставив на паузу')
        self.assertTrue(self.sent('torrent-add')[0]['paused'])
        self.assertEqual(self.call('GET', '/api/torrents')[1][0]['state'], 'paused')

    def test_paused_add_runs_for_the_metadata_then_stops(self):
        # a paused magnet never fetches its file list (measured on Transmission 4.1.3), so add starts it, waits, then stops it
        self.boot()
        code, a = self.call('POST', '/api/torrents/add', {'magnet': M, 'paused': True})
        self.assertEqual(code, 200); self.assertNotIn('warning', a)
        self.assertFalse(self.sent('torrent-add')[0]['paused'])
        self.assertEqual(len(self.sent('torrent-stop')), 1)
        self.assertEqual(self.call('GET', '/api/torrents')[1][0]['state'], 'paused')
        self.assertEqual(len(self.call('GET', '/api/torrents/' + a['id'] + '/files')[1]), 2)

    def lag_stops(self, polls):
        """Real Transmission applies torrent-stop about 0.2 s late (measured) and drops a start sent before that: the fake
        applies a stop only after `polls` more torrent-get calls."""
        real, st = self.fake.handle, {'ids': None, 'n': 0}

        def stop(m, a): st.update(ids=a['ids'], n=0); return {}

        def get(m, a):
            if st['ids'] is not None:
                st['n'] += 1
                if st['n'] > polls: real('torrent-stop', {'ids': st['ids']}); st['ids'] = None
            return real(m, a)
        self.wrap(lambda m, a: m == 'torrent-stop', stop); self.wrap(lambda m, a: m == 'torrent-get', get)

    def test_pause_returns_only_after_the_torrent_has_stopped(self):
        self.boot(); self.call('POST', '/api/torrents/add', {'magnet': M}); self.lag_stops(3)
        self.assertEqual(self.call('POST', '/api/torrents/tr:1', {'action': 'pause'})[0], 200)
        self.assertEqual(self.fake.torrents[H]['status'], 0)           # a resume sent right now would not be lost
        self.call('POST', '/api/torrents/tr:1', {'action': 'resume'}); self.assertEqual(self.fake.torrents[H]['status'], 4)

    def test_paused_add_returns_only_after_the_torrent_has_stopped(self):
        self.boot(); self.lag_stops(3)
        self.assertEqual(self.call('POST', '/api/torrents/add', {'magnet': M, 'paused': True})[0], 200)
        self.assertEqual(self.fake.torrents[H]['status'], 0)

    def test_files_picked_at_add(self):
        self.boot()
        code, a = self.call('POST', '/api/torrents/add', {'magnet': M, 'files': [0]})
        self.assertEqual(code, 200)
        self.assertEqual(self.sent('torrent-set')[-1], {'ids': [1], 'files-wanted': [0], 'files-unwanted': [1]})
        self.assertEqual([f['wanted'] for f in self.call('GET', '/api/torrents/tr:1/files')[1]], [True, False])
        self.assertEqual(self.sent('torrent-stop'), [])
        self.assertEqual(self.call('GET', '/api/torrents')[1][0]['state'], 'downloading')

    def test_no_metadata_in_time_leaves_it_stopped(self):
        self.boot(); self.patch(searchd, 'FILES_WAIT', 0.6)
        self.wrap(lambda m, a: m == 'torrent-get' and 'fileStats' in a['fields'], lambda m, a: {'torrents': [{'files': [], 'fileStats': []}]})
        code, a = self.call('POST', '/api/torrents/add', {'magnet': M, 'files': [0]})
        self.assertEqual(code, 200); self.assertIn('Метадані', a['warning'])
        self.assertEqual(len(self.sent('torrent-stop')), 1); self.assertEqual(self.sent('torrent-set'), [])

    def test_add_resolves_a_page_and_a_topic(self):
        self.boot(); self.patch(searchd.tsearch, 'resolve', lambda url: M); self.patch(searchd, 'rt', lambda *a: {'magnet': M})
        self.assertEqual(self.call('POST', '/api/torrents/add', {'page': 'https://example.com/release'})[1]['hash'], H)
        self.assertTrue(self.call('POST', '/api/torrents/add', {'topic': '123'})[1]['duplicate'])
        self.assertEqual(len(self.sent('torrent-add')), 2)

    def test_bad_requests(self):
        self.boot()
        self.assertEqual(self.call('POST', '/api/torrents/add', {'magnet': 'https://example.com/a.torrent'}), (400, {'error': 'Це не магнет'}))
        self.assertEqual(self.call('POST', '/api/torrents/add', {})[0], 400)
        self.assertEqual(self.call('POST', '/api/torrents/add', {'magnet': M, 'files': 'all'})[0], 400)
        self.assertEqual(self.call('POST', '/api/torrents/tr:1', {'action': 'explode'})[0], 400)
        self.assertEqual(self.call('POST', '/api/torrents/add', [1])[0], 400)
        self.assertEqual(self.call('POST', '/api/torrents/add', b'{nope')[0], 400)
        self.assertEqual(self.call('GET', '/api/torrents/tr:99/files')[0], 404)
        self.assertEqual(self.sent('torrent-add'), [])

    # ---- the TV Cast engine rows -------------------------------------------------------------------------------------

    def test_tv_rows_allow_only_keep_and_remove(self):
        eng = self.stub(engine_answer); self.boot(engine=eng.url)
        rows = self.call('GET', '/api/torrents')[1]
        self.assertEqual([(r['id'], r['engine'], r['state']) for r in rows], [('tv:' + H, 'tv', 'done')])
        code, d = self.call('POST', '/api/torrents/tv:' + H, {'action': 'remove_data'})
        self.assertEqual((code, d['ok']), (200, True)); self.assertEqual(eng.seen[-1][:2], ('POST', '/remove?hash=%s&files=1' % H))
        self.call('POST', '/api/torrents/tv:' + H, {'action': 'remove'}); self.assertEqual(eng.seen[-1][1], '/remove?hash=%s&files=0' % H)
        for a in ('pause', 'resume', 'files', 'priority'): self.assertEqual(self.call('POST', '/api/torrents/tv:' + H, {'action': a})[0], 400, a)
        self.assertEqual(self.call('GET', '/api/torrents/tv:' + H + '/files')[0], 400)
        self.assertEqual(self.call('POST', '/api/torrents/tv:' + 'ab' * 20, {'action': 'remove'})[0], 404)   # the engine does not know it
        self.assertEqual(self.call('POST', '/api/torrents/tv:zz', {'action': 'remove'})[0], 404)             # not a hash: never reaches the engine
        self.assertEqual(self.call('POST', '/api/torrents/tr:x', {'action': 'pause'})[0], 404)

    def test_keep_moves_a_tv_torrent_into_transmission(self):
        eng = self.stub(engine_answer); self.boot(engine=eng.url)
        code, d = self.call('POST', '/api/torrents/tv:' + H, {'action': 'keep'})
        self.assertEqual(code, 200); self.assertEqual((d['torrent']['engine'], d['torrent']['id']), ('transmission', 'tr:1'))
        self.assertEqual(self.sent('torrent-add')[0]['download-dir'], '/tmp/tv')   # same folder: Transmission verifies, no re-download
        self.assertEqual([p for _, p, _ in eng.seen if p.startswith('/remove')], ['/remove?hash=%s&files=0' % H])   # the files stay
        self.assertEqual(self.call('POST', '/api/torrents/tr:1', {'action': 'keep'})[0], 400)
        self.assertEqual(self.call('POST', '/api/torrents/tv:' + 'ab' * 20, {'action': 'keep'})[0], 404)

    # ---- client settings ---------------------------------------------------------------------------------------------

    def test_client_settings(self):
        self.boot()
        code, c = self.call('GET', '/api/client')
        self.assertEqual(code, 200)
        self.assertEqual((c['alt_speed'], c['speed_down'], c['speed_up'], c['ratio'], c['idle_min'], c['free_gb']), (False, 0, 0, 0, 0, 50.0))
        code, c = self.call('POST', '/api/client', {'alt_speed': True}); self.assertEqual((code, c['alt_speed']), (200, True))
        self.assertIs(self.sent('session-set')[-1]['alt-speed-enabled'], True)
        self.call('POST', '/api/client', {'speed_down': 500, 'speed_up': 100, 'ratio': 2.0, 'idle_min': 30})
        s = self.fake.session
        self.assertEqual((s['speed-limit-down'], s['speed-limit-down-enabled'], s['speed-limit-up'], s['speed-limit-up-enabled']), (500, True, 100, True))
        self.assertEqual((s['seedRatioLimit'], s['seedRatioLimited'], s['idle-seeding-limit'], s['idle-seeding-limit-enabled']), (2.0, True, 30, True))
        c = self.call('GET', '/api/client')[1]; self.assertEqual((c['speed_down'], c['speed_up'], c['ratio'], c['idle_min']), (500, 100, 2.0, 30))
        c = self.call('POST', '/api/client', {'speed_down': 0})[1]
        self.assertEqual(c['speed_down'], 0); self.assertFalse(self.fake.session['speed-limit-down-enabled'])
        self.assertEqual(self.call('POST', '/api/client', {'speed_down': 'fast'})[0], 400)
        self.assertEqual(self.call('POST', '/api/client', {'alt_speed': 'yes'})[0], 400)

    # ---- /api/downloads, act, MCP service table ----------------------------------------------------------------------

    def test_downloads_keeps_the_old_shape(self):
        self.boot(); self.call('POST', '/api/torrents/add', {'magnet': M})
        code, d = self.call('GET', '/api/downloads')
        self.assertEqual((code, d['folder'], d['free']), (200, '/tmp/dl-test', 50 * 2 ** 30))
        t = d['torrents'][0]
        self.assertEqual((t['hash'], t['name'], t['progress'], t['down'], t['done'], t['paused']), (H, 'Big Buck Bunny', 0.5, 2048, False, False))
        self.assertEqual(searchd.SVC['downloads']()['folder'], '/tmp/dl-test')   # the MCP tool calls the same function

    def test_act_download_goes_to_transmission(self):
        self.boot(); code, a = self.call('POST', '/api/act', {'to': 'download', 'magnet': M})
        self.assertEqual((code, a['id'], a['hash']), (200, 'tr:1', H)); self.assertEqual(len(self.sent('torrent-add')), 1)
        self.assertEqual(self.call('POST', '/api/act', {'to': 'download'})[0], 400)
        self.assertEqual(self.call('POST', '/api/act', {'to': 'magnet', 'magnet': M})[1], {'magnet': M})

    def test_act_tv_uses_the_core_or_a_peer(self):
        core = self.stub(lambda m, p, b: (200, {'core': True})); self.boot(core=core.url)
        self.assertEqual(self.call('POST', '/api/act', {'to': 'tv', 'magnet': M, 'from': 'x'})[1], {'core': True})
        self.assertEqual(core.seen[-1], ('POST', '/api/kino/torrent/use', {'magnet': M, 'from': 'x'}))
        peer = self.stub(lambda m, p, b: (200, {'peer': True})); self.boot(peers=[{'name': 'J', 'url': peer.url}])
        self.assertEqual(self.call('POST', '/api/act', {'to': 'tv', 'magnet': M, 'from': 'x'})[1], {'peer': True})
        self.assertEqual(peer.seen[-1], ('POST', '/api/act', {'to': 'tv', 'magnet': M, 'from': 'x', 'hop': 1}))
        self.call('POST', '/api/act', {'to': 'inbox', 'magnet': M, 'title': 'T'})
        self.assertEqual(peer.seen[-1][2], {'to': 'inbox', 'magnet': M, 'title': 'T', 'from': 'search', 'hop': 1})
        n = len(peer.seen)
        self.assertEqual(self.call('POST', '/api/act', {'to': 'tv', 'magnet': M, 'hop': 1})[0], 409)   # forwarded once already: never again
        self.assertEqual(len(peer.seen), n)
        bad = self.stub(lambda m, p, b: (502, {'error': 'ядро не відповідає'})); self.boot(peers=[{'name': 'J', 'url': bad.url}])
        self.assertEqual(self.call('POST', '/api/act', {'to': 'tv', 'magnet': M})[1], {'error': 'ядро не відповідає'})
        self.boot(peers=[{'name': 'J', 'url': 'http://127.0.0.1:1'}]); self.assertEqual(self.call('POST', '/api/act', {'to': 'tv', 'magnet': M})[0], 502)
        self.boot(); self.assertEqual(self.call('POST', '/api/act', {'to': 'tv', 'magnet': M})[0], 409)   # no core, no peer

    def test_svc_table_for_mcp(self):
        self.boot()
        for k in ('create', 'act', 'downloads', 'sources', 'recent', 'client', 'add', 'control', 'server'): self.assertIn(k, searchd.SVC)
        self.assertIs(searchd.SVC['client'], searchd.CLIENT); self.assertEqual(searchd.SVC['link'], 'https://test.example')
        self.assertEqual(searchd.SVC['server']()['name'], 'Test')

    # ---- jobs: works + have ------------------------------------------------------------------------------------------

    def test_job_has_work_cards_and_have_marks(self):
        self.boot(); self.call('POST', '/api/torrents/add', {'magnet': M})
        self.fake_source([rel('Big Buck Bunny 2008 1080p BluRay x264', 60, H.upper()), rel('Big Buck Bunny 2008 720p WEB-DL', 30, 'a' * 40),
                          rel('Other Film 2019 1080p WEB-DL', 40, 'b' * 40)])
        code, job = self.call('POST', '/api/jobs', {'q': 'Big Buck Bunny', 'sources': ['fake'], 'wait': True})
        self.assertEqual((code, job['state'], job['count']), (200, 'done', 3))
        self.assertEqual([w['title'] for w in job['works']], ['Big Buck Bunny', 'Other Film'])
        w = job['works'][0]; self.assertEqual((w['year'], w['kind'], w['count'], len(w['rows'])), ('2008', 'film', 2, 2))
        self.assertEqual([(r['hash'], r['have']['engine'], r['have']['id']) for r in w['rows'] if 'have' in r], [(H.upper(), 'transmission', 'tr:1')])
        self.assertEqual([r['hash'] for r in job['items'] if 'have' in r], [H.upper()])
        self.assertNotIn('have', job['works'][1]['rows'][0])
        self.assertEqual(self.call('GET', '/api/jobs/' + job['id'])[1]['works'][0]['title'], 'Big Buck Bunny')

    def test_have_marks_do_not_leak_through_the_cache(self):
        self.boot(); self.call('POST', '/api/torrents/add', {'magnet': M})
        self.fake_source([rel('Big Buck Bunny 2008 1080p BluRay x264', 60, H.upper())])
        first = self.call('POST', '/api/jobs', {'q': 'Big Buck Bunny', 'sources': ['fake'], 'wait': True})[1]
        self.assertEqual(len([r for r in first['items'] if 'have' in r]), 1)
        self.call('POST', '/api/torrents/tr:1', {'action': 'remove'})
        second = self.call('POST', '/api/jobs', {'q': 'Big Buck Bunny', 'sources': ['fake'], 'wait': True})[1]   # same query: rows come from the cache
        self.assertTrue(second['sources']['fake']['cached']); self.assertEqual([r for r in second['items'] if 'have' in r], [])

    def test_cards_are_limited_to_30_and_rows_to_40(self):
        self.boot()
        rows = [rel('Mega Film 2020 1080p release %d' % i, 25, '%040x' % i) for i in range(45)]
        rows += [rel('Film %02d 2021 1080p WEB-DL' % i, 25, '%040x' % (100 + i)) for i in range(34)]
        self.fake_source(rows)
        job = self.call('POST', '/api/jobs', {'q': 'film', 'sources': ['fake'], 'wait': True})[1]
        self.assertEqual((len(job['works']), job['works'][0]['title'], job['works'][0]['count'], len(job['works'][0]['rows'])), (30, 'Mega Film', 45, 40))
        self.assertEqual(len(job['items']), 79)

    def test_search_works_while_transmission_is_down(self):
        self.boot(tr=False)
        self.fake_source([rel('Big Buck Bunny 2008 1080p BluRay x264', 60, H.upper()), rel('Other Film 2019 1080p WEB-DL', 40, 'b' * 40)])
        job = self.call('POST', '/api/jobs', {'q': 'Big Buck Bunny', 'sources': ['fake'], 'wait': True})[1]
        self.assertEqual((job['state'], len(job['works'])), ('done', 2)); self.assertEqual([r for r in job['items'] if 'have' in r], [])
        for path in ('/api/torrents', '/api/client', '/api/downloads'):
            code, d = self.call('GET', path)
            self.assertEqual(code, 502, path); self.assertTrue(d['error'].startswith('Transmission не працює'), d)
        self.assertEqual(self.call('POST', '/api/torrents/add', {'magnet': M})[0], 502)
        self.assertEqual(self.call('POST', '/api/torrents/tr:1', {'action': 'pause'})[0], 502)
        self.assertEqual(self.call('POST', '/api/client', {'alt_speed': True})[0], 502)
        self.assertEqual(self.call('GET', '/api/server')[0], 200)


class Import(unittest.TestCase):
    def test_import_does_not_serve(self):
        code = 'import sys; sys.path.insert(0, %r); import searchd; print(searchd.PORT, searchd.CFG["name"])' % SEARCH
        r = subprocess.run([sys.executable, '-c', code], capture_output=True, text=True, timeout=30, env=dict(os.environ, SEARCHD_CONFIG=BOOT))
        self.assertEqual((r.returncode, r.stdout.split()), (0, ['8896', 'Boot']), r.stderr[-300:])


if __name__ == '__main__':
    unittest.main()
