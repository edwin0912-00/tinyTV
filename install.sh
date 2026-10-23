#!/bin/zsh
# tinyTV installer for the core host (an always-on Mac). One command, safe to run again:
#   ./install.sh                     check, install missing tools (asks before brew), build, start, find the TV
#   ./install.sh --dry-run           print every step, change nothing
#   ./install.sh --yes               no questions (brew installs run)
#   ./install.sh --with hdrezka,trackers,tinysearch    optional providers (off by default, see providers/README.md)
#   ./install.sh --pair              run Hisense pairing now (needs your certificate, docs/hisense-pairing.md)
#   ./install.sh --tailscale         also publish the remote on your tailnet (https :8443)
# Never overwrites an existing config.json; LaunchAgents are rewritten and restarted only when they change.
set -u; setopt pipefail
cd "${0:A:h}"
ROOT=$PWD
DRY=0; YES=0; PAIR=0; TS=0; FORCE=0; WITH=""
for a in "$@"; do
  case $a in
    --dry-run) DRY=1 ;; --yes|-y) YES=1 ;; --pair) PAIR=1 ;; --tailscale) TS=1 ;; --force) FORCE=1 ;;
    --with=*) WITH=${a#--with=} ;; --with) ;;
    --help|-h) sed -n '2,9p' $0; exit 0 ;;
    *) [[ ${prev:-} = --with ]] && WITH=$a || { echo "unknown option: $a"; exit 2; } ;;
  esac
  prev=$a
