#!/bin/zsh
# Builds tinySearch.app (menu bar, arm64, macOS 14+) into mac/build and installs it to ~/Applications.
set -e
cd "$(dirname $0)"
A=build/tinySearch.app
rm -rf $A; mkdir -p $A/Contents/MacOS
swiftc -O -parse-as-library -target arm64-apple-macos14 TinySearch.swift -o $A/Contents/MacOS/tinySearch
cat > $A/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.tinytv.search</string><key>CFBundleName</key><string>tinySearch</string>
<key>CFBundleExecutable</key><string>tinySearch</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string><key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
P
SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')}
codesign -f -s ${SIGN_ID:--} $A
rm -rf ~/Applications/tinySearch.app; mkdir -p ~/Applications; cp -R $A ~/Applications/
echo built ~/Applications/tinySearch.app
