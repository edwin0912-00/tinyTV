#!/usr/bin/env python3
"""Secret and personal-data scan before a commit. Exit 1 on any hit.
  python3 scripts/secret-scan.py [DIR]
Finds: key/cert files, private keys, token-like values, emails, home paths, tailnet host names, LAN addresses
outside the documentation examples, MAC addresses outside the examples. Skips build/, node_modules/, .git/."""
import re, sys, pathlib

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.')
SECRET_FILES = {'.p12', '.pem', '.cer', '.key', '.pkcs8', '.mobileprovision'}
SECRET_NAMES = {'config.json', 'kino.json', 'shortcuts.json', 'session.json', 'pin.txt', 'token', '.env'}
EXAMPLE_IPS = {'192.168.0.2', '127.0.0.1', '0.0.0.0', '255.255.255.255'}
EXAMPLE_MACS = {'aabbccddeeff', '112233445566', '223344556677', '000000000000', 'ffffffffffff'}
PAT = [
    ('private key', re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----')),
    ('token-like', re.compile(r'(?i)(?:bearer\s+[A-Za-z0-9._-]{24,}|(?:api[_-]?key|secret|token|passw(?:or)?d)["\']?\s*[:=]\s*["\'][A-Za-z0-9._/+-]{16,}["\'])')),
    ('email', re.compile(r'(?i)\b[\w.+-]+@(?!example\.com|users\.noreply\.github\.com|anthropic\.com)[\w-]+\.(?:com|net|org|io|me|ua|ru|es|de)\b')),
    ('home path', re.compile(r'/Users/(?!Shared\b)[a-z][\w.-]+|/home/[a-z][\w.-]+')),
    ('tailnet host', re.compile(r'\b[a-z0-9-]+\.tail[0-9a-f]{4,}\.ts\.net\b')),
    ('LAN address', re.compile(r'\b(?:192\.168|10\.\d{1,3})\.\d{1,3}\.\d{1,3}\b')),
    ('tailscale IP', re.compile(r'\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b')),
    ('MAC address', re.compile(r'\b[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}\b|\b[0-9a-f]{12}\b')),
]
hits = 0
for p in sorted(ROOT.rglob('*')):
    parts = p.relative_to(ROOT).parts
    if not p.is_file() or any(x in parts for x in ('build', 'node_modules', '.git', '__pycache__')): continue
    rel = '/'.join(parts)
    if p.suffix in SECRET_FILES or p.name in SECRET_NAMES:
        print(f'secret file    {rel}'); hits += 1; continue
    try: text = p.read_text()
    except (UnicodeDecodeError, OSError): continue
    for n, line in enumerate(text.split('\n'), 1):
        for name, rx in PAT:
            for m in rx.finditer(line):
                v = m.group(0)
                if name == 'LAN address' and (v in EXAMPLE_IPS or v.endswith('.255') or v.endswith('.0') or v.endswith('.1')): continue
                if name == 'MAC address':
                    h = v.replace(':', '').lower()
                    if h in EXAMPLE_MACS or not re.search(r'[a-f]', h) or not re.search(r'\d', h): continue
                print(f'{name:14} {rel}:{n}: {line.strip()[:110]}'); hits += 1
print(f'secret-scan: {hits} hit(s)')
sys.exit(1 if hits else 0)