done
WITH=${WITH//,/ }
VERSION=$(cat VERSION 2>/dev/null || echo 0.3.0)
SUP="$HOME/Library/Application Support/tinyTV"; LA=$HOME/Library/LaunchAgents; LOGS=$HOME/Library/Logs
APPS=$HOME/Applications/tinyTV
ok()   { print -P "%F{green}✓%f $*"; }
warn() { print -P "%F{yellow}!%f $*"; }
die()  { print -P "%F{red}✗%f $*"; exit 1; }
step() { print -P "\n%B$*%b"; }
run()  { if (( DRY )); then echo "  [dry-run] $*"; else eval "$@"; fi }
ask()  { (( YES )) && return 0; (( DRY )) && return 1; read -q "?$1 [y/N] " r; echo; [[ $r = y ]] }

print -P "%BtinyTV $VERSION installer%b$( (( DRY )) && echo '  (dry run: nothing changes)')"

# 1. This machine
step "1. Machine"
[[ $(uname) = Darwin ]] || die "The core runs on macOS. On Linux run only the engine: node engine/server.mjs (see README)."
MAJ=$(sw_vers -productVersion | cut -d. -f1); (( MAJ >= 14 )) || die "macOS 14 or newer needed (this is $(sw_vers -productVersion))."
[[ $(uname -m) = arm64 ]] || die "Apple silicon (arm64) needed: scripts/build.sh targets arm64."
ok "macOS $(sw_vers -productVersion), $(uname -m)"
if xcode-select -p >/dev/null 2>&1 && command -v swiftc >/dev/null; then ok "Swift $(swiftc --version 2>&1 | head -1 | sed -E 's/.*Swift version ([0-9.]+).*/\1/')"
else warn "Xcode command line tools missing"; run "xcode-select --install"; die "Install the command line tools, then run ./install.sh again."; fi

# 2. Tools
step "2. Tools: node, ffmpeg, yt-dlp, python3"
need=()
for t in node ffmpeg yt-dlp; do command -v $t >/dev/null && ok "$t" || need+=$t; done
[[ -x /usr/bin/python3 ]] && ok "python3 (/usr/bin)" || warn "python3 missing: discover.py and helpers need /usr/bin/python3"
if (( ${#need} )); then
  command -v brew >/dev/null || die "Missing: ${need[*]}. Install Homebrew (https://brew.sh) or the tools, then run again."
  if ask "Install ${need[*]} with Homebrew?"; then run "brew install ${need[*]}"
  elif (( DRY )); then echo "  [dry-run] brew install ${need[*]}"
  else die "Missing: ${need[*]}"; fi
fi
NODE_MAJ=$(node -v 2>/dev/null | sed -E 's/v([0-9]+).*/\1/'); [[ -z $NODE_MAJ ]] || (( NODE_MAJ >= 18 )) || die "Node 18+ needed (have $(node -v))."

# 3. Engine dependencies
step "3. Torrent engine (engine/, webtorrent)"
if [[ -d engine/node_modules/webtorrent ]]; then ok "engine/node_modules present"
else run "(cd engine && npm install --omit=dev --no-audit --no-fund)"; fi

# 4. Build and sign
step "4. Build (providers: ${WITH:-none})"
for p in ${=WITH}; do [[ $p = tinysearch || -d providers/$p ]] || die "no provider: $p"; done
SWIFT_PROVIDERS=${${=WITH}:#tinysearch}
run "PROVIDERS='${SWIFT_PROVIDERS}' VERSION=$VERSION scripts/build.sh | tail -2" || die "build failed: run scripts/build.sh to see the errors"
run "mkdir -p '$APPS' && rsync -a --delete build/tinyTVCore.app build/tinyTV.app '$APPS/'"
(( DRY )) || ok "apps in $APPS"

# 5. Config (never overwritten)
step "5. Config and TV"
# A config with "core" means this Mac is a remote of another core: a second core here would fight it for the TV.
if [[ -f "$SUP/config.json" ]] && grep -q '"core"' "$SUP/config.json"; then
  (( FORCE )) || die "This Mac is a remote (config has \"core\"): its core runs elsewhere. Use the menu bar app only, or --force."
fi
if [[ -f "$SUP/config.json" ]]; then ok "keeping $SUP/config.json"; run "node scripts/tinytv-setup.mjs config --write >/dev/null"
else run "node scripts/tinytv-setup.mjs config --write" || warn "no TV found now: write $SUP/config.json by hand (config.core.example.json)"; fi
if [[ -f "$SUP/remotenow.p12" || -f certs/remotenow.p12 ]]; then ok "Hisense client certificate present"
else warn "no Hisense client certificate: TV keys stay off until you follow docs/hisense-pairing.md (casting works without it)"; fi

# 6. LaunchAgents (rewritten and restarted only when they change)
step "6. Services"
agent() {   # agent LABEL LOG ARGS...
  local label=$1 log=$2; shift 2
  local f=$LA/$label.plist args="" a
  for a in "$@"; do args+="<string>$a</string>"; done
  local body="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array>$args</array>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ProcessType</key><string>Interactive</string>
<key>StandardOutPath</key><string>$LOGS/$log</string><key>StandardErrorPath</key><string>$LOGS/$log</string>
</dict></plist>"
  if [[ -f $f ]] && [[ "$(cat $f)" == "$body" ]] && launchctl print gui/$UID/$label >/dev/null 2>&1; then ok "$label unchanged, running"; return; fi
  if (( DRY )); then echo "  [dry-run] write $f and (re)start $label"; return; fi
  mkdir -p $LA $LOGS; print -r -- "$body" > $f
  launchctl bootout gui/$UID/$label 2>/dev/null
  for i in {1..10}; do launchctl bootstrap gui/$UID $f 2>/dev/null && break; /usr/bin/python3 -c 'import time;time.sleep(1)'; done
  launchctl print gui/$UID/$label >/dev/null 2>&1 && ok "$label started" || warn "$label did not start: see $LOGS/$log"
}
agent dev.tinytv.tvcast tvcast.log "$(command -v node || echo /opt/homebrew/bin/node)" "$ROOT/engine/server.mjs"
agent dev.tinytv.core tinyTVCore.log "$APPS/tinyTVCore.app/Contents/MacOS/tinyTVCore"
if [[ " $WITH " = *" tinysearch "* ]]; then
  step "6b. tinySearch (optional provider)"
  if (( DRY )); then echo "  [dry-run] providers/tinysearch/install.sh"
  else (cd providers/tinysearch && ./install.sh) || warn "tinySearch: see providers/tinysearch/PROVIDER.md"; fi
fi

# 7. Pairing (Hisense)
if (( PAIR )); then
  step "7. Hisense pairing"
  TV=$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("tv",""))' "$SUP/config.json" 2>/dev/null)
  [[ -n $TV ]] || die "no TV address in $SUP/config.json"
  run "/usr/bin/python3 -c 'import paho.mqtt' 2>/dev/null || /usr/bin/python3 -m pip install --user paho-mqtt"
  run "python3 scripts/pair.py $TV"
fi

# 8. Checks and addresses
step "8. Check"
if (( ! DRY )); then
  for i in {1..15}; do curl -s -m 2 -o /dev/null http://127.0.0.1:8891/api/state && break; /usr/bin/python3 -c 'import time;time.sleep(1)'; done
  curl -s -m 3 -o /dev/null -w '' http://127.0.0.1:8891/api/state && ok "core answers on :8891" || warn "core does not answer yet: tail $LOGS/tinyTVCore.log"
  curl -s -m 3 -o /dev/null http://127.0.0.1:8890/state && ok "engine answers on :8890" || warn "engine does not answer: tail $LOGS/tvcast.log"
fi
IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
TSCLI=/Applications/Tailscale.app/Contents/MacOS/Tailscale; command -v tailscale >/dev/null && TSCLI=tailscale
step "Open the remote"
echo "  Home Wi-Fi:  http://tinytv.local/   or   http://${IP:-<this-mac-ip>}/   (port 8897 if 80 was taken)"
echo "  Kino:        http://tinytv.local/kino"
if [[ -x $TSCLI ]] || command -v tailscale >/dev/null; then
  DNS=$($TSCLI status --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null)
  if (( TS )) && [[ -n $DNS ]]; then run "$TSCLI serve --bg --https=8443 http://127.0.0.1:8891 >/dev/null"; fi
  [[ -n $DNS ]] && echo "  Tailscale:   https://$DNS:8443/   $( (( TS )) || echo '(run ./install.sh --tailscale to publish)')"
else
  echo "  Tailscale:   not installed (optional: remote outside home)"
fi
echo "  Add the page to the iPhone home screen (Share -> Add to Home Screen). Help for any step: AGENTS.md"
