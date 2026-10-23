"""Best release per kind (owner 2026-10-22: agents and the UI take one release without asking)."""
import re

def kind(r):
    s = (r.get('title', '') + ' ' + (r.get('category') or '')).lower()
    if re.search(r'\bflac\b|\bmp3\b|\balac\b|discograph|дискограф|\bmusic\b|lossless|\bost\b|\bvinyl\b', s): return 'music'
    if re.search(r'\bepub\b|\bpdf\b|\bfb2\b|\bmobi\b|книг|audiobook|аудиокниг|\bbooks?\b|literature|\bchm\b|\bdjvu\b|психолог|психотерап', s): return 'book'
    video = re.search(r'\b(2160p|1080p|720p|480p|bdremux|web-?dl|webrip|bluray|hdtv)\b', s)
    if not video and re.search(r'repack|fitgirl|\bgog\b|\bgames?\b|\bigr|игр|\bcodex\b|update only|\bplaza\b|\bps[45]\b|\bswitch\b', s): return 'game'
    if not video and re.search(r'\bx64\b|portable|multilingual|crack|\bapps?\b|программ|софт|\bmacos\b|\bwindows\b', s): return 'software'
    if re.search(r'\bs\d{1,2}(e\d{1,3})?\b|season|сезон|серии|серии|\bseries\b|\btv\b', s): return 'series'
    if r.get('quality') or re.search(r'\b(19|20)\d{2}\b', s): return 'film'
    return 'other'

def _score(r, k, prefer):
    g = {'g': 0, 'y': 1, 'u': 1, 'r': 2}.get(r.get('grade'), 2); s = r.get('seeds', 0); t = r.get('title', '').lower()
    if k in ('film', 'series'):
        tv = 0 if r.get('tv_ok') else 1 if not r.get('dv5') else 3
        ua = 0 if r.get('ua') or 'UA' in (r.get('audio') or []) else 1
        q = -(r.get('quality') or 0)
        if prefer == 'small': return (g, ua, tv, r.get('size_gb') or 999, -s)
        if prefer == '4k': return (g, 0 if r.get('quality') == 2160 else 1, tv, ua, -s)
        if prefer == 'ua': return (g, ua, tv, q, -s)
        return (g, tv, ua, q, -s)
    if k == 'music': return (g, 0 if 'flac' in t else 1 if '320' in t else 2, -s)
    if k == 'book':
        f = {'epub': 0, 'pdf': 1}.get(prefer or 'epub', 0)
        return (g, 0 if (prefer == 'audio') == bool(re.search(r'audio|аудио|m4b|mp3', t)) else 1, 0 if ('epub', 'pdf')[f] in t else 1, -s)
    return (g, -s)

def best(rows, k=None, prefer=None):
    if not rows: return None
    k = k or kind(rows[0])
    return min(rows, key=lambda r: _score(r, k, prefer))
