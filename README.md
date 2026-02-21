# WorkWork

Sound notifications and tab colors for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) on macOS.

I saw [peon-ping](https://github.com/PeonPing), thought "that's a great idea", shamelessly stole the concept, and — out of zero trust in anyone else's code — rebuilt the whole thing from scratch as a native macOS daemon specifically for Claude Code. No Python runtime, no Node dependencies, just a Swift binary talking over a Unix socket.

It plays Warcraft peon sounds (or GLaDOS, or StarCraft, or whatever) when Claude finishes a task, hits an error, needs permission, or when you're spamming prompts too fast. Also colors your terminal tabs so you can tell at a glance which session is doing what.

Compatible with [OpenPeon](https://github.com/PeonPing) sound packs — 35+ community packs work out of the box.

## Requirements

- macOS 13+
- Xcode Command Line Tools (`xcode-select --install`)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)

## Install

**One-liner:**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/andreaskolltveit/workwork/main/install.sh)
```

**Or clone first:**

```bash
git clone https://github.com/andreaskolltveit/workwork.git ~/.claude/hooks/workwork
cd ~/.claude/hooks/workwork && bash install.sh
```

This builds the daemon, grabs the default peon sound pack, sets up a LaunchAgent, and wires up your Claude Code hooks. Restart Claude Code after install.

## Commands

`workwork <command>` from any terminal:

| Command | What it does |
|---------|-------------|
| `status` | Daemon status |
| `pause` / `resume` / `toggle` | Mute/unmute |
| `volume [0.0-1.0]` | Get/set volume |
| `preview [category]` | Play a sound |
| `preview --list` | List categories |
| `packs list` | Installed packs |
| `packs use <name>` | Switch active pack |
| `packs next` | Cycle to next |
| `packs install <name>` | Download from registry |
| `packs remove <name>` | Delete a pack |
| `packs rotation list` | Rotation list |
| `packs rotation add <n>` | Add to rotation |
| `packs rotation remove <n>` | Remove from rotation |
| `notifications [on\|off\|overlay\|standard]` | Notification style |
| `rotation [random\|round-robin\|session_override\|agentskill]` | Rotation mode |
| `ping` | Health check |
| `help` | All commands |

## Sound Packs

Browse what's available:

```bash
workwork packs install --list-registry
```

Install by name:

```bash
workwork packs install glados
workwork packs install sc_kerrigan,sc_battlecruiser
```

Go wild:

```bash
workwork packs install --all
```

## What Triggers Sound

Toggle any of these in `config.json`:

| Category | When |
|----------|------|
| `session.start` | New session |
| `task.complete` | Agent done |
| `task.error` | Something broke |
| `task.acknowledge` | Agent starts working |
| `input.required` | Waiting for you |
| `resource.limit` | Context compaction |
| `user.spam` | You're clicking too fast |

## Tab Colors

Your terminal tabs change color based on state:

| State | Color |
|-------|-------|
| Working | Amber |
| Idle | Green |
| Needs approval | Red |
| Done | Blue |

Customize RGB values in `config.json` under `tab_color.colors`.

## Configuration

`~/.claude/hooks/workwork/config.json`:

```json
{
  "volume": 0.5,
  "default_pack": "peon",
  "desktop_notifications": true,
  "notification_style": "overlay"
}
```

All options documented in `config.default.json`.

## Uninstall

```bash
bash ~/.claude/hooks/workwork/uninstall.sh
```

## How It Works

1. Claude Code fires hook events (SessionStart, Stop, Notification, etc.)
2. `workwork.sh` relays event JSON to the daemon over a Unix socket
3. Daemon picks a sound from the active pack and plays it
4. Tab title/color escape sequences get written back to your terminal
5. Optional overlay notification pops up on screen

## License

MIT
