# wezterm-ai-agents

[![CI](https://github.com/nakashima-takeo/wezterm-ai-agents/actions/workflows/ci.yml/badge.svg)](https://github.com/nakashima-takeo/wezterm-ai-agents/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

[日本語](README.md)

WezTerm plugin for orchestrating parallel AI coding agent sessions.
Persistent workspaces, git worktree integration, and agent state visualization.

<!-- TODO: Add screenshot or demo GIF here -->
<!-- ![Demo](docs/demo.gif) -->

> A plugin built for the author's personal workflow, published to share across machines.
> Design philosophy: one git worktree per task, multiple AI agent sessions in parallel,
> fully restorable after WezTerm restart.
>
> Bug reports welcome. Feature requests are evaluated against the author's use cases. Fork freely.

## Requirements

macOS / Linux. Windows is not supported.

- WezTerm nightly (20230712+ recommended for plugin API)
- [Nerd Font](https://www.nerdfonts.com/) (required for status icons. Set `nerd_font = false` for Unicode fallback if not installed)
- git 2.7+ (required for `git worktree list --porcelain`)
- bash (for hooks scripts)
- Agent CLIs must be in PATH

## Supported Agents

| Agent | Command | State Detection |
|-------|---------|----------------|
| [Claude Code](https://docs.claude.com/en/docs/claude-code) | `claude` | working / waiting / done / idle |
| [Cursor Agent](https://docs.cursor.com/agent) | `cursor-agent` | unknown (hook limitations) |
| [OpenAI Codex](https://github.com/openai/codex) | `codex` | working / waiting / done / idle |
| [Google Gemini CLI](https://github.com/google-gemini/gemini-cli) | `gemini` | working / waiting / done / idle |

Each agent retains a session ID and can resume via `--resume` after WezTerm restart.

## Installation

### Installing a Nerd Font

A Nerd Font is required for status icons. With Homebrew:

```bash
brew install --cask font-jetbrains-mono-nerd-font
```

Set the font in your WezTerm config:

```lua
config.font = wezterm.font("JetBrainsMono Nerd Font")
```

> Any Nerd Font will work. Pick your favorite from https://www.nerdfonts.com/.

### Plugin Setup

```lua
local wezterm = require "wezterm"
local config = wezterm.config_builder()

local ai = wezterm.plugin.require("https://github.com/nakashima-takeo/wezterm-ai-agents")
ai.apply(config, {})

return config
```

For local development, use `dofile`:

```lua
local plugin_dir = wezterm.home_dir .. "/github/wezterm-ai-agents"
local ai = dofile(plugin_dir .. "/plugin/init.lua")
ai.apply(config, { plugin_dir = plugin_dir })
```

## Hooks Setup

Agent state detection requires configuring the bundled `hooks/agent_status.sh` in each agent's hooks.
The script writes state as JSON to `$TMPDIR/wezterm-agent-<pane_id>` (falls back to `/tmp` if `$TMPDIR` is unset), which the plugin reads periodically.

### Finding the hooks path

The hooks directory path is logged automatically when `ai.apply()` runs.
Check the WezTerm Debug Overlay (default: `Ctrl+Shift+L` — Ctrl, not Cmd, even on macOS) for the path.

The path is also available as `ai.hooks_dir` after calling `ai.apply()`.

By referencing the plugin's `agent_status.sh` directly, the script is automatically updated when the plugin is updated.

> **Note**: Copying the script elsewhere means plugin updates won't reach your copy. Referencing `ai.hooks_dir` directly is recommended.

### Claude Code

`~/.claude/settings.json` (if you have existing hooks, add entries to the arrays):

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh claude idle" }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh claude clear" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh claude working" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh claude done" }] }],
    "PreToolUse":  [{ "matcher": "AskUserQuestion", "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh claude waiting" }] }],
    "PostToolUse": [{ "matcher": "AskUserQuestion", "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh claude working" }] }]
  }
}
```

### Cursor Agent

Cursor lacks fine-grained lifecycle hooks, so the state always shows as `unknown`.

`~/.cursor/hooks.json`:

```json
{
  "version": 1,
  "hooks": {
    "sessionStart": [{ "command": "<hooks_dir>/agent_status.sh cursor unknown" }],
    "sessionEnd": [{ "command": "<hooks_dir>/agent_status.sh cursor clear" }]
  }
}
```

### Codex

`~/.codex/hooks.json`:

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh codex idle" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh codex working" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh codex done" }] }]
  }
}
```

### Gemini

`~/.gemini/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh gemini idle" }] }],
    "SessionEnd":   [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh gemini clear" }] }],
    "BeforeAgent":  [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh gemini working" }] }],
    "AfterAgent":   [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh gemini done" }] }]
  }
}
```

## Keybinds

Modifier keys are auto-detected by platform (macOS: `Cmd`, Linux: `Ctrl`). Override with `opts.modifier_prefix`.

