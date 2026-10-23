#!/bin/zsh
# install.sh - tinySearch server on THIS Mac (the same script serves core host and the owner's Mac):
#   1. Homebrew formula transmission-cli (Transmission 4.x)
#   2. launchd agent dev.tinytv.transmission: transmission-daemon, RPC on 127.0.0.1:9091 only, settings from config.json
#   3. launchd agent dev.tinytv.searchd: searchd.py (a running searchd is NOT restarted while its plist is unchanged)
#   4. tailnet https :8444 -> searchd (tailscale serve, tailnet only)
# Run it on the host itself, in ~/tinyTV/search. Without config.json it copies config.example.json and stops: edit, run again.
# Safe to re-run; it restarts Transmission for a few seconds (settings.json is rewritten while the daemon is stopped).
set -eu
cd "${0:A:h}"
BREW=/opt/homebrew/bin/brew; PY=/usr/bin/python3; TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
UIDN=$(id -u); LA=$HOME/Library/LaunchAgents; LOGS=$HOME/Library/Logs
TD="$HOME/Library/Application Support/tinySearch/transmission"   # Transmission config dir: settings.json, resume files
RPC=http://127.0.0.1:9091/transmission/rpc
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1
nap() { $PY -c 'import time;time.sleep(1)'; }
die() { echo "install.sh: $*" >&2; exit 1; }

[ -x $BREW ] || die "Homebrew not found at $BREW"
[ -f config.json ] || { cp config.example.json config.json; echo "config.json created from config.example.json: edit it, then run install.sh again"; exit 1; }
CFG=$($PY -c 'import hostcfg,json;print(json.dumps(hostcfg.load()))')
cfg() { $PY -c 'import json,sys;v=json.loads(sys.argv[1])[sys.argv[2]];print("" if v is None else v)' "$CFG" "$1"; }
DL=$(cfg download_dir); INC=$(cfg incomplete_dir); PORT=$(cfg port)
[ -n "$DL" ] || die "download_dir is empty in config.json"
mkdir -p "$DL" "$LOGS" "$LA" "$TD" || die "cannot create $DL (is the disk mounted?)"
[ -z "$INC" ] || mkdir -p "$INC"

# Transmission: brew formula transmission-cli. TDAEMON=/path/to/transmission-daemon skips brew (a daemon installed or built
# some other way). Homebrew on core host lives on External (/opt/homebrew/* are symlinks), so brew sees the long prefix
# /Volumes/External/.../homebrew: it cannot pour the transmission-cli bottle there (it cannot relocate /opt/homebrew into a
# longer prefix) and would build from source. That is heavy for core host, so install.sh stops and says what to run.
if [ -z "${TDAEMON:-}" ]; then
  TDAEMON=/opt/homebrew/bin/transmission-daemon
  if [ ! -x $TDAEMON ]; then
    PREFIX=$($BREW --prefix)
    if [ "$PREFIX" != /opt/homebrew ]; then
      echo "install.sh: Homebrew prefix is $PREFIX, not /opt/homebrew, so brew would build transmission-cli from source (heavy)." >&2
      echo "  Build it once, at a quiet moment, then run install.sh again:" >&2
      echo "  HOMEBREW_MAKE_JOBS=2 nice -n 15 $BREW install --build-from-source --ignore-dependencies transmission-cli" >&2
      exit 1
    fi
    $BREW install transmission-cli
  fi
fi
[ -x $TDAEMON ] || die "transmission-daemon not found at $TDAEMON"

plist() {   # plist LABEL LOG ARGS(<string> items): same layout as dev.tinytv.searchd.plist
  cat <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$1</string>
<key>ProgramArguments</key><array>$3</array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>$2</string>
<key>StandardErrorPath</key><string>$2</string>
</dict></plist>
P
}
write_plist() {   # write_plist LABEL LOG ARGS: sets CHANGED=1 when the plist on disk is new or different
  local f=$LA/$1.plist
  plist "$1" "$2" "$3" > "$f.new"
  if cmp -s "$f.new" "$f"; then rm -f "$f.new"; CHANGED=0; else mv "$f.new" "$f"; CHANGED=1; fi
  chmod 644 "$f"
}
boot() {   # boot LABEL: (re)load the launchd agent
  local i
  launchctl bootout gui/$UIDN/$1 2>/dev/null || true
  for i in {1..10}; do launchctl bootstrap gui/$UIDN $LA/$1.plist 2>/dev/null && return 0; nap; done
  launchctl bootstrap gui/$UIDN $LA/$1.plist   # last try, prints the reason
}

