#!/bin/bash
# WorkWork installer — sound notifications for Claude Code
set -euo pipefail

# --- Determine repo directory ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# If run via curl|bash (process substitution), SCRIPT_DIR won't contain workwork.sh
if [ ! -f "$SCRIPT_DIR/workwork.sh" ]; then
  echo "Cloning WorkWork..."
  CLONE_DIR="$HOME/.claude/hooks/workwork"
  if [ -d "$CLONE_DIR/.git" ]; then
    echo "Existing installation found at $CLONE_DIR — pulling latest..."
    git -C "$CLONE_DIR" pull --ff-only
  else
    mkdir -p "$(dirname "$CLONE_DIR")"
    git clone https://github.com/andreaskolltveit/workwork.git "$CLONE_DIR"
  fi
  SCRIPT_DIR="$CLONE_DIR"
fi

WORK_DIR="$SCRIPT_DIR"
echo "Installing WorkWork from: $WORK_DIR"
echo ""

# --- Check prerequisites ---
if ! command -v swiftc &>/dev/null; then
  echo "Error: swiftc not found. Install Xcode Command Line Tools:"
  echo "  xcode-select --install"
  exit 1
fi

# --- 1. Build daemon ---
echo "[1/6] Building daemon..."
bash "$WORK_DIR/daemon/build.sh"
echo ""

# --- 2. If installed outside ~/.claude/hooks/workwork, symlink ---
HOOK_DIR="$HOME/.claude/hooks/workwork"
if [ "$WORK_DIR" != "$HOOK_DIR" ]; then
  echo "[2/6] Linking to $HOOK_DIR..."
  mkdir -p "$(dirname "$HOOK_DIR")"
  if [ -L "$HOOK_DIR" ]; then
    rm "$HOOK_DIR"
  elif [ -d "$HOOK_DIR" ]; then
    echo "Warning: $HOOK_DIR already exists and is not a symlink."
    echo "Move or remove it first, or clone directly into ~/.claude/hooks/workwork"
    exit 1
  fi
  ln -s "$WORK_DIR" "$HOOK_DIR"
else
  echo "[2/6] Already in ~/.claude/hooks/workwork — no linking needed."
fi
echo ""

# --- 3. Generate config.json ---
echo "[3/6] Generating config..."
if [ ! -f "$WORK_DIR/config.json" ]; then
  cp "$WORK_DIR/config.default.json" "$WORK_DIR/config.json"
  echo "Created config.json from defaults."
else
  echo "config.json already exists — keeping current settings."
fi

# Generate empty state file
if [ ! -f "$WORK_DIR/.state.json" ]; then
  cat > "$WORK_DIR/.state.json" << 'STATE'
{
  "last_active": {},
  "last_stop_time": 0,
  "last_played": {},
  "prompt_timestamps": {},
  "prompt_start_times": {},
  "session_start_times": {},
  "session_packs": {},
  "subagent_sessions": {},
  "agent_sessions": [],
  "pending_subagent_pack": {},
  "rotation_index": 0
}
STATE
  echo "Created .state.json"
fi
echo ""

# --- 4. Download default pack ---
echo "[4/6] Downloading peon sound pack..."
if [ -d "$WORK_DIR/packs/peon" ] && [ -f "$WORK_DIR/packs/peon/openpeon.json" ]; then
  echo "Peon pack already installed — skipping."
else
  bash "$WORK_DIR/scripts/pack-download.sh" --dir="$WORK_DIR" --packs=peon
fi
echo ""

# --- 5. Install LaunchAgent ---
echo "[5/6] Installing LaunchAgent..."
PLIST_SRC="$WORK_DIR/com.workwork.daemon.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.workwork.daemon.plist"

# Stop existing daemon if running
launchctl bootout "gui/$(id -u)/com.workwork.daemon" 2>/dev/null || true

# Expand __WORK_DIR__ placeholder and write plist
sed "s|__WORK_DIR__|$WORK_DIR|g" "$PLIST_SRC" > "$PLIST_DST"

# Start daemon
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
echo "Daemon started."
echo ""

# --- 6. Configure Claude Code hooks ---
echo "[6/6] Configuring Claude Code hooks..."
SETTINGS_FILE="$HOME/.claude/settings.json"
WORKWORK_CMD="$HOOK_DIR/workwork.sh"

mkdir -p "$HOME/.claude"

# Use python3 to safely merge hooks into settings.json
python3 << PYEOF
import json, os

settings_path = "$SETTINGS_FILE"
hook_cmd = "$WORKWORK_CMD"

# Load existing settings
settings = {}
if os.path.isfile(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)

hooks = settings.setdefault("hooks", {})

# Hook definitions: event -> (matcher, async)
hook_defs = {
    "SessionStart":       ("", False),
    "SessionEnd":         ("", True),
    "SubagentStart":      ("", True),
    "UserPromptSubmit":   ("", True),
    "Stop":               ("", True),
    "Notification":       ("", True),
    "PermissionRequest":  ("", True),
    "PostToolUseFailure": ("Bash", True),
    "PreCompact":         ("", True),
}

for event, (matcher, is_async) in hook_defs.items():
    hook_entry = {
        "type": "command",
        "command": hook_cmd,
        "timeout": 10,
    }
    if is_async:
        hook_entry["async"] = True

    matcher_block = {
        "matcher": matcher,
        "hooks": [hook_entry],
    }

    # Check if this event already has the workwork hook
    existing = hooks.get(event, [])
    already = False
    for block in existing:
        for h in block.get("hooks", []):
            if h.get("command", "").endswith("/workwork.sh"):
                already = True
                break
        if already:
            break

    if not already:
        existing.append(matcher_block)
        hooks[event] = existing

settings["hooks"] = hooks

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print("Hooks configured.")
PYEOF

echo ""
echo "==================================="
echo " WorkWork installed successfully!"
echo "==================================="
echo ""
echo "Restart Claude Code to activate hooks."
echo ""
echo "Quick test:"
echo "  workwork ping     # health check"
echo "  workwork status   # daemon status"
echo "  workwork help     # all commands"
