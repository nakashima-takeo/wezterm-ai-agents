-- Workspace session: current window snapshot/sync + workspace creation (spawn).
--
-- These functions touch the WezTerm mux API and depend on injected `agent` / `layout`
-- modules (passed as args to break cyclic loads). Storage access (read/write/find/
-- get_cwd_path) is injected via setup() from workspace/init.lua to keep a single facade.

local wezterm = require("wezterm")
local mux = wezterm.mux

local M = {}

local storage

-- workspace/init.lua が自身(storage+CRUD)を注入する。
function M.setup(storage_mod) storage = storage_mod end

-- ============== Snapshot / Sync ==============

-- Build a snapshot of current window's tab structure (agent presence + layout).
-- Requires injected `agent` and `layout` modules to break cyclic loads.
function M.snapshot_tabs(window, agent_mod, layout_mod, plugin_opts)
  local tabs = {}
  for _, tab in ipairs(window:tabs()) do
    local entry = {}
    local impl, agent_opts, pane = agent_mod.find_in_tab(tab, plugin_opts)
    if impl then
      entry.agent = impl.id
      local sid = impl.session_id(pane, agent_opts)
      if sid then entry.session_id = sid end
    end
    local cwd_pane = pane or tab:active_pane()
    if cwd_pane then
      local pcwd = storage.get_cwd_path(cwd_pane)
      if pcwd then entry.cwd = pcwd end
    end
    local lay = layout_mod and layout_mod.snapshot(tab) or nil
    if lay then entry.layout = lay end
    table.insert(tabs, entry)
  end
  return tabs
end

-- Periodic full snapshot: capture tab structure, agents, layouts, and cwds for all running workspaces.
function M.sync_all(opts, agent_mod, layout_mod, plugin_opts)
  local data = storage.read(opts)
  local changed = false
  for _, win in ipairs(mux.all_windows()) do
    local ws = storage.find(data, win:get_workspace())
    if ws then
      local tabs = M.snapshot_tabs(win, agent_mod, layout_mod, plugin_opts)
      local old = wezterm.json_encode(ws.tabs or {})
      local new = wezterm.json_encode(tabs)
      if old ~= new then
        ws.tabs = tabs
        changed = true
      end
    end
  end
  if changed then storage.write(opts, data) end
end

-- ============== Creation ==============

-- Workspace creation: spawn a window with tabs/layouts/agents as configured.
function M.create(ws_config, agent_mod, layout_mod, plugin_opts, default_tabs)
  local tabs = ws_config.tabs or default_tabs
  local first = tabs[1] or {}
  local first_cwd = first.cwd or ws_config.cwd

  local function tab_spawn_opts(t)
    if not t.agent then return nil, nil end
    local impl = agent_mod.get(t.agent)
    if not impl then return nil, nil end
    local agent_opts = agent_mod.opts_for(impl, plugin_opts)
    return impl.spawn_args(agent_opts, t.session_id, t.cwd), agent_mod.spawn_env(agent_opts)
  end

  local first_args, first_env = tab_spawn_opts(first)
  local _, first_pane, window = mux.spawn_window({
    workspace = ws_config.name,
    cwd = first_cwd,
    args = first_args,
    set_environment_variables = first_env,
  })
  if first.layout and layout_mod then layout_mod.apply(first_pane, first.layout, first_cwd) end

  for i = 2, #tabs do
    local t = tabs[i]
    local cwd = t.cwd or ws_config.cwd
    local args, env = tab_spawn_opts(t)
    local _, new_pane = window:spawn_tab({ cwd = cwd, args = args, set_environment_variables = env })
    if t.layout and layout_mod then layout_mod.apply(new_pane, t.layout, cwd) end
  end
end

return M
