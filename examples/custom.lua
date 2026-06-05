-- Customized configuration example.
-- Shows how to select agents, override commands, remap keybinds, and tune UI.

local wezterm = require("wezterm")
local config = wezterm.config_builder()

local ai = wezterm.plugin.require("https://github.com/nakashima-takeo/wezterm-ai-agents")
ai.apply(config, {
  -- Register only specific agents (default: all).
  -- Available: "claude", "codex", "cursor", "gemini"
  enabled_agents = { "claude", "codex" },

  -- Which agent Mod+Shift+C spawns (default: first registered).
  default_agent = "claude",

  -- UI language: "en" or "ja" (default: auto-detected from LANG env).
  locale = "en",

  -- Modifier key prefix: "CMD" (macOS) or "CTRL" (Linux).
  -- Auto-detected by default.
  modifier_prefix = "CMD",

  workspace = {
    -- Where workspace definitions are persisted.
    file = wezterm.home_dir .. "/.wezterm-workspaces.json",
    -- Name for the initial workspace.
    default_workspace = "default",
  },

  worktree = {
    -- Where git worktrees are created.
    -- Presets: "sibling" (../repo__worktrees/branch), "subdirectory" (.worktrees/branch)
    -- Custom template: "{parent}/.worktrees/{branch}"
    path = "sibling",
  },

  -- Override the shell command used to launch each agent.
  agents = {
    claude = { command = "claude --dangerously-skip-permissions" },
    codex = { command = "codex --approval-mode full-auto" },
  },

  ui = {
    tab_title = {
      max_chars = 32, -- Truncate tab titles beyond this length.
      active_bg = "#1e1e2e", -- Background color for the active tab.
      active_fg = "#cdd6f4", -- Text color for the active tab.
    },
  },

  -- Remap specific keybinds. Only the fields you specify are overridden;
  -- unspecified fields (key or mods) keep their defaults.
  -- See README for the full list of keybind IDs.
  keybinds = {
    workspace_selector = { key = "s", mods = "CTRL|SHIFT" },
    agent_spawn = { key = "Return", mods = "CMD|SHIFT" },
  },

  -- Disable keybinds you don't want the plugin to register.
  -- Useful when they conflict with your own keybinds.
  disabled_keybinds = { "new_tab", "close_tab" },

  -- How often (seconds) the right status bar refreshes agent states.
  status_update_interval = 2,
  -- How often (seconds) workspace state (tabs, agents, layouts) is synced to JSON.
  session_sync_interval = 10,

  -- Auto-install agent state-tracking hooks into each agent's config on startup
  -- (default: true; requires `jq`). Symlinked configs (e.g. dotfiles) are skipped.
  -- Set false to manage hooks yourself (see README "手動でのHooks設定").
  install_hooks = false,
})

return config
