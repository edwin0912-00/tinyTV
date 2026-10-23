# tests/test_trclient.py
import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fake_transmission import Fake
from trclient import Transmission

M = 'magnet:?xt=urn:btih:DD8255ECDC7CA55FB0BBF81323D87062DB1F6D1C&dn=Big+Buck+Bunny'

class TrClient(unittest.TestCase):
    def setUp(self): self.f = Fake(); self.t = Transmission(self.f.url)

    def test_add_and_list(self):
        r = self.t.add(M, unwanted=[1])
        self.assertEqual(r['hash'], 'dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c'); self.assertFalse(r['duplicate'])
        row = self.t.list()[0]
        self.assertEqual((row['name'], row['progress'], row['state'], row['files_count']), ('Big Buck Bunny', 0.5, 'downloading', 2))
        self.assertFalse(self.t.files(r['id'])[1]['wanted'])

    def test_duplicate(self):
        self.t.add(M); self.assertTrue(self.t.add(M)['duplicate'])

    def test_stop_start_remove(self):
        i = self.t.add(M)['id']; self.t.stop([i]); self.assertEqual(self.t.list()[0]['state'], 'paused')
        self.t.start([i]); self.assertEqual(self.t.list()[0]['state'], 'downloading')
        self.t.remove([i], delete_data=True); self.assertEqual(self.t.list(), [])
        self.assertTrue([c for c in self.f.calls if c['method'] == 'torrent-remove'][-1]['arguments']['delete-local-data'])

    def test_files_priority_and_session(self):
        i = self.t.add(M)['id']; self.t.set_files(i, high=[0]); self.assertEqual(self.t.files(i)[0]['priority'], 1)
        self.t.set_session(**{'alt-speed-enabled': True}); self.assertTrue(self.t.session()['alt-speed-enabled'])
        self.assertEqual(self.t.free_space('/tmp'), 123456789)

if __name__ == '__main__':
    unittest.main()
