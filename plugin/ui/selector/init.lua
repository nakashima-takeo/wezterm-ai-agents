-- Selector coordinator: wires the workspace/worktree/ui sub-modules and builds
-- the keybind table. Sub-modules are loaded by plugin/init.lua and injected via
-- setup(); this file re-exports the public surface (build_keybinds / maybe_prefetch
-- / pinned_windows) so callers keep using a single `selector` facade.
-- All public functions take `deps` (injected modules) to avoid cyclic loads.
--   deps = { workspace, layout, worktree, agent, editor, opts }

local wezterm = require("wezterm")
local mux = wezterm.mux
local act = wezterm.action

local M = {}

M.pinned_windows = {}

local sel_ws, sel_wt, sel_ui, sel_cc

-- plugin/init.lua から各サブモジュールを受け取り結線する。
-- 共有 UI ヘルパーを workspace/worktree/command_center の各 UI に注入し、maybe_prefetch を再エクスポートする。
function M.setup(ws, wt, ui, command_center)
  sel_ws, sel_wt, sel_ui, sel_cc = ws, wt, ui, command_center
  ws.setup(ui)
  wt.setup(ui)
  command_center.setup(ui)
  M.maybe_prefetch = wt.maybe_prefetch
end

-- ============== Agent selector (Cmd+Shift+Opt+C) ==============

function M.agent_selector(window, pane, deps)
  local opts = deps.opts
  local agents = deps.agent.all()
  local choices = {}
  for _, impl in ipairs(agents) do
    table.insert(choices, { id = impl.id, label = "\xEF\x91\x8A " .. impl.display_name })
  end

  window:perform_action(
    act.InputSelector({
      title = "Agent",
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(iw, ip, id)
        if not id then return end
        local impl = deps.agent.get(id)
        if not impl then return end
        deps.layout.add_tab(iw, impl.id, deps.workspace, opts)
        local agent_opts = deps.agent.opts_for(impl, opts)
        local args = impl.spawn_args(agent_opts)
        local env = deps.agent.spawn_env(agent_opts)
        iw:perform_action(act.SpawnCommandInNewTab({ args = args, set_environment_variables = env }), ip)
      end),
    }),
    pane
  )
end

-- ============== Keybinds factory ==============

local function is_last_window_in_workspace(window)
  local ws = window:mux_window():get_workspace()
  local n = 0
  for _, w in ipairs(mux.all_windows()) do
    if w:get_workspace() == ws then n = n + 1 end
  end
  return n <= 1
end
local function is_last_tab(window) return #window:mux_window():tabs() <= 1 end
local function is_last_pane(window) return #window:mux_window():active_tab():panes() <= 1 end

