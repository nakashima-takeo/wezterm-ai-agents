-- Workspace persistence: JSON storage + CRUD + snapshot/sync.
--
-- JSON schema (per workspace):
--   { name, cwd, lastUsed, tabs = [{ agent = "claude" | nil, session_id, cwd, layout }, ...] }
--
-- The "agent" field is the agent id (see plugin/agents/*.lua).
-- Legacy fields {claude=true, sessionId=...} are read transparently for migration.

local wezterm = require("wezterm")
local mux = wezterm.mux

local M = {}

-- ============== JSON read / write ==============

local function read_file(opts)
  local file = io.open(opts.file, "r")
  if not file then return { workspaces = {} } end
  local content = file:read("*a")
  file:close()
  local ok, data = pcall(wezterm.json_parse, content)
  if ok and data and data.workspaces then return data end
  wezterm.log_error("workspace.read: JSON parse failed for " .. opts.file .. (not ok and (": " .. tostring(data)) or ""))
  return { workspaces = {} }
end

-- Migrate legacy tab schema (claude=true, sessionId=X) to (agent="claude", session_id=X).
local function migrate_tab(tab)
  if tab.agent == nil and tab.claude == true then tab.agent = "claude" end
  if tab.session_id == nil and tab.sessionId then tab.session_id = tab.sessionId end
  tab.claude = nil
  tab.sessionId = nil
  return tab
end

function M.read(opts)
  local data = read_file(opts)
  for _, ws in ipairs(data.workspaces) do
    if type(ws.tabs) == "table" then
      for _, tab in ipairs(ws.tabs) do
        migrate_tab(tab)
      end
    end
  end
  return data
end

function M.write(opts, data)
  local tmp = opts.file .. ".tmp"
  local file = io.open(tmp, "w")
  if not file then
    wezterm.log_error("workspace.write: failed to open " .. tmp)
    return
  end
  local ok, encoded = pcall(wezterm.json_encode, data)
  if not ok or not encoded then
    file:close()
    os.remove(tmp)
    wezterm.log_error("workspace.write: JSON encode failed")
    return
  end
  local write_ok = file:write(encoded)
  file:close()
  if not write_ok then
    os.remove(tmp)
    wezterm.log_error("workspace.write: write failed to " .. tmp)
    return
  end
  local rename_ok, rename_err = os.rename(tmp, opts.file)
  if not rename_ok then
    wezterm.log_error("workspace.write: rename failed: " .. (rename_err or "unknown"))
    os.remove(tmp)
  end
end

-- ============== CRUD ==============

function M.find(data, name)
  for i, ws in ipairs(data.workspaces) do
    if ws.name == name then return ws, i end
  end
  return nil, nil
end

function M.update_last_used(opts, name)
  local data = M.read(opts)
  local ws = M.find(data, name)
  if ws then
    ws.lastUsed = os.time()
    M.write(opts, data)
  end
end

function M.sort(workspaces, default_name)
  local copy = {}
  for i, v in ipairs(workspaces) do
    copy[i] = v
  end
  table.sort(copy, function(a, b)
    if a.name == b.name then return false end
    if a.name == default_name then return true end
    if b.name == default_name then return false end
    return (a.lastUsed or 0) > (b.lastUsed or 0)
  end)
  return copy
end

function M.exists(name)
  for _, win in ipairs(mux.all_windows()) do
    if win:get_workspace() == name then return true end
  end
  return false
end

-- Count tabs in a saved workspace that have an agent + session_id (resumable).
function M.count_saved_sessions(ws)
  if type(ws.tabs) ~= "table" then return 0 end
  local n = 0
  for _, tab in ipairs(ws.tabs) do
    if tab.agent and tab.session_id and tab.session_id ~= "" then n = n + 1 end
  end
  return n
end

-- ============== Snapshot / Sync ==============

local function cwd_of(pane)
  local cwd = pane:get_current_working_dir()
  if not cwd then return nil end
  return cwd.file_path or tostring(cwd):gsub("^file://[^/]*", "")
end

-- Build a snapshot of current window's tab structure (agent presence + layout).
-- Requires injected `agent` and `layout` modules to break cyclic loads.
function M.snapshot_tabs(window, agent_mod, layout_mod, plugin_opts)
  local tabs = {}
  for _, tab in ipairs(window:mux_window():tabs()) do
    local entry = {}
    local impl, agent_opts, pane = agent_mod.find_in_tab(tab, plugin_opts)
    if impl then
      entry.agent = impl.id
      local sid = impl.session_id(pane, agent_opts)
      if sid then entry.session_id = sid end
    end
    local cwd_pane = pane or tab:active_pane()
    if cwd_pane then
      local pcwd = cwd_of(cwd_pane)
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
  local data = M.read(opts)
  local changed = false
  for _, win in ipairs(mux.all_windows()) do
    local ws = M.find(data, win:get_workspace())
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
  if changed then M.write(opts, data) end
end

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
