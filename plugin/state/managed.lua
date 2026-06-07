-- Supervision registry: the set of pane ids the human has toggled into orchestrator
-- management. This is the only state the human writes for supervision; the orchestrator
-- reads it to learn its scope and the board reads it to render the roster.
--
-- On-disk schema (per GUI pid namespace, alongside the per-pane state files):
--   { "managed": [3, 6, 9] }
--
-- pane ids are mux-global within one GUI process, so the file lives under the same
-- <status_dir>/<gui_pid>/ namespace and is reaped by agent.cleanup_dead_namespaces.
-- Live state, workspace, escalation and history are NOT stored here: they are derived
-- from the per-pane state files / mux / the orchestrator's own context.

local wezterm = require("wezterm")

local M = {}

-- Read the managed set as { [pane_id] = true }. Missing or invalid file -> empty set.
function M.read(file)
  local f = io.open(file, "r")
  if not f then return {} end
  local raw = f:read("*a")
  f:close()
  if not raw or raw == "" then return {} end
  local ok, data = pcall(wezterm.json_parse, raw)
  if not ok or type(data) ~= "table" or type(data.managed) ~= "table" then return {} end
  local set = {}
  for _, id in ipairs(data.managed) do
    if type(id) == "number" then set[id] = true end
  end
  return set
end

-- Atomic write (tmp + rename) with a one-shot mkdir -p fallback, mirroring workspace.write.
-- Returns true on success.
function M.write(file, set)
  local arr = {}
  for id in pairs(set) do
    arr[#arr + 1] = id
  end
  table.sort(arr)

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

  local ok, encoded = pcall(wezterm.json_encode, { managed = arr })
  if not ok or not encoded then
    f:close()
    os.remove(tmp)
    wezterm.log_error("managed.write: JSON encode failed")
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

-- Toggle a pane's membership. Returns the new boolean state (true = now managed).
function M.toggle(file, pane_id)
  local set = M.read(file)
  local now = not set[pane_id]
  set[pane_id] = now or nil
  M.write(file, set)
  return now
end

function M.is_managed(file, pane_id) return M.read(file)[pane_id] == true end

-- Orchestrator pane tracking. The Lua side records which pane runs the supervisor so it can
-- avoid duplicate launches, respawn after a manual close, and exclude it from the console.
-- Stored as a plain pane id in a sibling file under the same GUI-pid namespace.
function M.read_orchestrator(file)
  local f = io.open(file, "r")
  if not f then return nil end
  local raw = f:read("*a")
  f:close()
  return tonumber((raw or ""):match("%d+"))
end

function M.write_orchestrator(file, pane_id)
  if not pane_id then
    os.remove(file)
    return
  end
  local f = io.open(file, "w")
  if not f then return end
  f:write(tostring(pane_id))
  f:close()
end

return M
