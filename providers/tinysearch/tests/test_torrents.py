import json, os, sys, threading, unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fake_transmission import Fake
import torrents

H = 'dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c'
class Engine:
    def __init__(self):
        self.removed = []; e = self
        class Hd(BaseHTTPRequestHandler):
            def do_GET(self):
                b = json.dumps({'folder': '/tmp/tv', 'free': 1, 'torrents': [{'hash': H, 'name': 'BBB', 'size': 100, 'progress': 1,
                     'down': 0, 'up': 5, 'peers': 3, 'active': True, 'paused': False, 'done': True,
                     'magnet': 'magnet:?xt=urn:btih:' + H}]}).encode()
                self.send_response(200); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
            def do_POST(self):
                from urllib.parse import urlparse, parse_qs
                q = parse_qs(urlparse(self.path).query); e.removed.append({k: v[0] for k, v in q.items()})
                self.send_response(200); self.end_headers()
            def log_message(self, *a): pass
        self.srv = ThreadingHTTPServer(('127.0.0.1', 0), Hd); self.url = 'http://127.0.0.1:%d' % self.srv.server_port
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

class OneList(unittest.TestCase):
    def setUp(self):
        self.f, self.e = Fake(), Engine()
        self.c = torrents.Client({'transmission': {'rpc': self.f.url, 'user': '', 'password': ''}, 'engine': self.e.url, 'download_dir': '/tmp/dl'})

    def test_tv_row_present(self):
        rows = self.c.list(); self.assertEqual([(r['engine'], r['id']) for r in rows], [('tv', 'tv:' + H)])

    def test_keep_moves_to_transmission_without_deleting(self):
        r = self.c.keep(H)
        self.assertEqual(r['engine'], 'transmission')
        adds = [c for c in self.f.calls if c['method'] == 'torrent-add']
        self.assertEqual(adds[-1]['arguments']['download-dir'], '/tmp/tv')
        self.assertEqual(self.e.removed[-1], {'hash': H, 'files': '0'})
        self.assertEqual([x['engine'] for x in self.c.list()], ['transmission'])

    def test_have(self):
        self.assertEqual(self.c.have([H.upper(), 'ff' * 20])[H]['engine'], 'tv')

if __name__ == '__main__':
    unittest.main()
