#!/bin/bash
# WorkWork uninstaller — remove all components
set -euo pipefail

echo "Uninstalling WorkWork..."
echo ""

# --- 1. Stop daemon ---
echo "[1/4] Stopping daemon..."
launchctl bootout "gui/$(id -u)/com.workwork.daemon" 2>/dev/null && echo "Daemon stopped." || echo "Daemon was not running."

# --- 2. Remove LaunchAgent plist ---
echo "[2/4] Removing LaunchAgent..."
PLIST="$HOME/Library/LaunchAgents/com.workwork.daemon.plist"
if [ -f "$PLIST" ]; then
  rm "$PLIST"
  echo "Removed $PLIST"
else
  echo "No plist found."
fi

# --- 3. Remove hooks from settings.json ---
echo "[3/4] Removing hooks from Claude Code settings..."
SETTINGS_FILE="$HOME/.claude/settings.json"

if [ -f "$SETTINGS_FILE" ]; then
  python3 << 'PYEOF'
import json, os

settings_path = os.path.expanduser("~/.claude/settings.json")
with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
changed = False

for event in list(hooks.keys()):
    blocks = hooks[event]
    new_blocks = []
    for block in blocks:
        new_hooks = [h for h in block.get("hooks", []) if not h.get("command", "").endswith("/workwork.sh")]
        if new_hooks:
            block["hooks"] = new_hooks
            new_blocks.append(block)
        else:
            changed = True
    if new_blocks:
        hooks[event] = new_blocks
    else:
        del hooks[event]
        changed = True

if changed:
    settings["hooks"] = hooks
    with open(settings_path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    print("Hooks removed from settings.json")
else:
    print("No WorkWork hooks found in settings.json")
PYEOF
else
  echo "No settings.json found."
fi

# --- 4. Remove workwork directory ---
echo "[4/4] Removing WorkWork files..."
HOOK_DIR="$HOME/.claude/hooks/workwork"

if [ -L "$HOOK_DIR" ]; then
  REAL_DIR=$(readlink "$HOOK_DIR")
  rm "$HOOK_DIR"
  echo "Removed symlink $HOOK_DIR -> $REAL_DIR"
  echo "Note: Source directory $REAL_DIR was not removed. Delete it manually if desired."
elif [ -d "$HOOK_DIR" ]; then
  rm -rf "$HOOK_DIR"
  echo "Removed $HOOK_DIR"
else
  echo "No workwork directory found."
fi

echo ""
echo "WorkWork uninstalled. Restart Claude Code to apply."
