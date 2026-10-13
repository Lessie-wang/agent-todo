#!/bin/bash
# Compile overlay.swift and assemble a minimal .app bundle.
#
# A bundle (not a bare binary) is required: WKWebView renders in a separate
# WebContent process, and without a CFBundleIdentifier the classic failure mode
# is a silent white screen — expensive to diagnose.
set -euo pipefail
cd "$(dirname "$0")"

APP="Agent Todo.app"
C="$APP/Contents"

rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources"

cat > "$C/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Agent Todo</string>
  <key>CFBundleDisplayName</key>       <string>待办</string>
  <key>CFBundleIdentifier</key>        <string>dev.agenttodo.float</string>
  <key>CFBundleExecutable</key>        <string>overlay</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>LSUIElement</key>               <true/>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

echo "compiling overlay.swift ..."
swiftc -O overlay.swift -o "$C/MacOS/overlay"

cp ui.html "$C/Resources/ui.html"
chmod +x "$C/MacOS/overlay"

# ad-hoc signature: it runs unsigned on your own Mac, but signing quiets some
# WebKit helper-process oddities
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "(ad-hoc signing skipped; harmless)"

echo "done → $APP"
echo "launch:  open \"$APP\"   (or double-click)"
echo "data:    ~/.agent-todo/todos.json"
