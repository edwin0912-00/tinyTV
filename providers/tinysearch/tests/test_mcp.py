# tests/test_mcp.py
"""MCP workflows get / watch / status / manage (Task 6) over a fake SVC: no network, no Transmission, no sleeping."""
import atexit, hashlib, itertools, json, os, re, shutil, sys, tempfile, types, unittest, urllib.error
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SEARCH = os.path.dirname(HERE)
sys.path.insert(0, SEARCH)
sys.path.insert(0, HERE)
import group, mcp  # noqa: E402
from fake_transmission import Fake  # noqa: E402

DUNE = 'Dune: Part Two'


def rel(title, seeds=50, q=1080, tv=True, dv5=False, ua=False, size=5.0, cat='', grade='g', **extra):
    """A search row as searchd hands it over (fields of tsearch.row that the picker and the MCP tools read)."""
    h = hashlib.sha1(title.encode()).hexdigest()
    r = {'title': title, 'seeds': seeds, 'quality': q, 'tv_ok': tv, 'dv5': dv5, 'ua': ua, 'audio': ['UA'] if ua else [], 'size_gb': size,
         'category': cat, 'grade': grade, 'tracker': 'fake', 'hash': h.upper(), 'magnet': 'magnet:?xt=urn:btih:%s&dn=x' % h}
    r.update(extra); return r


def card(title, kind, rows, year=''):
    return {'key': title.lower(), 'title': title, 'year': year, 'kind': kind, 'count': len(rows), 'rows': rows, 'best': rows[0]}


def pack(names, done=0):
    return [{'index': i, 'name': n, 'size': 100, 'done': done, 'wanted': True, 'priority': 0} for i, n in enumerate(names)]


class Env:
    """The SVC table searchd gives mcp.handle, with every call recorded in .calls as (name, payload)."""
    def __init__(self, works=(), tv=True, tv_reply=None, files=None, dup=(), warn=None, vanish=(), rows=(), list_error=None,
                 free=50 * 2 ** 30, alt=False, state='done', create_error=None):
        self.calls, self.works, self.files, self.dup, self.warn, self.vanish = [], list(works), files or {}, set(dup), warn, set(vanish)
        self.tv, self.tv_reply, self.rows, self.list_error, self.free, self.alt = tv, tv_reply or {'ok': True}, list(rows), list_error, free, alt
        self.by_id, self.n, self.create_error = {}, 0, create_error
        self.job = {'id': 'job1', 'state': state, 'works': self.works, 'count': sum(len(w['rows']) for w in self.works),
                    'items': [r for w in self.works for r in w['rows']], 'sources': {}}
        tr = types.SimpleNamespace(files=self._files, session=self._session, free_space=self._free)
        self.svc = {'create': self.create, 'act': self.act, 'add': self.add, 'control': self.control, 'server': self.server,
                    'client': types.SimpleNamespace(dl='/dl', tr=tr, list=self._list), 'link': 'https://x.example',
                    'downloads': lambda: {'free': 1, 'folder': '/dl', 'torrents': []}, 'sources': lambda: [{'id': 'fake'}],
                    'recent': lambda: [{'id': 'job0'}]}

    def of(self, name): return [p for n, p in self.calls if n == name]

    def create(self, b):
        self.calls.append(('create', b)); return {'error': self.create_error} if self.create_error else self.job

    def server(self): return {'name': 'Test', 'public_url': 'https://x.example', 'tv': self.tv, 'peers': [], 'vpn_sources': []}

    def act(self, b): self.calls.append(('act', b)); return self.tv_reply

    def add(self, b):
        self.calls.append(('add', b))
        h = re.search(r'btih:([0-9a-f]{40})', b['magnet'], re.I).group(1).lower()
        if h in self.dup:
            self.by_id[99] = h; return {'id': 'tr:99', 'hash': h, 'name': 'existing', 'duplicate': True}
        self.n += 1; self.by_id[self.n] = h
        out = {'id': 'tr:%d' % self.n, 'hash': h, 'name': 'T%d' % self.n, 'duplicate': False}
        if self.warn: out['warning'] = self.warn
        return out

    def control(self, tid, b):
        self.calls.append(('control', (tid, b)))
        if b.get('action') in ('remove', 'remove_data'): self.by_id.pop(int(tid.split(':')[1]), None)
        return {'ok': True, 'id': tid, 'action': b.get('action')}

    def _files(self, tid):   # as trclient.files: an unknown / removed id raises IndexError, a magnet without metadata gives []
        self.calls.append(('files', tid))
        h = self.by_id.get(tid)
        if h is None or h in self.vanish: self.by_id.pop(tid, None); raise IndexError(tid)
        return self.files.get(h, [])

    def _session(self): return {'alt-speed-enabled': self.alt}

    def _free(self, path):
        if self.free is None: raise RuntimeError('Transmission: error')
        return self.free

    def _list(self):
        if self.list_error: raise self.list_error
        return list(self.rows)


