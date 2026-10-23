# trclient.py
"""Transmission RPC client (owner 2026-10-22: a real client under tinySearch). stdlib only, Python 3.9."""
import base64, json, urllib.error, urllib.request

FIELDS = ['id', 'hashString', 'name', 'totalSize', 'percentDone', 'rateDownload', 'rateUpload', 'eta', 'status',
          'uploadRatio', 'downloadDir', 'error', 'errorString', 'isFinished', 'files']
# status codes: 0 stopped, 1 check wait, 2 checking, 3 download wait, 4 downloading, 5 seed wait, 6 seeding
STATE = {0: 'paused', 1: 'checking', 2: 'checking', 3: 'queued', 4: 'downloading', 5: 'queued', 6: 'seeding'}


class Transmission:
    def __init__(self, rpc_url, user='', password=''):
        self.url, self.sid = rpc_url, ''
        self.auth = 'Basic ' + base64.b64encode(('%s:%s' % (user, password)).encode()).decode() if user else ''

    def call(self, method, **args):
        body = json.dumps({'method': method, 'arguments': args}).encode()
        for _ in range(2):   # first call learns the session id from the 409 answer
            h = {'Content-Type': 'application/json', 'X-Transmission-Session-Id': self.sid}
            if self.auth: h['Authorization'] = self.auth
            try:
                with urllib.request.urlopen(urllib.request.Request(self.url, data=body, headers=h), timeout=15) as r:
                    d = json.loads(r.read())
                if d.get('result') != 'success': raise RuntimeError('Transmission: ' + str(d.get('result')))
                return d.get('arguments') or {}
            except urllib.error.HTTPError as e:
                if e.code != 409: raise
                self.sid = e.headers.get('X-Transmission-Session-Id', '')
        raise RuntimeError('Transmission: немає session id')

    def add(self, magnet, download_dir=None, paused=False, unwanted=None):
        a = {'filename': magnet, 'paused': paused}
        if download_dir: a['download-dir'] = download_dir
        if unwanted: a['files-unwanted'] = list(unwanted)
        r = self.call('torrent-add', **a); t = r.get('torrent-added') or r.get('torrent-duplicate') or {}
        return {'id': t.get('id'), 'hash': (t.get('hashString') or '').lower(), 'name': t.get('name', ''), 'duplicate': 'torrent-duplicate' in r}

    def list(self, ids=None):
        a = {'fields': FIELDS}
        if ids: a['ids'] = ids
        out = []
        for t in self.call('torrent-get', **a).get('torrents', []):
            st = 'error' if t.get('error') else 'done' if t.get('isFinished') else STATE.get(t.get('status'), 'paused')
            out.append({'id': t['id'], 'hash': t['hashString'].lower(), 'name': t['name'], 'size': t.get('totalSize', 0),
                        'progress': round(t.get('percentDone', 0), 4), 'down': t.get('rateDownload', 0), 'up': t.get('rateUpload', 0),
                        'eta': t.get('eta', -1), 'state': st, 'ratio': round(t.get('uploadRatio', 0), 2),
                        'path': t.get('downloadDir', ''), 'files_count': len(t.get('files') or []), 'error': t.get('errorString', '')})
        return out

    def files(self, tid):
        t = self.call('torrent-get', ids=[tid], fields=['files', 'fileStats'])['torrents'][0]
        return [{'index': i, 'name': f['name'], 'size': f['length'], 'done': f['bytesCompleted'],
                 'wanted': s['wanted'], 'priority': s['priority']} for i, (f, s) in enumerate(zip(t['files'], t['fileStats']))]

    def set_files(self, tid, wanted=None, unwanted=None, high=None, normal=None, low=None):
        a = {'ids': [tid]}
        for k, v in (('files-wanted', wanted), ('files-unwanted', unwanted), ('priority-high', high),
                     ('priority-normal', normal), ('priority-low', low)):
            if v: a[k] = list(v)
        self.call('torrent-set', **a)

    def start(self, ids): self.call('torrent-start', ids=list(ids))
    def stop(self, ids): self.call('torrent-stop', ids=list(ids))
    def remove(self, ids, delete_data=False): self.call('torrent-remove', ids=list(ids), **{'delete-local-data': delete_data})
    def session(self): return self.call('session-get')
    def set_session(self, **kw): self.call('session-set', **kw)
    def free_space(self, path): return self.call('free-space', path=path).get('size-bytes', 0)
