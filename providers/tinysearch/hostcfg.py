"""Per-host config for tinySearch (owner 2026-10-22: the same server on core host and on this Mac).

config.json lives next to this file. It is NOT shared between hosts (deploy.sh never copies it) and may hold any subset
of the keys below; missing keys fall back to DEFAULTS. config.example.json has the core host values.

  name            label of this server in the UI and in /api/server
  port            searchd listens on 127.0.0.1:<port>; the tailnet https :8444 address points at it
  public_url      this server's tailnet address
  download_dir    Transmission download folder (on core host the TV Cast engine uses the same folder)
  incomplete_dir  folder for unfinished downloads; '' = same as download_dir
  engine          TV Cast webtorrent engine URL, or null when this host has none
  core            tinyTV core URL, or null (then "to TV" goes through a peer that has one)
  peers           the other tinySearch servers: [{"name": ..., "url": ...}]
  transmission    rpc             RPC URL (the daemon listens on 127.0.0.1 only)
                  user, password  only for a Transmission that asks for them
                  speed_down, speed_up      KB/s, 0 = no limit
                  alt_down, alt_up          KB/s in "quiet mode"
                  ratio, idle_min           stop seeding at this ratio / after this many idle minutes
                  queue                     downloads that run at the same time
"""
import copy, json, os

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULTS = {
    'name': 'tinySearch', 'port': 8896, 'public_url': '', 'download_dir': os.path.expanduser('~/Downloads/Torrent'),
    'incomplete_dir': '', 'engine': None, 'core': None, 'peers': [],
    'transmission': {'rpc': 'http://127.0.0.1:9091/transmission/rpc', 'user': '', 'password': '',
                     'speed_down': 0, 'speed_up': 2000, 'alt_down': 3000, 'alt_up': 300, 'ratio': 1.0, 'idle_min': 60, 'queue': 3},
}


def load(path=None):
    path = path or os.path.join(HERE, 'config.json')
    try:
        with open(path) as f: user = json.load(f)
    except (OSError, ValueError): user = {}
    if not isinstance(user, dict): user = {}
    c = copy.deepcopy(DEFAULTS); c.update({k: v for k, v in user.items() if k != 'transmission'})
    c['transmission'].update(user.get('transmission') or {})
    for k in ('download_dir', 'incomplete_dir'):   # Transmission does not expand "~"
        if isinstance(c[k], str): c[k] = os.path.expanduser(c[k])
    return c