function M.build_keybinds(deps)
  local opts = deps.opts
  local keys = {}
  local help_items = {}
  local disabled = {}
  for _, k in ipairs(opts.disabled_keybinds or {}) do
    disabled[k] = true
  end

  local overrides = opts.keybinds or {}
  local prefix = opts.modifier_prefix or "CMD"
  local overridden = {}

  local function add(id, entry, help)
    if disabled[id] then return end
    if prefix ~= "CMD" then entry.mods = entry.mods:gsub("CMD", prefix) end
    local ov = overrides[id]
    if ov then
      if overridden[id] then return end
      overridden[id] = true
      entry.key = ov.key or entry.key
      entry.mods = ov.mods or entry.mods
    end
    table.insert(keys, entry)
    if help then
      table.insert(help_items, {
        group = help.group,
        desc = help.desc,
        runnable = help.runnable or false,
        key = entry.key,
        mods = entry.mods,
        action = entry.action,
      })
    end
  end

  -- 注意: help_items は help 付き add の呼び出し順で並ぶ。ヘルプの表示順 = ここでの記述順
  -- Workspace & Agent
  add("workspace_selector", {
    key = "S",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(w, p) sel_ws.workspace_selector(w, p, deps) end),
  }, { group = "help_group_main", desc = "help_workspace", runnable = true })

  local default_agent = opts.default_agent and deps.agent.get(opts.default_agent) or deps.agent.all()[1]
  if default_agent then
    add("agent_spawn", {
      key = "C",
      mods = "CMD|SHIFT",
      action = wezterm.action_callback(function(window, pane)
        deps.layout.add_tab(window, default_agent.id, deps.workspace, opts)
        local agent_opts = deps.agent.opts_for(default_agent, opts)
        local args = default_agent.spawn_args(agent_opts)
        local env = deps.agent.spawn_env(agent_opts)
        window:perform_action(act.SpawnCommandInNewTab({ args = args, set_environment_variables = env }), pane)
      end),
    }, { group = "help_group_main", desc = "help_agent_spawn", runnable = true })
  end

  add("agent_selector", {
    key = "A",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane) M.agent_selector(window, pane, deps) end),
  }, { group = "help_group_main", desc = "help_agent_selector", runnable = true })

  add("open_editor", {
    key = "E",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      local editor = deps.editor.detect(opts.default_editor)
      if not editor then
        sel_ui.toast(window, opts.labels.no_editor_found)
        return
      end
      local cwd = deps.workspace.get_cwd_path(pane)
      if not cwd then
        sel_ui.toast(window, opts.labels.cannot_get_cwd)
        return
      end
      wezterm.background_child_process({ editor, cwd })
    end),
  }, { group = "help_group_main", desc = "help_open_editor", runnable = true })

  add("worktree_selector", {
    key = "X",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(w, p) sel_wt.worktree_selector(w, p, deps) end),
  }, { group = "help_group_main", desc = "help_worktree", runnable = true })

  -- Tab & Pane (with workspace sync)
  add("new_tab", {
    key = "t",
    mods = "CMD",
    action = wezterm.action_callback(function(window, pane)
      deps.layout.add_tab(window, nil, deps.workspace, opts)
      window:perform_action(act.SpawnTab("CurrentPaneDomain"), pane)
    end),
  }, { group = "help_group_tab", desc = "help_new_tab" })

  add("close_tab", {
    key = "w",
    mods = "CMD",
    action = wezterm.action_callback(function(window, pane)
      if is_last_window_in_workspace(window) and is_last_tab(window) then return end
      deps.layout.remove_tab(window, deps.workspace, opts)
      window:perform_action(act.CloseCurrentTab({ confirm = false }), pane)
    end),
  }, { group = "help_group_tab", desc = "help_close_tab" })

  add(
    "next_tab",
    { key = "RightArrow", mods = "CMD|SHIFT", action = act.ActivateTabRelative(1) },
    { group = "help_group_tab", desc = "help_next_tab" }
  )
  add(
    "prev_tab",
    { key = "LeftArrow", mods = "CMD|SHIFT", action = act.ActivateTabRelative(-1) },
    { group = "help_group_tab", desc = "help_prev_tab" }
  )

  local function move_tab(direction)
    return wezterm.action_callback(function(window, pane)
      deps.layout.move_tab(window, direction, deps.workspace, opts)
      window:perform_action(act.MoveTabRelative(direction), pane)
    end)
  end
  add("move_tab_left", { key = "[", mods = "CMD|SHIFT", action = move_tab(-1) }, { group = "help_group_tab", desc = "help_move_tab_left" })
  add("move_tab_left", { key = "{", mods = "CMD|SHIFT", action = move_tab(-1) })
  add("move_tab_right", { key = "]", mods = "CMD|SHIFT", action = move_tab(1) }, { group = "help_group_tab", desc = "help_move_tab_right" })
  add("move_tab_right", { key = "}", mods = "CMD|SHIFT", action = move_tab(1) })

  add("split_right", {
    key = "/",
    mods = "CMD|OPT",
    action = wezterm.action_callback(function(window, pane)
      deps.layout.add_split(window, pane, "right", deps.workspace, opts)
      window:perform_action(act.SplitHorizontal({ domain = "CurrentPaneDomain" }), pane)
    end),
  }, { group = "help_group_tab", desc = "help_split_right" })
  add("split_bottom", {
    key = "-",
    mods = "CMD|OPT",
    action = wezterm.action_callback(function(window, pane)
      deps.layout.add_split(window, pane, "bottom", deps.workspace, opts)
      window:perform_action(act.SplitVertical({ domain = "CurrentPaneDomain" }), pane)
    end),
  }, { group = "help_group_tab", desc = "help_split_bottom" })

  add("close_pane", {
    key = "w",
    mods = "CMD|OPT",
    action = wezterm.action_callback(function(window, pane)
      if is_last_window_in_workspace(window) and is_last_tab(window) and is_last_pane(window) then return end
      if is_last_pane(window) then deps.layout.remove_tab(window, deps.workspace, opts) end
      window:perform_action(act.CloseCurrentPane({ confirm = false }), pane)
      if not is_last_pane(window) then
        wezterm.time.call_after(0.1, function() pcall(deps.layout.refresh_after_pane_close, window, deps.workspace, opts) end)
      end
    end),
  }, { group = "help_group_tab", desc = "help_close_pane" })

  -- Window
  add("pin_toggle", {
    key = "P",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      local L = opts.labels
      local id = tostring(window:window_id())
      if M.pinned_windows[id] then
        M.pinned_windows[id] = nil
        window:perform_action(act.SetWindowLevel("Normal"), pane)
        sel_ui.toast(window, L.pin_off, 2000)
      else
        M.pinned_windows[id] = true
        window:perform_action(act.SetWindowLevel("AlwaysOnTop"), pane)
        sel_ui.toast(window, L.pin_on, 2000)
      end
    end),
  }, { group = "help_group_window", desc = "help_pin_toggle", runnable = true })

  -- Help (keybind cheatsheet, generated from the bindings above)
  add("help", {
    key = "H",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane) sel_ui.help_selector(window, pane, deps, help_items) end),
  }, { group = "help_group_window", desc = "help_help" })

  -- Command center (toggle which agent panes the orchestrator supervises).
  -- Placed after the whole window group so the help overlay does not split that group.
  add("command_center", {
    key = "M",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane) sel_cc.open(window, pane, deps) end),
  }, { group = "help_group_command_center", desc = "help_command_center", runnable = true })

  -- ヘルプに表示しないキー (パススルー / ナビゲーション / 行編集)
  add("disable_quit", { key = "q", mods = "CMD", action = act.Nop }) -- CMD+Q 誤操作防止
  add("opt_enter", { key = "Enter", mods = "OPT", action = act.SendKey({ key = "Enter", mods = "OPT" }) })

  add("activate_pane_left", { key = "LeftArrow", mods = "CMD|OPT", action = act.ActivatePaneDirection("Left") })
  add("activate_pane_right", { key = "RightArrow", mods = "CMD|OPT", action = act.ActivatePaneDirection("Right") })
  add("activate_pane_up", { key = "UpArrow", mods = "CMD|OPT", action = act.ActivatePaneDirection("Up") })
  add("activate_pane_down", { key = "DownArrow", mods = "CMD|OPT", action = act.ActivatePaneDirection("Down") })

  add("scroll_to_top", { key = "UpArrow", mods = "CMD", action = act.ScrollToTop })
  add("scroll_to_bottom", { key = "DownArrow", mods = "CMD", action = act.ScrollToBottom })
  add("scroll_page_up", { key = "UpArrow", mods = "OPT", action = act.ScrollByPage(-1) })
  add("scroll_page_down", { key = "DownArrow", mods = "OPT", action = act.ScrollByPage(1) })

  add("line_start", { key = "LeftArrow", mods = "CMD", action = act.SendKey({ key = "a", mods = "CTRL" }) })
  add("line_end", { key = "RightArrow", mods = "CMD", action = act.SendKey({ key = "e", mods = "CTRL" }) })
  add("line_delete", { key = "Backspace", mods = "CMD", action = act.SendKey({ key = "u", mods = "CTRL" }) })

  return keys
end

return M
