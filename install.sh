#!/bin/bash
# agent-todo installer
#
#   ./install.sh              install the skill into your agent's skills dir
#   ./install.sh --with-app   also build the macOS widget and start it at login
#
# Override the skill location with:  SKILLS_DIR=/path/to/skills ./install.sh
set -euo pipefail
cd "$(dirname "$0")"

SKILL_NAME="agent-todo"
SKILLS_DIR="${SKILLS_DIR:-$HOME/.claude/skills}"
WITH_APP=0
[ "${1:-}" = "--with-app" ] && WITH_APP=1

echo "==> installing skill → $SKILLS_DIR/$SKILL_NAME"
mkdir -p "$SKILLS_DIR"
rm -rf "$SKILLS_DIR/$SKILL_NAME"
cp -R skill "$SKILLS_DIR/$SKILL_NAME"
echo "    ok"

if [ "$WITH_APP" = "0" ]; then
  echo
  echo "Skill installed. Try telling your agent: 记一条待办：周五交周报"
  echo "Want the floating widget too?  ./install.sh --with-app"
  exit 0
fi

if [ "$(uname)" != "Darwin" ]; then
  echo "the floating widget is macOS-only — skipping it"
  exit 0
fi

echo "==> building the desktop widget"
( cd app && ./build.sh )

APP_PATH="$(pwd)/app/Agent Todo.app"
AGENT_PLIST="$HOME/Library/LaunchAgents/dev.agenttodo.float.plist"

echo "==> enabling login autostart → $AGENT_PLIST"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.agenttodo.float</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>$APP_PATH</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/dev.agenttodo.float" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
/usr/bin/open -a "$APP_PATH" 2>/dev/null || true

echo
echo "All set. ⌥⌘X shows / hides the widget; the menu-bar ☑︎ icon has the rest."
echo "Turn autostart off later:"
echo "  launchctl bootout gui/$(id -u)/dev.agenttodo.float && rm \"$AGENT_PLIST\""
