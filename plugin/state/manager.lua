-- Manager pane tracking: which pane runs the reception manager for each workspace. One manager
-- per workspace, summoned by CMD+SHIFT+M. The Lua side records it so the summon can focus the
-- existing manager instead of spawning a duplicate, respawn after a manual close, and let the
-- tab renderer mark the manager's tab.
--
-- On-disk schema (per GUI pid namespace, alongside the per-pane state files):
--   manager.json: { "<workspace>": 12 }   -- pane id running the manager, per workspace
--
-- pane ids are mux-global within one GUI process, so the file lives under the same
-- <status_dir>/<gui_pid>/ namespace and is reaped by agent.cleanup_dead_namespaces.

local wezterm = require("wezterm")

local M = {}

-- Read+decode the JSON object file. Missing or invalid -> empty table.
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
    wezterm.log_error("manager.write: JSON encode failed")
    return false
  end

  local tmp = file .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    local dir = file:match("^(.*)/[^/]+$")
    if dir then pcall(wezterm.run_child_process, { "mkdir", "-p", dir }) end
    f = io.open(tmp, "w")
  end
  if not f then
    wezterm.log_error("manager.write: failed to open " .. tmp)
    return false
  end
  f:write(encoded)
  f:close()

  local rok, rerr = os.rename(tmp, file)
  if not rok then
    os.remove(tmp)
    wezterm.log_error("manager.write: rename failed: " .. (rerr or "unknown"))
    return false
  end
  return true
end

-- Read the manager pane id for workspace ws, or nil.
function M.read(file, ws)
  local v = read_json(file)[ws]
  return type(v) == "number" and v or nil
end

-- Record (or clear, with nil) the manager pane id for workspace ws.
function M.write(file, ws, pane_id)
  local map = read_json(file)
  map[ws] = pane_id or nil
  write_json(file, map)
end

-- True when pane_id runs the manager for any workspace (used to mark its tab regardless of which
-- workspace the renderer is in).
function M.is_manager(file, pane_id)
  if not pane_id then return false end
  for _, v in pairs(read_json(file)) do
    if v == pane_id then return true end
  end
  return false
end

return M
