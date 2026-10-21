#!/bin/zsh
# Deploys tinyTVCore.app to your always-on Mac (the core host) and (re)starts it as LaunchAgent dev.tinytv.core.
#   CORE_HOST=me@my-mac.local scripts/deploy-core.sh
# Only one MQTT client may use a paired client id: quit any other core first.
set -e
cd "$(dirname $0)/.."
: ${CORE_HOST:?set CORE_HOST=user@host}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}
S=(ssh -i $SSH_KEY -o ConnectTimeout=10 $CORE_HOST)
$S 'mkdir -p ~/tinyTV'
rsync -a --delete -e "ssh -i $SSH_KEY" build/tinyTVCore.app "${CORE_HOST}:tinyTV/"
$S 'mkdir -p ~/Library/Logs && cat > ~/Library/LaunchAgents/dev.tinytv.core.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>dev.tinytv.core</string>
<key>ProgramArguments</key><array><string>$HOME/tinyTV/tinyTVCore.app/Contents/MacOS/tinyTVCore</string></array>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ProcessType</key><string>Interactive</string>
<key>StandardOutPath</key><string>$HOME/Library/Logs/tinyTVCore.log</string>
<key>StandardErrorPath</key><string>$HOME/Library/Logs/tinyTVCore.log</string>
</dict></plist>
P
# Loaded: restart in place (bootout + bootstrap races with "Input/output error"). Not loaded: load it.
if launchctl print gui/$(id -u)/dev.tinytv.core >/dev/null 2>&1; then launchctl kickstart -k gui/$(id -u)/dev.tinytv.core
else launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.tinytv.core.plist; fi
echo deployed'
