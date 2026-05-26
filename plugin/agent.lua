-- Agent registry and aggregation helpers.
--
-- An agent implementation must expose:
--   id            : string identifier ("claude", "cursor", ...)
--   display_name  : human-readable name
--   icons         : { working, waiting, done, idle [, error] }
--   colors        : same keys as icons
--   spawn_args(opts, session_id, cwd) -> table  -- args for wezterm spawn
--   default_opts  : table merged under opts.agents[id]
--
-- Optional (injected by register() if not provided):
--   default_state : fallback state when file is absent (default "idle")
--   detect, state, session_id, consume_done, cleanup_stale, spawn_args
-- Injected unconditionally:
--   shell_quote(s) — POSIX single-quote escaping utility

local wezterm = require("wezterm")
local mux = wezterm.mux

local M = {}

function M.shell_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

function M.read_state_file(pane_id, status_dir)
  local path = status_dir .. "/wezterm-agent-" .. pane_id
  local f = io.open(path, "r")
  if not f then return nil end
  local raw = f:read("*a")
  f:close()
  if not raw or raw == "" then return nil end
  local ok, data = pcall(wezterm.json_parse, raw)
  if not ok or type(data) ~= "table" then return nil end
  return data
end

function M.cleanup_stale_files(agent_id, opts)
  local dir = opts.status_dir
  local ok, entries = pcall(wezterm.read_dir, dir)
  if not ok or not entries then return end
  for _, path in ipairs(entries) do
    if path:match("/wezterm%-agent%-") then
      local f = io.open(path, "r")
      if f then
        local raw = f:read("*a")
        f:close()
        local ok2, data = pcall(wezterm.json_parse, raw or "")
        if ok2 and type(data) == "table" and data.agent == agent_id then os.remove(path) end
      end
    end
  end
end

local registry = {}
local order = {}

function M.register(impl)
  if not impl or not impl.id then error("agent.register: impl.id is required") end

  local agent_id = impl.id
  local fallback = impl.default_state or "idle"

  if not impl.detect then
    impl.detect = function(pane, opts)
      local data = M.read_state_file(pane:pane_id(), opts.status_dir)
      return data ~= nil and data.agent == agent_id
    end
  end

  if not impl.state then
    impl.state = function(pane, opts)
      local data = M.read_state_file(pane:pane_id(), opts.status_dir)
      if not data or not data.state then return fallback end
      return data.state
    end
  end

  if not impl.session_id then
    impl.session_id = function(pane, opts)
      local data = M.read_state_file(pane:pane_id(), opts.status_dir)
      if not data or not data.session_id or data.session_id == "" then return nil end
      return data.session_id
    end
  end

  if not impl.consume_done then
    impl.consume_done = function(pane, opts)
      local path = opts.status_dir .. "/wezterm-agent-" .. pane:pane_id()
      local f = io.open(path, "r")
      if not f then return false end
      local raw = f:read("*a")
      f:close()
      if not raw or raw == "" then return false end
      local ok, data = pcall(wezterm.json_parse, raw)
      if not ok or type(data) ~= "table" then return false end
      if data.state ~= "done" or data.agent ~= agent_id then return false end
      data.state = fallback
      data.ts = os.time()
      local wf = io.open(path, "w")
      if not wf then return false end
      wf:write(wezterm.json_encode(data) .. "\n")
      wf:close()
      return true
    end
  end

  if not impl.cleanup_stale then impl.cleanup_stale = function(opts) M.cleanup_stale_files(agent_id, opts) end end

  impl.shell_quote = M.shell_quote

  if not impl.spawn_args then
    impl.spawn_args = function(opts, session_id, cwd)
      local cmd = opts.command
      if session_id then cmd = cmd .. " --resume " .. M.shell_quote(session_id) end
      local cd_prefix = ""
      if cwd then cd_prefix = "cd " .. M.shell_quote(cwd) .. " && " end
      local shell = opts.shell
      return { shell, "-lc", string.format("%s%s; exec %s -l", cd_prefix, cmd, shell) }
    end
  end

  if not registry[impl.id] then table.insert(order, impl.id) end
  registry[impl.id] = impl
end

function M.get(id) return registry[id] end

function M.all()
  local list = {}
  for _, id in ipairs(order) do
    table.insert(list, registry[id])
  end
  return list
end

-- Build per-agent opts by merging defaults + user overrides.
-- Plugin-level status_dir is injected unless agent-specific override exists.
function M.opts_for(agent_impl, plugin_opts)
  local out = {}
  for k, v in pairs(agent_impl.default_opts or {}) do
    out[k] = v
  end
  local user = plugin_opts.agents and plugin_opts.agents[agent_impl.id] or {}
  for k, v in pairs(user) do
    out[k] = v
  end
  if not out.status_dir and plugin_opts.status_dir then out.status_dir = plugin_opts.status_dir end
  return out
end

function M.spawn_env(agent_opts) return { WEZTERM_AGENT_STATUS_DIR = agent_opts.status_dir } end

-- Find which agent (if any) is running in the given pane.
function M.detect(pane, plugin_opts)
  for _, impl in ipairs(M.all()) do
    local agent_opts = M.opts_for(impl, plugin_opts)
    if impl.detect(pane, agent_opts) then return impl, agent_opts end
  end
  return nil, nil
end

-- Aggregate state counts across panes, optionally scoped to a workspace.
function M.count(plugin_opts, ws_name)
  local counts = { working = 0, waiting = 0, done = 0, idle = 0, error = 0, unknown = 0 }
  for _, win in ipairs(mux.all_windows()) do
    if not ws_name or win:get_workspace() == ws_name then
      for _, tab in ipairs(win:tabs()) do
        for _, p in ipairs(tab:panes()) do
          local impl, agent_opts = M.detect(p, plugin_opts)
          if impl then
            local st = impl.state(p, agent_opts)
            if counts[st] then counts[st] = counts[st] + 1 end
          end
        end
      end
    end
  end
  return counts
end

function M.all_workspaces(plugin_opts)
  local result = {}
  for _, win in ipairs(mux.all_windows()) do
    local ws = win:get_workspace()
    local bucket = result[ws] or { working = 0, waiting = 0, done = 0, idle = 0, error = 0, unknown = 0 }
    for _, tab in ipairs(win:tabs()) do
      for _, p in ipairs(tab:panes()) do
        local impl, agent_opts = M.detect(p, plugin_opts)
        if impl then
          local st = impl.state(p, agent_opts)
          if bucket[st] then bucket[st] = bucket[st] + 1 end
        end
      end
    end
    result[ws] = bucket
  end
  return result
end

-- Find first agent pane in a tab, returning (agent_impl, agent_opts, pane).
function M.find_in_tab(tab, plugin_opts)
  for _, p in ipairs(tab:panes()) do
    local impl, agent_opts = M.detect(p, plugin_opts)
    if impl then return impl, agent_opts, p end
  end
  return nil, nil, nil
end

return M
