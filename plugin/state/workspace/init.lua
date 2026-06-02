-- Workspace persistence: JSON storage + CRUD.
-- Snapshot/sync/create live in workspace/session.lua and are re-exported here via
-- setup() so callers keep using a single `workspace` facade (deps.workspace.X).
--
-- JSON schema (per workspace):
--   { name, cwd, lastUsed, tabs = [{ agent = "claude" | nil, session_id, cwd, layout }, ...] }
--
-- The "agent" field is the agent id (see plugin/agents/*.lua).
-- Legacy fields {claude=true, sessionId=...} are read transparently for migration.

local wezterm = require("wezterm")
local mux = wezterm.mux

local M = {}

-- session(snapshot/sync/create) を結線する。init.lua から呼ばれる。
-- session に自身(storage)を渡し、session の公開関数を M に再エクスポートして単一ファサードを保つ。
function M.setup(session)
  session.setup(M)
  M.snapshot_tabs = session.snapshot_tabs
  M.sync_all = session.sync_all
  M.create = session.create
end

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
    -- 初回・エージェント未起動時は base が不在になりうる。best-effort で作成し 1 度だけ再試行する。
    -- (dir が在る通常パスではサブプロセスを spawn しない。)
    local dir = opts.file:match("^(.*)/[^/]+$")
    if dir then pcall(wezterm.run_child_process, { "mkdir", "-p", dir }) end
    file = io.open(tmp, "w")
  end
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

-- pane の cwd をパス文字列で返す。selector / links / session と共有する単一の実装。
function M.get_cwd_path(pane)
  local cwd = pane:get_current_working_dir()
  if not cwd then return nil end
  return cwd.file_path or tostring(cwd):gsub("^file://[^/]*", "")
end

return M