# settings.json is written while the daemon is stopped (Transmission rewrites it on exit)
launchctl bootout gui/$UIDN/dev.tinytv.transmission 2>/dev/null || true
for i in {1..30}; do pgrep -f "transmission-daemon .*-g $TD" >/dev/null || break; nap; done
$PY - "$TD/settings.json" <<'PY'
import json, os, sys
sys.path.insert(0, os.getcwd())
import hostcfg
c = hostcfg.load(); t = c['transmission']; p = sys.argv[1]
try:
    with open(p) as f: s = json.load(f)
except (OSError, ValueError): s = {}
s.update({'rpc-bind-address': '127.0.0.1', 'rpc-port': 9091, 'rpc-whitelist-enabled': True, 'rpc-whitelist': '127.0.0.1',
          'rpc-authentication-required': False, 'download-dir': c['download_dir'],
          'incomplete-dir': c['incomplete_dir'] or c['download_dir'], 'incomplete-dir-enabled': bool(c['incomplete_dir']),
          'speed-limit-down': t['speed_down'], 'speed-limit-down-enabled': t['speed_down'] > 0,
          'speed-limit-up': t['speed_up'], 'speed-limit-up-enabled': t['speed_up'] > 0,
          'alt-speed-down': t['alt_down'], 'alt-speed-up': t['alt_up'], 'ratio-limit': t['ratio'], 'ratio-limit-enabled': True,
          'idle-seeding-limit': t['idle_min'], 'idle-seeding-limit-enabled': True, 'download-queue-size': t['queue'],
          'download-queue-enabled': True, 'umask': '022'})
tmp = p + '.new'
with open(tmp, 'w') as f: json.dump(s, f, indent=1)
os.chmod(tmp, 0o600); os.replace(tmp, p)
PY
# --log-level=warn: at info level the log gets two port-forwarding lines every 8 s on a network without UPnP/NAT-PMP
write_plist dev.tinytv.transmission "$LOGS/transmission.log" "<string>$TDAEMON</string><string>-f</string><string>-g</string><string>$TD</string><string>--log-level=warn</string>"
boot dev.tinytv.transmission

# searchd: leave a running one alone when nothing about its launch changed
write_plist dev.tinytv.searchd "$LOGS/searchd.log" "<string>$PY</string><string>$PWD/searchd.py</string>"
if [ $CHANGED = 1 ] || ! launchctl print gui/$UIDN/dev.tinytv.searchd >/dev/null 2>&1; then
  boot dev.tinytv.searchd; echo "dev.tinytv.searchd: (re)loaded"
else
  echo "dev.tinytv.searchd: plist unchanged and loaded, left running"
fi

if [ -x $TS ]; then
  $TS serve status 2>/dev/null | grep -q ":8444" || $TS serve --bg --https=8444 http://127.0.0.1:$PORT </dev/null \
    || echo "WARN: tailscale serve failed; run by hand: $TS serve --bg --https=8444 http://127.0.0.1:$PORT"
else
  echo "WARN: Tailscale.app not found, no tailnet address"
fi

# smoke check: searchd answers, Transmission answers 409 on 127.0.0.1 only
rc=0; code=000
for i in {1..30}; do curl -s -o /dev/null -m 2 http://127.0.0.1:$PORT/api/sources && break; nap; done
for i in {1..30}; do code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' $RPC || true); [ "$code" = 409 ] && break; nap; done
echo "$($TDAEMON --version 2>&1 | head -1)"
echo "searchd /api/sources $(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:$PORT/api/sources || true)"
echo "searchd /api/server $(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:$PORT/api/server || true) (404 until the client API exists)"
echo "transmission rpc $code (409 = alive)"
[ "$code" = 409 ] || { echo "install.sh: Transmission RPC is not answering on $RPC, see $LOGS/transmission.log" >&2; rc=1; }
EXPOSED=$(lsof -nP -iTCP:9091 -sTCP:LISTEN -Fn 2>/dev/null | grep '^n' | grep -v '^n127.0.0.1:9091$' || true)
[ -z "$EXPOSED" ] || { echo "install.sh: RPC port 9091 listens beyond 127.0.0.1: $EXPOSED" >&2; rc=1; }
exit $rc
