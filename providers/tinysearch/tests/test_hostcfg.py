# tests/test_hostcfg.py
import json, os, tempfile, unittest, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import hostcfg


def write_cfg(test, data):
    with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as f:
        json.dump(data, f)
    test.addCleanup(os.unlink, f.name)
    return f.name


class HostCfg(unittest.TestCase):
    def test_defaults_fill_missing_keys(self):
        c = hostcfg.load(write_cfg(self, {'name': 'Mac', 'transmission': {'speed_down': 5000}}))
        self.assertEqual(c['name'], 'Mac')
        self.assertEqual(c['port'], 8896)
        self.assertEqual(c['transmission']['speed_down'], 5000)
        self.assertEqual(c['transmission']['rpc'], 'http://127.0.0.1:9091/transmission/rpc')
        self.assertIsNone(c['core'])

    def test_missing_file_gives_defaults(self):
        self.assertEqual(hostcfg.load('/nonexistent/config.json')['port'], 8896)

    def test_every_documented_key_is_present(self):
        c = hostcfg.load('/nonexistent/config.json')
        for k in ('name', 'port', 'public_url', 'download_dir', 'incomplete_dir', 'engine', 'core', 'peers', 'transmission'):
            self.assertIn(k, c)
        for k in ('rpc', 'user', 'password', 'speed_down', 'speed_up', 'alt_down', 'alt_up', 'ratio', 'idle_min', 'queue'):
            self.assertIn(k, c['transmission'])

    def test_broken_or_odd_json_gives_defaults(self):
        with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as f:
            f.write('{not json')
        self.addCleanup(os.unlink, f.name)
        self.assertEqual(hostcfg.load(f.name)['port'], 8896)
        self.assertEqual(hostcfg.load(write_cfg(self, ['a', 'list']))['port'], 8896)
        self.assertEqual(hostcfg.load(write_cfg(self, {'transmission': None}))['transmission']['queue'], 3)

    def test_tilde_in_paths_is_expanded(self):
        c = hostcfg.load(write_cfg(self, {'download_dir': '~/Downloads/Torrent', 'incomplete_dir': '~/Downloads/Torrent/.incomplete'}))
        self.assertEqual(c['download_dir'], os.path.expanduser('~/Downloads/Torrent'))
        self.assertEqual(c['incomplete_dir'], os.path.expanduser('~/Downloads/Torrent/.incomplete'))
        self.assertEqual(hostcfg.load('/nonexistent/config.json')['incomplete_dir'], '')

    def test_result_is_a_copy_not_the_shared_defaults(self):
        a = hostcfg.load('/nonexistent/config.json')
        a['peers'].append({'name': 'x', 'url': 'y'})
        a['transmission']['queue'] = 99
        b = hostcfg.load('/nonexistent/config.json')
        self.assertEqual(b['peers'], [])
        self.assertEqual(b['transmission']['queue'], 3)


if __name__ == '__main__':
    unittest.main()
