#!/bin/zsh
# Builds into build/ (arm64, macOS 14+):
#   tinyTV.app      menu bar remote for a Mac (config "core" = the core's API)
#   tinyTVCore.app  headless core for an always-on Mac (MQTT, casting, media server, phone API); deploy: scripts/deploy-core.sh
# Optional providers are OFF unless named:  PROVIDERS="hdrezka trackers" scripts/build.sh   (see providers/README.md)
set -e
cd "$(dirname $0)/.."
mkdir -p build
for i in {1..300}; do mkdir build/.lock 2>/dev/null && break; [ $i = 300 ] && { echo "build lock busy for 5 min: rm -r build/.lock if stale"; exit 1; }; python3 -c "import time;time.sleep(1)"; done
trap 'rmdir build/.lock 2>/dev/null' EXIT
# A real signing identity keeps macOS permissions (Screen Recording) across rebuilds; ad-hoc loses them.
SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')}
SHARED=(core/TV.swift core/MQTT.swift core/Server.swift core/Cast.swift core/Remote.swift core/Screen.swift core/Light.swift
        core/LowLatency.swift core/Kino.swift core/Providers.swift core/Posters.swift)
FLAGS=()
for P in ${=PROVIDERS:-}; do
  [ -d providers/$P ] || { echo "no provider: $P"; exit 1; }
  SHARED+=(providers/$P/*.swift); FLAGS+=(-D PROVIDER_${(U)P})
  echo "provider ON: $P"
done
clang -c -O2 -fobjc-arc -target arm64-apple-macos14 core/VirtualDisplay.m -o build/VirtualDisplay.o
for NAME in tinyTV tinyTVCore; do
A=build/$NAME.app
mkdir -p $A/Contents/MacOS $A/Contents/Resources
MAIN=(core/Core.swift); [ $NAME = tinyTV ] && MAIN=(remote/mac/TinyTVApp.swift remote/mac/Watch.swift)
swiftc -O -parse-as-library -target arm64-apple-macos14 $FLAGS -import-objc-header core/VirtualDisplay.h $MAIN $SHARED build/VirtualDisplay.o -o $A/Contents/MacOS/$NAME
cp remote/web/phone.html remote/web/kino.html remote/web/screen.html remote/web/np.js remote/web/icon-180.png remote/web/icon-512.png remote/mac/AppIcon.icns core/discover.py core/audiosync.py core/switchplan.py core/keeper.py $A/Contents/Resources/
# The TV's client certificate is yours to supply (docs/hisense-pairing.md); it is never committed.
[ -f certs/remotenow.p12 ] && cp certs/remotenow.p12 $A/Contents/Resources/
cat > $A/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.tinytv.$([ $NAME = tinyTV ] && echo bar || echo core)</string>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundleExecutable</key><string>$NAME</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION:-0.3.1}</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Control the TV on your home network.</string>
<key>NSScreenCaptureUsageDescription</key><string>Show this screen on the TV.</string>
</dict></plist>
P
codesign --force --timestamp=none --sign "${SIGN_ID:--}" $A
echo built $A
done