| Key | ID | Action |
|-----|-----|--------|
| `Mod+Shift+S` | `workspace_selector` | Select / switch workspace |
| `Mod+Shift+N` | `workspace_register` | Register current cwd as workspace |
| `Mod+Shift+U` | `workspace_update` | Update workspace with current layout |
| `Mod+Shift+D` | `workspace_delete` | Delete workspace |
| `Mod+Shift+X` | `worktree_selector` | Worktree management (create/switch/delete) |
| `Mod+Shift+C` | `agent_spawn` | Spawn default agent in a new tab |
| `Mod+Shift+A` | `agent_selector` | Agent selection UI |
| `Mod+Shift+E` | `open_editor` | Open current directory in GUI editor |
| `Mod+T` | `new_tab` | New tab (workspace-synced) |
| `Mod+W` | `close_tab` | Close tab (protects last tab) |
| `Mod+Opt+W` | `close_pane` | Close pane (protects last pane) |
| `Mod+Shift+[` / `]` | `move_tab_left` / `right` | Move tab left/right (synced) |
| `Mod+Opt+/` | `split_right` | Split pane right |
| `Mod+Opt+-` | `split_bottom` | Split pane bottom |
| `Mod+Q` | `disable_quit` | Prevent accidental quit (Nop) |
| `Opt+Enter` | `opt_enter` | OPT+Enter passthrough |
| `Mod+Opt+←→↑↓` | `activate_pane_*` | Navigate between panes |
| `Mod+↑` / `Mod+↓` | `scroll_to_top` / `bottom` | Scroll to top/bottom |
| `Opt+↑` / `Opt+↓` | `scroll_page_up` / `down` | Scroll by page |
| `Mod+←` / `Mod+→` | `line_start` / `end` | Move to line start/end |
| `Mod+Shift+←→` | `prev_tab` / `next_tab` | Switch tabs |
| `Mod+Shift+P` | `pin_toggle` | Toggle always-on-top window pin |

Disable individual keybinds with `opts.disabled_keybinds = { "new_tab", "close_tab" }`.

Override keys with `opts.keybinds` (`key`/`mods` individually; unspecified fields keep defaults):

```lua
ai.apply(config, {
  keybinds = {
    workspace_selector = { key = "s", mods = "CTRL|SHIFT" },
    agent_spawn = { key = "Return", mods = "CTRL" },
    new_tab = { mods = "CTRL" },  -- key stays "t"
  },
})
```

## Options

```lua
ai.apply(config, {
  nerd_font = true,                 -- Use Nerd Font icons. Set false for Unicode fallback
  enabled_agents = nil,             -- nil = all; or { "claude", "codex" }
  default_agent = nil,              -- nil = first registered; or "claude"
  default_editor = nil,             -- nil = auto-detect (code/cursor/windsurf/zed/subl); or "/usr/local/bin/cursor" etc.
  locale = "ja",                    -- auto-detected from LANG env; "en" | "ja"
  modifier_prefix = "CMD",          -- auto-detected: macOS="CMD", Linux="CTRL"
  workspace = {
    file = wezterm.home_dir .. "/.wezterm-workspaces.json",
    default_workspace = "default",
  },
  worktree = {
    path = "sibling",  -- "sibling" | "subdirectory" | "{parent}/.worktrees/{branch}" etc.
  },
  agents = {
    -- claude = { command = "claude --dangerously-skip-permissions" },
    -- codex = { command = "codex --yolo" },
  },
  ui = {
    tab_title = {
      max_chars = 24,
      active_bg = "#1e1e2e",
      active_fg = "#cdd6f4",
    },
  },
  disabled_keybinds = {},
  keybinds = {},                    -- { id = { key = "...", mods = "..." } }
  status_update_interval = 1,       -- right status refresh interval (sec)
  session_sync_interval = 30,       -- session ID sync interval (sec)
  right_status_extra = nil,         -- function(window, pane, deps) -> segments
  install_ui_tab_title = true,
  install_ui_status = true,
  install_keybinds = true,
})
```

See `default_opts` in `plugin/init.lua` for all options.

## Adding a New Agent

Implement the interface defined in `plugin/agent.lua` in `plugin/agents/<id>.lua`:

```lua
return {
  id = "myagent",
  display_name = "...",
  colors = { working = "...", waiting = "...", done = "...", idle = "..." },
  detect(pane, opts)    -> bool,
  state(pane, opts)     -> "working" | "waiting" | "done" | "idle" | "error",
  session_id(pane, opts) -> string|nil,
  spawn_args(opts, session_id, cwd) -> table,
  cleanup_stale(opts)   -> nil,
  default_opts = { ... },
}
```

Register in `init.lua`: `agent.register(load_module("agents/myagent"))`

Configure the agent's hooks to call `hooks/agent_status.sh <id> <state>`.

## License

MIT
