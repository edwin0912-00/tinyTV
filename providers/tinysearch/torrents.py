"""One list of torrents: Transmission ("Скачати") + the TV Cast engine ("Дивитись") - owner 2026-10-22, option 1A."""
import json, urllib.request
from trclient import Transmission


def _get(url, timeout=5):
    with urllib.request.urlopen(url, timeout=timeout) as r: return json.loads(r.read())


def _post(url, data, timeout=10):
    r = urllib.request.Request(url, data=json.dumps(data).encode(), headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(r, timeout=timeout) as x: return x.read()


class Client:
    def __init__(self, cfg):
        t = cfg['transmission']; self.tr = Transmission(t['rpc'], t.get('user', ''), t.get('password', ''))
        self.engine, self.dl = cfg.get('engine'), cfg.get('download_dir')

    def engine_list(self):
        if not self.engine: return {'torrents': []}
        try: return _get(self.engine + '/list')
        except Exception: return {'torrents': []}

    def list(self):
        rows = [dict(r, id='tr:%d' % r['id'], engine='transmission') for r in self.tr.list()]
        seen = {r['hash'] for r in rows}; e = self.engine_list()
        for t in e.get('torrents', []):
            h = t['hash'].lower()
            if h in seen: continue
            rows.append({'id': 'tv:' + h, 'engine': 'tv', 'hash': h, 'name': t['name'], 'size': t.get('size', 0),
                         'progress': t.get('progress', 0), 'down': t.get('down', 0), 'up': t.get('up', 0), 'eta': -1,
                         'state': 'done' if t.get('done') else 'paused' if t.get('paused') else 'downloading',
                         'ratio': 0, 'path': e.get('folder', ''), 'files_count': 0, 'magnet': t.get('magnet', '')})
        return rows

    def have(self, hashes):
        want = {h.lower() for h in hashes if h}
        return {r['hash']: {'engine': r['engine'], 'id': r['id'], 'progress': r['progress'], 'state': r['state']}
                for r in self.list() if r['hash'] in want}

    def keep(self, h):
        h = h.lower(); e = self.engine_list()
        t = next((x for x in e.get('torrents', []) if x['hash'].lower() == h), None)
        if not t: raise ValueError('Немає такого торента на рушії ТВ')
        added = self.tr.add(t['magnet'], download_dir=e.get('folder'))   # same folder: Transmission verifies, no re-download
        urllib.request.urlopen(urllib.request.Request(self.engine + '/remove?hash=%s&files=0' % h, data=b'', method='POST'), timeout=10)
        return next(r for r in self.list() if r['hash'] == added['hash'])
