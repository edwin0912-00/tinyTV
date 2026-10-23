# tests/fake_transmission.py
"""Minimal Transmission RPC double: 409 + X-Transmission-Session-Id handshake, a few methods, in memory."""
import json, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Fake:
    def __init__(self):
        self.torrents, self.session, self.calls = {}, {'download-dir': '/tmp/dl', 'alt-speed-enabled': False}, []
        h = self
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                if self.headers.get('X-Transmission-Session-Id') != 'sid1':
                    self.send_response(409); self.send_header('X-Transmission-Session-Id', 'sid1'); self.end_headers(); return
                req = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                h.calls.append(req); out = h.handle(req['method'], req.get('arguments') or {})
                body = json.dumps({'result': 'success', 'arguments': out}).encode()
                self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
            def log_message(self, *a): pass
        self.srv = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.url = 'http://127.0.0.1:%d/transmission/rpc' % self.srv.server_port
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def handle(self, m, a):
        if m == 'torrent-add':
            h = a['filename'].split('btih:')[1][:40].lower()
            if h in self.torrents: return {'torrent-duplicate': {'id': self.torrents[h]['id'], 'hashString': h, 'name': 'x'}}
            t = {'id': len(self.torrents) + 1, 'hashString': h, 'name': 'Big Buck Bunny', 'totalSize': 100, 'percentDone': 0.5,
                 'rateDownload': 2048, 'rateUpload': 0, 'eta': 30, 'status': 0 if a.get('paused') else 4, 'uploadRatio': 0.0,
                 'downloadDir': a.get('download-dir', '/tmp/dl'), 'error': 0, 'errorString': '', 'isFinished': False,
                 'files': [{'name': 'a.mkv', 'length': 60, 'bytesCompleted': 30}, {'name': 'b.srt', 'length': 40, 'bytesCompleted': 40}],
                 'fileStats': [{'wanted': True, 'priority': 0}, {'wanted': True, 'priority': 0}]}
            for i in a.get('files-unwanted', []): t['fileStats'][i]['wanted'] = False
            self.torrents[h] = t; return {'torrent-added': {'id': t['id'], 'hashString': h, 'name': t['name']}}
        if m == 'torrent-get':
            ts = [t for t in self.torrents.values() if not a.get('ids') or t['id'] in a['ids']]
            return {'torrents': [{k: t[k] for k in a['fields'] if k in t} for t in ts]}
        if m in ('torrent-start', 'torrent-stop'):
            for t in self.torrents.values():
                if t['id'] in a['ids']: t['status'] = 4 if m == 'torrent-start' else 0
            return {}
        if m == 'torrent-remove':
            self.torrents = {k: t for k, t in self.torrents.items() if t['id'] not in a['ids']}; return {}
        if m == 'torrent-set':
            for t in self.torrents.values():
                if t['id'] in a['ids']:
                    for i in a.get('files-unwanted', []): t['fileStats'][i]['wanted'] = False
                    for i in a.get('files-wanted', []): t['fileStats'][i]['wanted'] = True
                    for i in a.get('priority-high', []): t['fileStats'][i]['priority'] = 1
            return {}
        if m == 'session-get': return dict(self.session)
        if m == 'session-set': self.session.update(a); return {}
        if m == 'free-space': return {'path': a['path'], 'size-bytes': 123456789}
        return {}
