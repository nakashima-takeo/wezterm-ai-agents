-- wezterm-ai-agents: entry point.
-- Usage:
--   local plugin = wezterm.plugin.require("https://github.com/nakashima-takeo/wezterm-ai-agents")
--   plugin.apply(config, { agents = { claude = { command = "..." } } })
--
-- Or for local development (no `debug` library in WezTerm Lua sandbox, so the
-- plugin directory must be provided explicitly via opts.plugin_dir):
--   local plugin_dir = wezterm.home_dir .. "/github/wezterm-ai-agents"
--   local plugin = dofile(plugin_dir .. "/plugin/init.lua")
--   plugin.apply(config, { plugin_dir = plugin_dir, ... })

local wezterm = require("wezterm")

-- ============== Module loader ==============

local function detect_plugin_dir(user_dir)
  if user_dir then return user_dir end
  for _, p in ipairs(wezterm.plugin.list()) do
    if p.url:find("wezterm%-ai%-agents") or p.component:find("wezterm%-ai%-agents") then return p.plugin_dir end
  end
  error("wezterm-ai-agents: plugin_dir not detected. Pass opts.plugin_dir or load via wezterm.plugin.require.")
end

local workspace, worktree, layout, selector, agent, ui, builtin_labels, builtin_icons

local all_agent_ids = { "claude", "cursor", "codex", "gemini" }

local function load_modules(plugin_dir, enabled_agents)
  local function load(rel) return dofile(plugin_dir .. "/plugin/" .. rel .. ".lua") end
  workspace = load("workspace")
  worktree = load("worktree")
  layout = load("layout")
  selector = load("selector")
  agent = load("agent")
  ui = load("ui")
  builtin_labels = load("labels")
  builtin_icons = load("icons")
  for _, id in ipairs(enabled_agents or all_agent_ids) do
    local found = false
    for _, valid in ipairs(all_agent_ids) do
      if id == valid then
        found = true
        break
      end
    end
    if not found then error("wezterm-ai-agents: unknown agent '" .. id .. "'. Available: " .. table.concat(all_agent_ids, ", ")) end
    agent.register(load("agents/" .. id))
  end
end

local M = {
  version = "0.7.0",
  workspace = nil,
  worktree = nil,
  layout = nil,
  selector = nil,
  agent = nil,
  ui = nil,
}

-- ============== Defaults ==============

local default_opts = {
  workspace = {
    file = wezterm.home_dir .. "/.wezterm-workspaces.json",
    default_workspace = "default",
  },
  default_tabs = { {}, {} },

  worktree = {
    path = "sibling", -- "sibling" | "subdirectory" | custom template with {git_root}, {parent}, {repo}, {branch}
  },

  nerd_font = true,
  status_dir = os.getenv("TMPDIR") or "/tmp",
  enabled_agents = nil, -- nil = all; or { "claude" } to register only specific agents
  default_agent = nil, -- nil = first registered; or "claude" to set default agent for Cmd+Shift+C
  default_editor = nil, -- nil = auto-detect (code/cursor/windsurf/zed/subl); or "/usr/local/bin/cursor" etc.
  agents = {
    -- agent-specific overrides, e.g. claude = { command = "claude --foo" }
  },

  ui = {
    tab_title = {
      max_chars = 24,
      active_bg = "#1e1e2e",
      active_fg = "#cdd6f4",
      accent_fg = "#b4befe",
      inactive_bg = "#11111b",
      inactive_fg = "#585b70",
    },
    right_status = {
      fg = "#a6adc8",
      -- colors: derived from first registered agent at apply() time.
      -- Override here to use custom colors instead of agent defaults.
    },
  },

  install_ui_tab_title = true,
  install_ui_status = true,
  install_tab_bar_style = true, -- fancy tab bar + ボタン非表示 (プラグインのタブUI向け)
  install_keybinds = true,
  disabled_keybinds = {},
  keybinds = {},
  modifier_prefix = wezterm.target_triple:find("darwin") and "CMD" or "CTRL",
  locale = (os.getenv("LANG") or ""):sub(1, 2) == "ja" and "ja" or "en",

  status_update_interval = 1, -- right-status refresh (sec)
  session_sync_interval = 5, -- workspace full snapshot sync (sec)

  right_status_extra = nil, -- function(window, pane, deps) -> segments
}

