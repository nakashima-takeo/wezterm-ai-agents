-- Supervision registry: the set of pane ids the human has toggled into orchestrator
-- management, partitioned by workspace. Each workspace is supervised independently:
-- the command center (CMD+SHIFT+M) only ever touches the current workspace's set, and
-- one orchestrator runs per workspace. This is the only state the human writes for
-- supervision; the orchestrator reads its workspace's slice to learn its scope.
--
-- On-disk schema (per GUI pid namespace, alongside the per-pane state files):
--   managed.json:      { "<workspace>": [3, 6], "<other-ws>": [9] }
--   orchestrator.json: { "<workspace>": 12 }   -- pane id running the supervisor, per ws
-- managed.json is also read independently by the Go MCP server (agent-plugin/mcp/watch.go
-- readManagedSet), which selects its own workspace via WEZTERM_AGENT_WORKSPACE. Update both
-- sides when changing the shape.
--
-- pane ids are mux-global within one GUI process, so the files live under the same
-- <status_dir>/<gui_pid>/ namespace and are reaped by agent.cleanup_dead_namespaces.
-- Live state, escalation and history are NOT stored here: they are derived from the
-- per-pane state files / mux / the orchestrator's own context.

local wezterm = require("wezterm")

local M = {}

-- Read+decode a JSON object file. Missing or invalid -> empty table.
local function read_json(file)
  if not file then return {} end
  local f = io.open(file, "r")
  if not f then return {} end
  local raw = f:read("*a")
  f:close()
  if not raw or raw == "" then return {} end
  local ok, data = pcall(wezterm.json_parse, raw)
  if not ok or type(data) ~= "table" then return {} end
  return data
end

-- Atomic write (tmp + rename) with a one-shot mkdir -p fallback. Returns true on success.
local function write_json(file, tbl)
  local ok, encoded = pcall(wezterm.json_encode, tbl)
  if not ok or not encoded then
    wezterm.log_error("managed.write: JSON encode failed")
    return false
  end

  local tmp = file .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    -- base dir may be absent before any agent has run. Best-effort create, then retry once.
    local dir = file:match("^(.*)/[^/]+$")
    if dir then pcall(wezterm.run_child_process, { "mkdir", "-p", dir }) end
    f = io.open(tmp, "w")
  end
  if not f then
    wezterm.log_error("managed.write: failed to open " .. tmp)
    return false
  end
  f:write(encoded)
  f:close()

  local rok, rerr = os.rename(tmp, file)
  if not rok then
    os.remove(tmp)
    wezterm.log_error("managed.write: rename failed: " .. (rerr or "unknown"))
    return false
  end
  return true
end

-- Read one workspace's managed set as { [pane_id] = true }. Missing ws -> empty set.
function M.read(file, ws)
  local arr = read_json(file)[ws]
  local set = {}
  if type(arr) == "table" then
    for _, id in ipairs(arr) do
      if type(id) == "number" then set[id] = true end
    end
  end
  return set
end

-- Replace one workspace's set, leaving other workspaces untouched. Empty set drops the key.
function M.write(file, ws, set)
  local all = read_json(file)
  local arr = {}
  for id in pairs(set) do
    arr[#arr + 1] = id
  end
  table.sort(arr)
  all[ws] = (#arr > 0) and arr or nil
  return write_json(file, all)
end

-- Toggle a pane's membership in a workspace. Returns the new boolean state (true = now managed).
function M.toggle(file, ws, pane_id)
  local set = M.read(file, ws)
  local now = not set[pane_id]
  set[pane_id] = now or nil
  M.write(file, ws, set)
  return now
end

function M.is_managed(file, ws, pane_id) return M.read(file, ws)[pane_id] == true end

-- Drop managed ids whose pane is no longer alive, across every workspace. Without this, a closed
-- pane lingers in the set forever (toggle-off is the only other removal path), so the orchestrator's
-- "set is empty" termination condition never holds and get_agents reports the closed pane as
-- "unknown". `live` is the { [tostring(pane_id)] = true } set from agent.sweep_orphan_files; nil
-- means liveness could not be determined, so we leave the file untouched. Only writes on change.
function M.prune(file, live)
  if type(live) ~= "table" then return end
  local all = read_json(file)
  local changed = false
  for ws, arr in pairs(all) do
    if type(arr) == "table" then
      local kept = {}
      for _, id in ipairs(arr) do
        if live[tostring(id)] then
          kept[#kept + 1] = id
        else
          changed = true
        end
      end
      all[ws] = (#kept > 0) and kept or nil
    end
  end
  if changed then write_json(file, all) end
end

-- Orchestrator pane tracking, keyed by workspace. The Lua side records which pane runs the
-- supervisor for each workspace so it can avoid duplicate launches, respawn after a manual close,
-- exclude it from that workspace's console, and distinguish its tab.
function M.read_orchestrator(file, ws)
  local v = read_json(file)[ws]
  return type(v) == "number" and v or nil
end

function M.write_orchestrator(file, ws, pane_id)
  local map = read_json(file)
  map[ws] = pane_id or nil
  write_json(file, map)
end

-- True when pane_id runs the orchestrator for any workspace (used to mark its tab regardless of
-- which workspace the renderer is in).
function M.is_orchestrator(file, pane_id)
  if not pane_id then return false end
  for _, v in pairs(read_json(file)) do
    if v == pane_id then return true end
  end
  return false
end

return M