def call(env, name, args=None):
    """tools/call through mcp.handle -> (structured data, isError, the raw result)."""
    r = mcp.handle({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': name, 'arguments': args or {}}}, env.svc)['result']
    return json.loads(r['content'][0]['text']), r['isError'], r


def fast(test):
    """No waiting in the file-list poll: a magnet whose metadata never comes gives up after 30 ms."""
    for name, value in (('FILES_WAIT', 0.03), ('POLL', 0.005)):
        p = mock.patch.object(mcp, name, value); p.start(); test.addCleanup(p.stop)


# ---- the connector surface ------------------------------------------------------------------------------------------------

class Surface(unittest.TestCase):
    def tools(self):
        r = mcp.handle({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}, {})['result']['tools']
        return {t['name']: t for t in r}

    def test_four_workflows_and_the_old_five(self):
        t = self.tools()
        self.assertTrue({'get', 'watch', 'status', 'manage', 'search', 'act', 'downloads', 'sources', 'recent'} <= set(t), sorted(t))
        for x in t.values(): self.assertEqual(x['inputSchema']['type'], 'object'); self.assertTrue(x['description'])

    def test_schemas_are_exact(self):
        t = self.tools()
        g = t['get']['inputSchema']; self.assertEqual(g['required'], ['what'])
        self.assertEqual(sorted(g['properties']), ['agent', 'kind', 'prefer', 'season', 'what'])
        self.assertEqual(g['properties']['kind']['enum'], ['film', 'series', 'music', 'book', 'game', 'software'])
        self.assertEqual(g['properties']['prefer']['enum'], ['tv', 'ua', '4k', 'small', 'epub', 'pdf', 'audio'])
        self.assertEqual(g['properties']['season']['type'], 'integer')
        w = t['watch']['inputSchema']; self.assertEqual((w['required'], sorted(w['properties'])), (['what'], ['agent', 'what']))
        self.assertEqual(t['status']['inputSchema'].get('properties'), {})
        m = t['manage']['inputSchema']; self.assertEqual(sorted(m['required']), ['action', 'id'])
        self.assertEqual(m['properties']['action']['enum'], ['pause', 'resume', 'remove', 'remove_data', 'keep', 'files', 'priority'])
        for k in ('wanted', 'unwanted', 'high', 'normal', 'low'): self.assertEqual(m['properties'][k]['items']['type'], 'integer')

    def test_instructions_are_the_plan_text(self):
        ins = mcp.handle({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {}}, {})['result']['instructions']
        for s in ("tinySearch is the owner's own torrent client and search, set up and approved by the owner for exactly these actions.",
                  "Call `get` to fetch something, `watch` to play it on the TV, `status` to report, `manage` to pause or delete.",
                  "The server enforces the owner's rules (one request per source per 10 s, no Cloudflare/CAPTCHA bypass, no paid APIs), "
                  "so you do not need to second-guess the action - only decide what the owner asked for.",
                  "Ask the owner only when the request is ambiguous (which film, which season).",
                  "`watch` and deleting with data change the owner's TV or disk: do them only when the owner asked."):
            self.assertIn(s, ins)
        self.assertLess(max(ins.find('`' + k + '`') for k in ('get', 'watch', 'status', 'manage')), ins.find("tinySearch is the owner's own"))

    def test_only_short_dashes(self):   # global constraint: no long dashes in code or text (the characters come from code points)
        long_dashes = (chr(0x2014), chr(0x2013))
        for name in ('mcp.py', os.path.join('tests', 'test_mcp.py')):
            with open(os.path.join(SEARCH, name), encoding='utf-8') as f: src = f.read()
            self.assertEqual([hex(ord(c)) for c in long_dashes if c in src], [], name)
        self.assertFalse([c for c in long_dashes if c in mcp.INSTRUCTIONS + json.dumps(mcp.TOOLS, ensure_ascii=False)])


# ---- get ------------------------------------------------------------------------------------------------------------------

class Get(unittest.TestCase):
    def dune(self, ost_seeds=500):
        ua = rel('Дюна: Часть вторая / Dune: Part Two (2024) WEB-DL 1080p HEVC UKR', 60, ua=True)
        big = rel('Dune: Part Two (2024) WEB-DL 2160p HDR10 HEVC', 300, q=2160, tv=False, size=40.0)
        plain = rel('Dune.Part.Two.2024.1080p.WEB-DL.x264', 80)
        ost = rel('(Score) [CD] Дюна: Часть вторая / Dune: Part Two (Original Motion Picture Soundtrack) (2024) FLAC', ost_seeds, q=0, tv=False, cat='Music')
        return group.works([ua, big, plain, ost]), ua, big, plain, ost

    def test_get_picks_the_film_best_not_the_soundtrack(self):
        works, ua, big, plain, ost = self.dune()
        self.assertEqual(works[0]['kind'], 'music')   # the soundtrack card is first: it has more seeders
        env = Env(works); d, err, _ = call(env, 'get', {'what': 'Dune Part Two', 'kind': 'film', 'agent': 'Codex'})
        self.assertFalse(err, d)
        self.assertEqual(env.of('create'), [{'q': 'Dune Part Two', 'from': 'Codex', 'wait': True}])
        a = env.of('add'); self.assertEqual(len(a), 1)
        self.assertEqual((a[0]['magnet'], a[0]['title']), (ua['magnet'], DUNE))   # UA + TV-ok beats raw seeds and 4K
        self.assertEqual(d['picked'], {'title': ua['title'], 'size_gb': 5.0, 'seeds': 60, 'tracker': 'fake', 'quality': 1080})
        self.assertEqual(d['torrent'], {'id': 'tr:1', 'name': 'T1'}); self.assertEqual(d['where'], '/dl')
        self.assertEqual(d['link'], 'https://x.example/#job1'); self.assertNotIn('files_selected', d); self.assertEqual(env.of('control'), [])

    def test_get_without_kind_takes_the_first_card(self):
        works, ua, *_ = self.dune(ost_seeds=5)
        env = Env(works); d, err, _ = call(env, 'get', {'what': 'Dune Part Two'})
        self.assertFalse(err, d); self.assertEqual(env.of('add')[0]['magnet'], ua['magnet'])
        self.assertEqual(env.of('create')[0]['from'], 'agent (MCP)')

    def test_get_prefer_changes_the_order(self):
        works, ua, big, plain, _ = self.dune()
        env = Env(works); call(env, 'get', {'what': 'Dune', 'kind': 'film', 'prefer': '4k'})
        self.assertEqual(env.of('add')[0]['magnet'], big['magnet'])

    def test_get_music_takes_flac(self):
        flac = rel('Pink Floyd - The Wall (1979) FLAC', 40, q=0, tv=False, cat='Music'); mp3 = rel('Pink Floyd - The Wall (1979) MP3 320', 200, q=0, tv=False, cat='Music')
        env = Env(group.works([flac, mp3])); d, err, _ = call(env, 'get', {'what': 'Pink Floyd The Wall', 'kind': 'music'})
        self.assertFalse(err, d); self.assertEqual(env.of('add')[0]['magnet'], flac['magnet'])

    def test_get_kind_with_no_card_is_an_error_that_lists_what_was_found(self):
        works, *_ = self.dune(); env = Env(works)
        d, err, _ = call(env, 'get', {'what': 'Dune Part Two', 'kind': 'game'})
        self.assertTrue(err); self.assertIn('game', d['error']); self.assertEqual(env.of('add'), [])
        self.assertEqual({(f['title'], f['kind']) for f in d['found']}, {(w['title'], w['kind']) for w in works})

    def test_get_series_also_takes_a_film_card_whose_titles_show_seasons(self):
        a = rel('Game of Thrones 2011 1080p BluRay', 30); b = rel('Game of Thrones 2011 Season 1-8 1080p BluRay', 20)
        env = Env([card('Game of Thrones', 'film', [a, b], '2011')]); d, err, _ = call(env, 'get', {'what': 'Game of Thrones', 'kind': 'series'})
        self.assertFalse(err, d); self.assertEqual(len(env.of('add')), 1)
        d, err, _ = call(Env([card('Other', 'film', [rel('Other 2020 1080p')], '2020')]), 'get', {'what': 'x', 'kind': 'series'})
        self.assertTrue(err)   # a film card with no season in any title is not a series

    def test_get_nothing_found_and_search_error(self):
        d, err, _ = call(Env([]), 'get', {'what': 'zzz'}); self.assertTrue(err); self.assertIn('Нічого не знайшов', d['error'])
        d, err, _ = call(Env([], create_error='Порожній запит'), 'get', {'what': 'zzz'}); self.assertEqual((err, d['error']), (True, 'Порожній запит'))

    def test_get_validates_input(self):
        w = [card('A', 'film', [rel('A 2020 1080p')], '2020')]
        for args in ({}, {'what': '  '}, {'what': 'A', 'kind': 'cartoon'}, {'what': 'A', 'prefer': 'cheap'}, {'what': 'A', 'kind': 'film', 'season': 2},
                     {'what': 'A', 'kind': 'series', 'season': 0}, {'what': 'A', 'kind': 'series', 'season': 'two'}, {'what': 'A', 'season': True},
                     {'what': 'A', 'season': chr(0xB2)}, {'what': 'A', 'season': 2.5}, {'what': 'A', 'season': -1}):
            env = Env(w); d, err, _ = call(env, 'get', args)
            self.assertTrue(err, args); self.assertEqual((env.of('create'), env.of('add')), ([], []), args)

    def test_get_says_when_the_torrent_already_exists(self):
        r = rel('Big Buck Bunny 2008 1080p', 10); env = Env([card('Big Buck Bunny', 'film', [r], '2008')], dup=[r['hash'].lower()])
        d, err, _ = call(env, 'get', {'what': 'Big Buck Bunny', 'kind': 'film'})
        self.assertFalse(err, d); self.assertEqual(d['torrent'], {'id': 'tr:99', 'name': 'existing', 'duplicate': True}); self.assertIn('Вже є', d['note'])

    def test_get_keeps_the_add_warning_as_a_note(self):
        r = rel('Big Buck Bunny 2008 1080p', 10); env = Env([card('Big Buck Bunny', 'film', [r], '2008')], warn='Менше 10 ГБ вільно - поставив на паузу')
        d, err, _ = call(env, 'get', {'what': 'Big Buck Bunny', 'kind': 'film'})
        self.assertFalse(err, d); self.assertIn('Менше 10 ГБ', d['note'])

    def test_get_tells_when_the_search_was_still_running(self):
        r = rel('Big Buck Bunny 2008 1080p', 10); env = Env([card('Big Buck Bunny', 'film', [r], '2008')], state='run')
        d, err, _ = call(env, 'get', {'what': 'Big Buck Bunny'}); self.assertFalse(err, d); self.assertIn('Пошук', d['note'])

    def test_get_shows_the_work_and_the_runners_up(self):
        works, *_ = self.dune(); env = Env(works); d, err, _ = call(env, 'get', {'what': 'Dune', 'kind': 'film'})
        self.assertEqual(d['work'], 'Dune: Part Two (2024, film)'); self.assertEqual(d['others'], ['Dune: Part Two (2024, music)'])

    def test_transmission_down_is_a_readable_error(self):
        env = Env([card('A', 'film', [rel('A 2020 1080p')], '2020')])
        env.add = lambda b: (_ for _ in ()).throw(urllib.error.URLError('refused')); env.svc['add'] = env.add
        d, err, _ = call(env, 'get', {'what': 'A'}); self.assertTrue(err); self.assertIn('Transmission не працює', d['error'])


# ---- get with a season ----------------------------------------------------------------------------------------------------

GOT = ['Game of Thrones S01-S12 Complete/Season %d/Game.of.Thrones.S%02dE%02d.mkv' % (s, s, e)
       for s, e in [(1, 1), (1, 2), (2, 1), (2, 2), (2, 3), (10, 1), (11, 1), (12, 1)]]


class Season(unittest.TestCase):
    def setUp(self): fast(self)

    def one(self, files, title='Game of Thrones S01-S12 Complete 1080p', **kw):
        r = rel(title, 100); env = Env([card('Game of Thrones', 'series', [r], '2011')], files={r['hash'].lower(): files}, **kw)
        return env, r

    def test_season_2_marks_everything_else_unwanted(self):
        env, r = self.one(pack(GOT))
        d, err, _ = call(env, 'get', {'what': 'Game of Thrones', 'season': 2})
        self.assertFalse(err, d)
        self.assertEqual(env.of('control'), [('tr:1', {'action': 'files', 'wanted': [2, 3, 4], 'unwanted': [0, 1, 5, 6, 7]})])
        self.assertEqual((d['files_selected'], d['files_total']), (3, 8)); self.assertIn('сезон', d['note'].lower())
        self.assertEqual(env.of('add')[0]['magnet'], r['magnet']); self.assertEqual(env.of('create')[0]['q'], 'Game of Thrones')

    def test_season_1_does_not_take_season_10_11_or_the_pack_name(self):   # S1 is a prefix of S10, and the pack is called S01-S12
        env, _ = self.one(pack(GOT)); call(env, 'get', {'what': 'Game of Thrones', 'kind': 'series', 'season': 1})
        self.assertEqual(env.of('control')[0][1]['wanted'], [0, 1])
        env, _ = self.one(pack(GOT)); call(env, 'get', {'what': 'Game of Thrones', 'kind': 'series', 'season': 12})
        self.assertEqual(env.of('control')[0][1]['wanted'], [7])

    def test_season_names_in_cyrillic_and_other_spellings(self):
        names = ['Игра престолов/Сезон 2/01.mkv', 'Игра престолов/Сезон 3/01.mkv', 'Игра престолов/season_02/extra.mkv', 'Игра престолов/Season 03/x.mkv']
        env, _ = self.one(pack(names)); d, err, _ = call(env, 'get', {'what': 'Игра престолов', 'season': 2})
        self.assertFalse(err, d); self.assertEqual(env.of('control')[0][1]['wanted'], [0, 2])

    def test_a_single_season_pack_needs_no_change(self):
        names = ['Show.S02.1080p/Show.S02E01.mkv', 'Show.S02.1080p/Show.S02E02.mkv']
        env, _ = self.one(pack(names), title='Show S02 1080p'); d, err, _ = call(env, 'get', {'what': 'Show', 'season': 2})
        self.assertFalse(err, d); self.assertEqual(env.of('control'), []); self.assertEqual((d['files_selected'], d['files_total']), (2, 2))

    def test_season_named_only_by_the_top_folder(self):
        env, _ = self.one(pack(['Dune Saga Season 2/01.mkv', 'Dune Saga Season 2/02.mkv']), title='Dune Saga Season 2')
        d, err, _ = call(env, 'get', {'what': 'Dune Saga', 'season': 2}); self.assertFalse(err, d); self.assertEqual(d['files_selected'], 2)
        env, _ = self.one(pack(['Pack S01-S03/01.mkv', 'Pack S01-S03/02.mkv']), title='Pack S01-S03')   # a range in the top folder says nothing
        d, err, _ = call(env, 'get', {'what': 'Pack', 'season': 2}); self.assertTrue(err)

    def test_a_flat_single_file_torrent(self):
        env, _ = self.one(pack(['Show.S02E05.1080p.mkv']), title='Show S02E05'); d, err, _ = call(env, 'get', {'what': 'Show', 'season': 2})
        self.assertFalse(err, d); self.assertEqual(d['files_selected'], 1)

    def test_wrong_season_is_removed_from_the_list_only_and_the_next_release_is_tried(self):
        s3 = rel('Game of Thrones S03 1080p BluRay', 500); s2 = rel('Game of Thrones Season 2 1080p BluRay', 100)
        full = rel('Game of Thrones Complete Series 1080p', 20); noise = rel('Game of Thrones 2011 720p', 10)
        files = {s3['hash'].lower(): pack(['GoT.S03/GoT.S03E01.mkv', 'GoT.S03/GoT.S03E02.mkv'], done=7 * 2 ** 20),
                 s2['hash'].lower(): pack(['GoT.S02/GoT.S02E01.mkv', 'GoT.S02/GoT.S02E02.mkv', 'GoT.S02/Extras/making.mkv'])}
        env = Env([card('Game of Thrones', 'series', [s3, s2, full, noise], '2011')], files=files)
        d, err, _ = call(env, 'get', {'what': 'Game of Thrones', 'kind': 'series', 'season': 2})
        self.assertFalse(err, d)
        self.assertEqual([a['magnet'] for a in env.of('add')], [s3['magnet'], s2['magnet']])
        self.assertEqual(env.of('control'), [('tr:1', {'action': 'remove'}), ('tr:2', {'action': 'files', 'wanted': [0, 1], 'unwanted': [2]})])
        self.assertEqual((d['picked']['title'], d['torrent']['id'], d['files_selected']), (s2['title'], 'tr:2', 2))
        self.assertIn('14 МБ', d['note'])   # said aloud: the first release left a little data on disk and it was not deleted

    def test_only_one_retry(self):
        s3 = rel('Game of Thrones S03 1080p', 500); s4 = rel('Game of Thrones S04 1080p', 400); s2 = rel('Game of Thrones S02 1080p', 100)
        files = {x['hash'].lower(): pack(['p/x.S0%dE01.mkv' % n]) for n, x in ((3, s3), (4, s4))}
        files[s2['hash'].lower()] = pack(['p/x.S02E01.mkv'])
        env = Env([card('Game of Thrones', 'series', [s3, s4, s2], '2011')], files=files)
        d, err, _ = call(env, 'get', {'what': 'Game of Thrones', 'season': 2})
        # s3 first (best), then the best release that MENTIONS season 2 (s2); a pack that does not name it is never tried
        self.assertFalse(err, d); self.assertEqual([a['magnet'] for a in env.of('add')], [s3['magnet'], s2['magnet']])
        s2b = rel('Game of Thrones S02 720p', 90); files[s2b['hash'].lower()] = pack(['p/x.S05E01.mkv']); files[s2['hash'].lower()] = pack(['p/x.S05E01.mkv'])
        env = Env([card('Game of Thrones', 'series', [s3, s4, s2, s2b], '2011')], files=files)
        d, err, _ = call(env, 'get', {'what': 'Game of Thrones', 'season': 2})
        self.assertTrue(err); self.assertEqual(len(env.of('add')), 2)   # best + ONE retry, then it gives up
        self.assertEqual([c[1]['action'] for c in env.of('control')], ['remove', 'remove'])
        self.assertNotIn('remove_data', json.dumps(env.of('control')))   # never deletes data on its own

    def test_no_season_in_the_title_means_no_retry_candidate(self):
        a = rel('Show 2011 1080p', 100); b = rel('Show 2011 720p', 50)
        env = Env([card('Show', 'series', [a, b], '2011')], files={a['hash'].lower(): pack(['x/other.S09E01.mkv'])})
        d, err, _ = call(env, 'get', {'what': 'Show', 'season': 2})
        self.assertTrue(err); self.assertEqual(len(env.of('add')), 1); self.assertEqual(env.of('control'), [('tr:1', {'action': 'remove'})])
        self.assertIn('сезон', d['error'].lower())

    def test_existing_torrent_is_never_changed_or_removed(self):
        env, r = self.one(pack(GOT), dup=[rel('Game of Thrones S01-S12 Complete 1080p', 100)['hash'].lower()])
        d, err, _ = call(env, 'get', {'what': 'Game of Thrones', 'season': 2})
        self.assertFalse(err, d); self.assertEqual(env.of('control'), []); self.assertTrue(d['torrent']['duplicate']); self.assertIn('Вже є', d['note'])
        s3 = rel('Game of Thrones S03 1080p', 500); s2 = rel('Game of Thrones S02 1080p', 100)   # the owner's own wrong-season torrent stays too
        env = Env([card('Game of Thrones', 'series', [s3, s2], '2011')], dup=[s3['hash'].lower()],
                  files={s3['hash'].lower(): pack(['a.S03E01.mkv']), s2['hash'].lower(): pack(['a.S02E01.mkv'])})
        d, err, _ = call(env, 'get', {'what': 'Game of Thrones', 'season': 2})
        self.assertFalse(err, d); self.assertEqual(env.of('control'), []); self.assertEqual(d['torrent']['id'], 'tr:1')

    def test_torrent_removed_by_someone_else_while_choosing_files(self):
        env, r = self.one(pack(GOT), vanish=[rel('Game of Thrones S01-S12 Complete 1080p', 100)['hash'].lower()])
        d, err, _ = call(env, 'get', {'what': 'Game of Thrones', 'season': 2})
        self.assertTrue(err); self.assertIn('зник', d['error']); self.assertEqual(env.of('control'), []); self.assertEqual(len(env.of('add')), 1)

    def test_metadata_that_never_comes_is_a_failed_release_not_a_hang(self):
        env, r = self.one([])
        d, err, _ = call(env, 'get', {'what': 'Game of Thrones', 'season': 2})
        self.assertTrue(err); self.assertIn('метадані', d['error'].lower()); self.assertEqual(env.of('control'), [('tr:1', {'action': 'remove'})])

    def test_low_disk_warning_removes_the_paused_torrent_and_stops(self):
        env, r = self.one(pack(GOT), warn='Менше 10 ГБ вільно - поставив на паузу')
        d, err, _ = call(env, 'get', {'what': 'Game of Thrones', 'season': 2})
        self.assertTrue(err); self.assertIn('10 ГБ', d['error']); self.assertEqual(env.of('files'), [])
        self.assertEqual(env.of('control'), [('tr:1', {'action': 'remove'})]); self.assertEqual(len(env.of('add')), 1)


# ---- watch ----------------------------------------------------------------------------------------------------------------

class Watch(unittest.TestCase):
    def film(self, *rows): return [card('Dune: Part Two', 'film', list(rows), '2024')]

    def test_no_tv_here_is_refused_before_anything_else(self):
        env = Env(self.film(rel('Dune 2024 1080p')), tv=False)
        d, err, raw = call(env, 'watch', {'what': 'Dune'})
        self.assertTrue(err); self.assertEqual(d['error'], 'На цьому сервері немає ТВ'); self.assertEqual(raw['structuredContent']['error'], 'На цьому сервері немає ТВ')
        self.assertEqual((env.of('create'), env.of('act')), ([], []))

    def test_plays_the_best_tv_ok_release(self):
        big = rel('Dune 2024 2160p BDRemux', 300, q=2160, tv=False, size=60.0); b = rel('Dune 2024 1080p WEB-DL', 80)
        c = rel('Dune 2024 1080p WEB-DL UKR', 60, ua=True, topic='123', page='https://x/y')
        env = Env(self.film(big, b, c), tv_reply={'ok': True, 'playing': 'Dune'}); d, err, _ = call(env, 'watch', {'what': 'Dune', 'agent': 'Codex'})
        self.assertFalse(err, d)
        self.assertEqual(env.of('act'), [{'to': 'tv', 'magnet': c['magnet'], 'topic': '123', 'page': 'https://x/y', 'title': 'Dune: Part Two', 'from': 'Codex'}])
        self.assertEqual((d['picked']['title'], d['tv']), (c['title'], {'ok': True, 'playing': 'Dune'})); self.assertEqual(env.of('add'), [])

    def test_skips_a_soundtrack_card(self):
        ost = rel('Dune (Original Motion Picture Soundtrack) (2024) FLAC', 900, q=0, tv=False, cat='Music'); f = rel('Dune 2024 1080p WEB-DL', 20)
        env = Env([card('Dune', 'music', [ost], '2024'), card('Dune', 'film', [f], '2024')]); call(env, 'watch', {'what': 'Dune'})
        self.assertEqual(env.of('act')[0]['magnet'], f['magnet'])

    def test_tv_error_is_an_error(self):
        env = Env(self.film(rel('Dune 2024 1080p')), tv_reply={'error': 'ТВ не відповідає'}); d, err, _ = call(env, 'watch', {'what': 'Dune'})
        self.assertEqual((err, d['error']), (True, 'ТВ не відповідає'))

    def test_without_a_tv_ok_release_it_takes_the_best_that_is_not_dolby_vision_5(self):
        big = rel('Dune 2024 2160p BDRemux', 300, q=2160, tv=False, size=60.0); dv = rel('Dune 2024 2160p DV', 500, q=2160, tv=False, dv5=True)
        env = Env(self.film(dv, big)); d, err, _ = call(env, 'watch', {'what': 'Dune'})
        self.assertFalse(err, d); self.assertEqual(env.of('act')[0]['magnet'], big['magnet']); self.assertIn('TV', d['note'])
        env = Env(self.film(dv)); d, err, _ = call(env, 'watch', {'what': 'Dune'})
        self.assertTrue(err); self.assertEqual(env.of('act'), [])

    def test_no_film_found(self):
        env = Env([card('Show', 'series', [rel('Show S01 1080p')], '2020')]); d, err, _ = call(env, 'watch', {'what': 'Show'})
        self.assertTrue(err); self.assertEqual(env.of('act'), [])
        d, err, _ = call(Env(self.film(rel('x 2020 1080p'))), 'watch', {'what': ' '}); self.assertTrue(err)


# ---- status ---------------------------------------------------------------------------------------------------------------

def trow(i, state, down=0, **kw):
    r = {'id': 'tr:%d' % i, 'engine': 'transmission', 'hash': '%040x' % i, 'name': 'T%d' % i, 'size': 100, 'progress': 0.5, 'down': down, 'up': 1,
         'eta': 60, 'state': state, 'ratio': 0.1, 'path': '/dl', 'files_count': 2, 'error': ''}
    r.update(kw); return r


class Status(unittest.TestCase):
    def test_top_20_active_first_trimmed(self):
        rows = [trow(i, 'seeding') for i in range(1, 26)] + [trow(30, 'downloading', 5000), trow(31, 'paused'), trow(32, 'error')]
        rows.append({'id': 'tv:' + 'a' * 40, 'engine': 'tv', 'name': 'TV one', 'progress': 0.1, 'down': 700, 'state': 'downloading', 'eta': -1})
        env = Env(rows=rows, free=int(12.34 * 2 ** 30), alt=True); d, err, _ = call(env, 'status')
        self.assertFalse(err, d)
        self.assertEqual((len(d['torrents']), d['total']), (20, 29))
        self.assertEqual([t['id'] for t in d['torrents'][:2]], ['tr:30', 'tv:' + 'a' * 40]); self.assertEqual(d['torrents'][2]['state'], 'error')
        self.assertEqual(set(d['torrents'][0]), {'id', 'name', 'engine', 'progress', 'down', 'state', 'eta'})
        self.assertEqual((d['free_gb'], d['alt_speed'], d['where'], d['down_total']), (12.3, True, '/dl', 5700))

    def test_empty_client_and_unknown_free_space(self):
        d, err, _ = call(Env(free=None), 'status'); self.assertFalse(err, d); self.assertEqual((d['torrents'], d['total'], d['free_gb'], d['alt_speed']), ([], 0, None, False))

    def test_transmission_not_answering(self):
        d, err, _ = call(Env(list_error=urllib.error.URLError('refused')), 'status'); self.assertTrue(err); self.assertIn('Transmission не працює', d['error'])
        d, err, _ = call(Env(list_error=ConnectionRefusedError('no')), 'status'); self.assertTrue(err); self.assertIn('Transmission не працює', d['error'])


# ---- manage ---------------------------------------------------------------------------------------------------------------

class Manage(unittest.TestCase):
    def test_passes_the_body_to_control(self):
        env = Env(); d, err, _ = call(env, 'manage', {'id': 'tr:3', 'action': 'pause'})
        self.assertFalse(err, d); self.assertEqual(env.of('control'), [('tr:3', {'action': 'pause'})]); self.assertEqual(d, {'ok': True, 'id': 'tr:3', 'action': 'pause'})
        env = Env(); call(env, 'manage', {'id': 'tr:3', 'action': 'files', 'unwanted': [1, 2], 'high': [0], 'wanted': None})
        self.assertEqual(env.of('control'), [('tr:3', {'action': 'files', 'unwanted': [1, 2], 'high': [0]})])
        env = Env(); call(env, 'manage', {'id': 'tr:3', 'action': 'remove_data'}); self.assertEqual(env.of('control'), [('tr:3', {'action': 'remove_data'})])

    def test_refusals_from_control_become_errors(self):
        env = Env(); env.svc['control'] = lambda tid, b: (_ for _ in ()).throw(ValueError('Невідомий id: x'))
        d, err, _ = call(env, 'manage', {'id': 'x', 'action': 'pause'}); self.assertEqual((err, d['error']), (True, 'Невідомий id: x'))

    def test_id_and_action_are_required(self):
        for args in ({}, {'id': 'tr:1'}, {'action': 'pause'}):
            env = Env(); d, err, _ = call(env, 'manage', args); self.assertTrue(err, args); self.assertEqual(env.of('control'), [])


# ---- the low-level tools keep working -------------------------------------------------------------------------------------

class OldTools(unittest.TestCase):
    def test_search_act_and_the_listings(self):
        r = rel('Dune 2024 1080p', 10); env = Env([card('Dune', 'film', [r], '2024')])
        d, err, _ = call(env, 'search', {'query': 'Dune', 'agent': 'Codex', 'top': 5})
        self.assertFalse(err, d); self.assertEqual(env.of('create')[0]['q'], 'Dune'); self.assertEqual(d['items'][0]['title'], 'Dune 2024 1080p')
        self.assertEqual(d['link'], 'https://x.example/#job1')
        d, err, _ = call(env, 'act', {'to': 'magnet', 'magnet': r['magnet'], 'agent': 'Codex'}); self.assertFalse(err, d); self.assertEqual(env.of('act')[0]['from'], 'Codex')
        self.assertEqual(call(env, 'downloads')[0], {'free': 1, 'folder': '/dl', 'torrents': []})
        self.assertEqual(call(env, 'sources')[1], False); self.assertEqual(call(env, 'recent')[1], False)
        d, err, _ = call(env, 'nope'); self.assertTrue(err)


# ---- the workflows over the real searchd functions and a fake Transmission --------------------------------------------------

class SeasonFake(Fake):
    """A Transmission double where every added torrent is a three-season pack and the disk is roomy."""
    FILES = ['Show/Season 1/Show.S01E01.mkv', 'Show/Season 2/Show.S02E01.mkv', 'Show/Season 2/Show.S02E02.mkv', 'Show/Season 3/Show.S03E01.mkv']

    def handle(self, m, a):
        if m == 'free-space': return {'path': a['path'], 'size-bytes': 50 * 2 ** 30}
        out = super().handle(m, a)
        if m == 'torrent-add':
            for t in self.torrents.values():
                if len(t['files']) == 2:   # still the Fake's two default files
                    t['files'] = [{'name': n, 'length': 10, 'bytesCompleted': 0} for n in self.FILES]
                    t['fileStats'] = [{'wanted': True, 'priority': 0} for _ in self.FILES]
        return out

    def sent(self, method): return [c['arguments'] for c in self.calls if c['method'] == method]


class Integration(unittest.TestCase):
    """searchd's own add / control / server / client against the fake Transmission; only the search is canned."""
    COUNT = itertools.count(1)

    @classmethod
    def setUpClass(cls):
        global searchd
        cls.tmp = tempfile.mkdtemp(prefix='mcp-int-'); atexit.register(shutil.rmtree, cls.tmp, True)
        boot = os.path.join(cls.tmp, 'boot.json')
        with open(boot, 'w') as f: json.dump({'name': 'Boot', 'transmission': {'rpc': 'http://127.0.0.1:1/transmission/rpc'}}, f)
        os.environ['SEARCHD_CONFIG'] = boot   # importing searchd reads its config: never the real one, never the real Transmission
        import searchd
        cls.boot = boot

    @classmethod
    def tearDownClass(cls): searchd.configure(cls.boot)

    def setUp(self):
        self.fake = SeasonFake()
        cfg = {'name': 'Test', 'public_url': 'https://test.example', 'download_dir': '/tmp/dl-int', 'engine': None, 'core': None, 'peers': [],
               'transmission': {'rpc': self.fake.url}}
        path = os.path.join(self.tmp, 'c%d.json' % next(self.COUNT))
        with open(path, 'w') as f: json.dump(cfg, f)
        searchd.configure(path)
        self.works = []
        self.env = types.SimpleNamespace(svc=dict(searchd.SVC, create=lambda b: {'id': 'job1', 'state': 'done', 'works': self.works}))

    def serve(self, *cards): self.works[:] = cards

    def test_get_adds_to_the_configured_folder(self):
        r = rel('Big Buck Bunny 2008 1080p', 10); self.serve(card('Big Buck Bunny', 'film', [r], '2008'))
        d, err, _ = call(self.env, 'get', {'what': 'Big Buck Bunny', 'kind': 'film'})
        self.assertFalse(err, d); self.assertEqual((d['torrent']['id'], d['where'], d['link']), ('tr:1', '/tmp/dl-int', 'https://test.example/#job1'))
        a = self.fake.sent('torrent-add'); self.assertEqual((len(a), a[0]['download-dir'], a[0]['paused']), (1, '/tmp/dl-int', False))
        d, err, _ = call(self.env, 'get', {'what': 'Big Buck Bunny', 'kind': 'film'})   # the same release again
        self.assertFalse(err, d); self.assertTrue(d['torrent']['duplicate']); self.assertIn('Вже є', d['note']); self.assertEqual(len(self.fake.torrents), 1)

    def test_season_2_marks_the_other_seasons_unwanted_in_transmission(self):
        r = rel('Show S01-S03 1080p', 10); self.serve(card('Show', 'series', [r], '2020'))
        d, err, _ = call(self.env, 'get', {'what': 'Show', 'season': 2})
        self.assertFalse(err, d); self.assertEqual((d['files_selected'], d['files_total']), (2, 4))
        flags = [x['wanted'] for x in next(iter(self.fake.torrents.values()))['fileStats']]
        self.assertEqual(flags, [False, True, True, False])
        self.assertEqual(self.fake.sent('torrent-stop'), [])   # it keeps running: only the other seasons were dropped

    def test_a_pack_without_the_season_leaves_the_list_but_not_the_disk(self):
        r = rel('Show S01-S03 1080p', 10); self.serve(card('Show', 'series', [r], '2020'))
        d, err, _ = call(self.env, 'get', {'what': 'Show', 'season': 7})
        self.assertTrue(err, d); self.assertEqual(self.fake.torrents, {})
        rm = self.fake.sent('torrent-remove'); self.assertEqual([x['delete-local-data'] for x in rm], [False])

    def test_manage_and_status_over_the_real_client(self):
        r = rel('Big Buck Bunny 2008 1080p', 10); self.serve(card('Big Buck Bunny', 'film', [r], '2008'))
        tid = call(self.env, 'get', {'what': 'Big Buck Bunny'})[0]['torrent']['id']
        d, err, _ = call(self.env, 'status')
        self.assertFalse(err, d); self.assertEqual((d['total'], d['torrents'][0]['id'], d['torrents'][0]['engine'], d['free_gb'], d['alt_speed'], d['where']),
                                                   (1, tid, 'transmission', 50.0, False, '/tmp/dl-int'))
        self.fake.session['alt-speed-enabled'] = True; self.assertTrue(call(self.env, 'status')[0]['alt_speed'])
        t = next(iter(self.fake.torrents.values()))
        self.assertEqual(call(self.env, 'manage', {'id': tid, 'action': 'pause'})[0]['action'], 'pause'); self.assertEqual(t['status'], 0)
        call(self.env, 'manage', {'id': tid, 'action': 'resume'}); self.assertEqual(t['status'], 4)
        d, err, _ = call(self.env, 'manage', {'id': tid, 'action': 'remove_data'})
        self.assertFalse(err, d); self.assertEqual(self.fake.sent('torrent-remove')[-1]['delete-local-data'], True)
        self.assertEqual(call(self.env, 'status')[0]['total'], 0)
        d, err, _ = call(self.env, 'manage', {'id': 'tr:zzz', 'action': 'pause'}); self.assertTrue(err); self.assertIn('Невідомий id', d['error'])
        d, err, _ = call(self.env, 'manage', {'id': tid, 'action': 'explode'}); self.assertTrue(err)

    def test_watch_is_refused_by_a_server_without_a_tv(self):
        r = rel('Dune 2024 1080p WEB-DL', 10); self.serve(card('Dune', 'film', [r], '2024'))
        d, err, _ = call(self.env, 'watch', {'what': 'Dune'})
        self.assertEqual((err, d['error']), (True, 'На цьому сервері немає ТВ'))


# ---- season words ---------------------------------------------------------------------------------------------------------

class SeasonWords(unittest.TestCase):
    def test_seasons_in(self):
        for text, want in (('Game.of.Thrones.S02E05.1080p', {2}), ('Show S2', {2}), ('Show S10E01', {10}), ('Show S1', {1}), ('Show Season 2', {2}),
                           ('Show season_02', {2}), ('Show Season.12', {12}), ('Сезон 3', {3}), ('Игра / Game / Сезон: 1-8 / Серии: 1-73 из 73', set(range(1, 9))),
                           ('Show S01-S04 1080p', {1, 2, 3, 4}), ('Show Seasons 1-3', {1, 2, 3}), ('Show S01-03', {1, 2, 3}), ('2 сезон', {2}),
                           ('Show 2nd Season', {2}), ('Show 2024 1080p x265 DV', set()), ('Show 4K HDR10 H264 5.1', set()), ('Galaxy 2160p season', set()),
                           ('Show S100', set()), ('Sample/Subs/English.srt', set())):
            self.assertEqual(mcp.seasons_in(text)[0], want, text)

    def test_a_real_en_dash_range_in_a_title(self):   # titles in the wild write S01<en dash>S04
        dash = chr(0x2013)
        self.assertEqual(mcp.seasons_in('Show S01' + dash + 'S04 1080p')[0], {1, 2, 3, 4})
        self.assertEqual(mcp.seasons_in('Show Seasons 1 ' + dash + ' 3')[0], {1, 2, 3})
        self.assertEqual(mcp.seasons_in('Show Сезон: 1' + dash + '8')[0], set(range(1, 9)))

    def test_complete_series_markers(self):
        for text in ('Show Complete Series 1080p', 'Show The Complete Collection', 'Show All Seasons', 'Игра престолов Полный сериал', 'Show Все сезоны'):
            self.assertTrue(mcp.seasons_in(text)[1], text)
        for text in ('Show Season 2 COMPLETE', 'Show S02 Complete Season'): self.assertFalse(mcp.seasons_in(text)[1], text)
        self.assertTrue(mcp.seasons_in('Show Complete Seasons 1-4')[1])


if __name__ == '__main__':
    unittest.main()