local function is_array(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
    if t[n] == nil then return false end
  end
  return n > 0
end

local function merge(base, override)
  local out = {}
  for k, v in pairs(base) do
    if type(v) == "table" then
      out[k] = merge(v, {})
    else
      out[k] = v
    end
  end
  if override then
    for k, v in pairs(override) do
      if type(v) == "table" and type(out[k]) == "table" and not is_array(v) then
        out[k] = merge(out[k], v)
      else
        out[k] = v
      end
    end
  end
  return out
end

-- ============== Apply ==============

function M.apply(config, user_opts)
  local opts = merge(default_opts, user_opts)
  M.opts = opts

  local plugin_dir = detect_plugin_dir(opts.plugin_dir)
  load_modules(plugin_dir, opts.enabled_agents)
  M.workspace, M.worktree, M.layout, M.selector, M.agent, M.ui = workspace, worktree, layout, selector, agent, ui

  if opts.default_agent and not agent.get(opts.default_agent) then
    wezterm.log_error(
      "wezterm-ai-agents: default_agent '" .. opts.default_agent .. "' is not registered. Check enabled_agents or spelling."
    )
  end

  local icon_set = opts.nerd_font and builtin_icons.nerd or builtin_icons.unicode
  for _, impl in ipairs(agent.all()) do
    impl.icons = icon_set
  end

  opts.labels = merge(builtin_labels[opts.locale] or builtin_labels.en, opts.labels or {})
  M.hooks_dir = plugin_dir .. "/hooks"
  wezterm.log_info("wezterm-ai-agents v" .. M.version .. " loaded (hooks_dir = " .. M.hooks_dir .. ")")

  wezterm.on("gui-startup", function()
    for _, impl in ipairs(agent.all()) do
      if impl.cleanup_stale then
        local ok, err = pcall(impl.cleanup_stale, agent.opts_for(impl, opts))
        if not ok then wezterm.log_warn("[ai-agents] cleanup_stale failed for " .. impl.id .. ": " .. tostring(err)) end
      end
    end
    wezterm.plugin.update_all()
  end)

  -- Derive status colors/icons from all registered agents (first wins), merged with user overrides.
  local agent_colors, agent_icons = {}, {}
  for _, impl in ipairs(agent.all()) do
    for k, v in pairs(impl.colors or {}) do
      if not agent_colors[k] then agent_colors[k] = v end
    end
    for k, v in pairs(impl.icons or {}) do
      if not agent_icons[k] then agent_icons[k] = v end
    end
  end
  opts.ui.right_status.colors = merge(agent_colors, opts.ui.right_status.colors or {})
  opts.ui.right_status.icons = merge(agent_icons, opts.ui.right_status.icons or {})

  local pin_icon_set = opts.nerd_font and builtin_icons.nerd or builtin_icons.unicode
  opts.ui.right_status.pin_icon = opts.ui.right_status.pin_icon or pin_icon_set.pin
  opts.ui.right_status.pin_color = opts.ui.right_status.pin_color or "#b4befe"

  local deps = {
    workspace = workspace,
    worktree = worktree,
    layout = layout,
    selector = selector,
    agent = agent,
    ui = ui,
    opts = opts,
  }
  M.deps = deps

  if opts.install_tab_bar_style then
    config.use_fancy_tab_bar = true
    config.show_close_tab_button_in_tabs = false
    config.show_new_tab_button_in_tab_bar = false
    config.hide_tab_bar_if_only_one_tab = false -- 1タブ時もエージェント状態UIを表示
    -- WezTerm の tab_max_width (既定16) がタブタイトル幅の上限になるため、max_chars に余裕分を足して連動させる。
    config.tab_max_width = opts.ui.tab_title.max_chars + 8
  end

  if opts.install_ui_tab_title then
    wezterm.on(
      "format-tab-title",
      function(tab, tabs, _panes, _config, _hover, max_width) return ui.format_tab_title(tab, deps, max_width, #tabs) end
    )
  end

  if opts.install_ui_status then
    local last_status_tick = 0
    local last_sync_tick = 0
    local prev_win_id = nil
    wezterm.on("update-status", function(window, pane)
      local now = os.time()
      pcall(selector.maybe_prefetch, window, pane, deps)
      local win_id = tostring(window:window_id())
      if prev_win_id and prev_win_id ~= win_id and selector.pinned_windows[prev_win_id] then
        selector.pinned_windows[prev_win_id] = nil
        selector.pinned_windows[win_id] = true
      end
      prev_win_id = win_id
      if (now - last_status_tick) >= opts.status_update_interval then
        last_status_tick = now
        local impl, agent_opts = agent.detect(pane, opts)
        if impl and impl.consume_done then pcall(impl.consume_done, pane, agent_opts) end
        local segs = ui.right_status_segments(window, pane, deps)
        window:set_right_status(wezterm.format(segs))
      end
      if (now - last_sync_tick) >= opts.session_sync_interval then
        last_sync_tick = now
        pcall(workspace.sync_all, opts.workspace, agent, layout, opts)
      end
    end)
  end

  if opts.install_keybinds then
    local user_keys = config.keys or {}
    local plugin_keys = selector.build_keybinds(deps)
    local merged = {}
    for _, k in ipairs(plugin_keys) do
      table.insert(merged, k)
    end
    for _, k in ipairs(user_keys) do
      table.insert(merged, k)
    end
    config.keys = merged
  end

  return M
end

return M
