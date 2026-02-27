#!/bin/bash
# workwork.sh — thin shell relay for WorkWork daemon (0 Python)
# CLI mode: workwork <command> [args]
# Hook mode: piped JSON from Claude Code hooks
WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
SOCK="$WORK_DIR/.workworkd.sock"

daemon_send() { printf '%s\n' "$1" | nc -U -w 2 "$SOCK" 2>/dev/null || true; }
json_field() { printf '%s' "$1" | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true; }

# --- CLI mode ---
if [ $# -gt 0 ]; then
  resp=""
  case "$1" in
    packs)
      case "${2:-}" in
        install)
          shift 2
          args=("--dir=$WORK_DIR")
          for a in "$@"; do
            case "$a" in
              --*) args+=("$a") ;;
              *) args+=("--packs=$a") ;;
            esac
          done
          bash "$WORK_DIR/scripts/pack-download.sh" "${args[@]}"
          exit $?
          ;;
        list)
          active=$(daemon_send '{"cli":"packs","action":"current"}' 2>/dev/null)
          active_name=$(json_field "$active" "pack")
          for d in "$WORK_DIR"/packs/*/openpeon.json; do
            [ -f "$d" ] || continue
            pack_dir=$(dirname "$d")
            name=$(basename "$pack_dir")
            count=$(ls "$pack_dir/sounds/" 2>/dev/null | wc -l | tr -d ' ')
            display=$(python3 -c "import json; print(json.load(open('$d')).get('display_name','$name'))" 2>/dev/null || echo "$name")
            marker=""
            [ "$name" = "$active_name" ] && marker=" *"
            printf "  %-28s %s (%d sounds)%s\n" "$name" "$display" "$count" "$marker"
          done
          exit 0
          ;;
        remove)
          if [ -z "${3:-}" ]; then echo "Usage: workwork packs remove <name>"; exit 1; fi
          rm -rf "$WORK_DIR/packs/${3}"
          echo "Removed pack: ${3}"
          exit 0
          ;;
        rotation)
          resp=$(daemon_send "{\"cli\":\"packs\",\"action\":\"rotation\",\"arg\":\"${3:-}\",\"arg2\":\"${4:-}\"}")
          ;;
        *)
          resp=$(daemon_send "{\"cli\":\"packs\",\"action\":\"${2:-list}\",\"arg\":\"${3:-}\",\"arg2\":\"${4:-}\"}")
          ;;
      esac
      ;;
    help)
      cat <<'EOF'
workwork — sound notifications for Claude Code

Commands:
  status                  Show daemon status
  pause / resume / toggle Pause/resume sounds
  volume [0.0-1.0]       Get/set volume
  preview [category]      Play a sound (default: task.complete)
  preview --list          List available categories
  packs list              List installed packs
  packs use <name>        Set active pack
  packs next              Cycle to next pack
  packs install <name>    Download pack from registry
  packs remove <name>     Remove installed pack
  packs rotation list     Show rotation list
  packs rotation add <n>  Add pack to rotation
  packs rotation remove   Remove pack from rotation
  notifications [on|off|overlay|standard]
  rotation [random|round-robin|session_override|agentskill]
  ping                    Health check
  help                    This message
EOF
      exit 0
      ;;
    preview)
      resp=$(daemon_send "{\"cli\":\"preview\",\"value\":\"${2:-}\"}")
      ;;
    *)
      resp=$(daemon_send "{\"cli\":\"$1\",\"value\":\"${2:-}\"}")
      ;;
  esac
  if [ -n "${resp:-}" ]; then
    text=$(json_field "$resp" "text")
    [ -n "$text" ] && printf '%b\n' "$text"
  fi
  exit 0
fi

# --- Hook mode (stdin JSON) ---
[ -t 0 ] && { echo "Usage: workwork <command> — run 'workwork help' for details"; exit 0; }

INPUT=$(cat)
[ ! -S "$SOCK" ] && exit 0

# Detect TTY for escape sequences
TTY=""
if [ -n "${CLAUDE_TERM_TTY:-}" ]; then
  TTY="$CLAUDE_TERM_TTY"
elif command -v tty &>/dev/null; then
  TTY=$(tty 2>/dev/null || true)
fi

# Detect bundle ID (terminal app)
BUNDLE_ID=""
if [ "$(uname)" = "Darwin" ]; then
  BUNDLE_ID=$(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true' 2>/dev/null || true)
fi

# Detect IDE PID (parent of parent for embedded terminals)
IDE_PID=""
if [ -n "${TERM_PROGRAM_VERSION:-}" ] && [ -n "${PPID:-}" ]; then
  IDE_PID=$(ps -o ppid= -p "$PPID" 2>/dev/null | tr -d ' ' || true)
fi

# Inject context into JSON and send to daemon
ENRICHED=$(printf '%s' "$INPUT" | sed "s/}\$/,\"bundle_id\":\"${BUNDLE_ID}\",\"ide_pid\":\"${IDE_PID}\"}/")


resp=$(daemon_send "$ENRICHED" || true)
[ -z "${resp:-}" ] && exit 0

# Write TTY escapes
if [ -n "$TTY" ] && [ -e "$TTY" ]; then
  tab_title=$(json_field "$resp" "tab_title")
  tab_color=$(json_field "$resp" "tab_color")
  [ -n "$tab_title" ] && printf '%b' "$tab_title" > "$TTY" 2>/dev/null || true
  [ -n "$tab_color" ] && printf '%b' "$tab_color" > "$TTY" 2>/dev/null || true
fi

# Stderr message (e.g. paused notice on SessionStart)
stderr_msg=$(json_field "$resp" "stderr")
[ -n "${stderr_msg:-}" ] && echo "$stderr_msg" >&2

exit 0
