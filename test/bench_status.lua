-- Performance reproduction harness for the update-status read path.
--
-- Models a WezTerm session as it actually behaves:
--   * GUI windows  -> update-status fires ONCE PER GUI WINDOW per tick.
--                     Typical usage is a single GUI window (gui=1).
--   * MuxWindows   -> mux.all_windows() returns one per workspace, INCLUDING
--                     non-visible (background) workspaces. count() scans all of
--                     them to produce the whole-session "全ワークスペース合計".
--   * tabs / panes -> per workspace.
--
-- It writes a real per-pane status file for each pane and counts how many
-- status-file reads + how much wall-clock a tick costs through the real path:
-- ui.right_status_segments -> agent.count -> classify_pane -> read_state_file.
--
-- Run: luajit test/bench_status.lua [workspaces] [tabs] [panes_per_tab] [gui_windows]

package.path = package.path .. ";test/?.lua"
local mock = require("mock_wezterm")
package.preload["wezterm"] = function() return mock end
_G.wezterm = mock

local PLUGIN_DIR = io.popen("pwd"):read("*l")
local function load_mod(rel) return dofile(PLUGIN_DIR .. "/plugin/" .. rel .. ".lua") end

-- ===== load plugin modules and register all 4 agents =====
local agent = load_mod("agent")
for _, id in ipairs({ "claude", "codex", "cursor", "gemini" }) do
  agent.register(load_mod("agents/" .. id))
end
local ui = load_mod("ui")
local icons = load_mod("icons")

-- ===== count status-file reads by wrapping read_state_file (a spy) =====
-- The hot path (right_status_segments -> count) reads only via this, so wrapping
-- it measures exactly the reads we care about, without touching global io.open.
local read_count = 0
local real_read = agent.read_state_file
agent.read_state_file = function(pane_id, dir)
  read_count = read_count + 1
  return real_read(pane_id, dir)
end

-- ===== params =====
local WS = tonumber(arg[1]) or 3 -- workspaces (== MuxWindows returned by mux)
local T = tonumber(arg[2]) or 5 -- tabs per workspace
local P = tonumber(arg[3]) or 3 -- panes per tab
local GUI = tonumber(arg[4]) or 1 -- GUI windows (== update-status firings per tick)
local TICKS = 60 -- simulate 60 ticks (~1 minute at 1Hz)

-- ===== temp status dir + per-pane state files =====
local status_dir = os.tmpname()
os.remove(status_dir)
os.execute("mkdir -p " .. status_dir)

local STATES = { "working", "waiting", "done", "idle" }
local pane_seq = 0
local function make_pane()
  pane_seq = pane_seq + 1
  local id = pane_seq
  -- ~80% of panes are real claude agents, rest have no state file (non-agent).
  if id % 5 ~= 0 then
    local st = STATES[(id % #STATES) + 1]
    local json = string.format('{"agent":"claude","state":"%s","ts":%d,"session_id":"sess-%d"}', st, 1700000000 + id, id)
    local f = io.open(status_dir .. "/wezterm-agent-" .. id, "w")
    f:write(json .. "\n")
    f:close()
  end
  return {
    pane_id = function() return id end,
    get_current_working_dir = function() return { file_path = "/Users/x/dev/project-" .. id } end,
  }
end

-- ===== build mock mux: one MuxWindow per workspace =====
local mux_windows = {}
for w = 1, WS do
  local tabs = {}
  for _ = 1, T do
    local panes = {}
    for _ = 1, P do
      table.insert(panes, make_pane())
    end
    table.insert(tabs, {
      panes = function() return panes end,
      get_size = function() return { cols = 200 } end,
    })
  end
  mux_windows[w] = {
    get_workspace = function() return "ws-" .. w end,
    tabs = function() return tabs end,
    active_tab = function() return tabs[1] end,
  }
end
mock.mux.all_windows = function() return mux_windows end

-- ===== GUI window object passed to right_status_segments =====
local function make_gui_window(wid)
  return {
    window_id = function() return wid end,
    active_workspace = function() return "ws-1" end,
  }
end

-- ===== minimal opts/deps (mirror init.lua defaults needed by ui) =====
local opts = {
  status_dir = status_dir,
  ui = {
    right_status = {
      fg = "#fff",
      colors = { working = "#0f0", waiting = "#ff0", done = "#00f", idle = "#888", error = "#f00", unknown = "#888" },
      icons = icons.unicode,
      cwd_width = 20,
    },
  },
}
-- inject icons into each agent impl (init.lua normally does this)
for _, impl in ipairs(agent.all()) do
  impl.icons = icons.unicode
end
local deps = { opts = opts, agent = agent, selector = { pinned_windows = {} } }

-- ===== measure: each tick, update-status fires once per GUI window =====
local total_panes = WS * T * P
local a_pane = mux_windows[1]:tabs()[1]:panes()[1]
read_count = 0
local t0 = os.clock()
for _ = 1, TICKS do
  for g = 1, GUI do
    local win = make_gui_window(tostring(g))
    local segs = ui.right_status_segments(win, a_pane, deps)
    mock.format(segs)
  end
end
local elapsed = os.clock() - t0

os.execute("rm -rf " .. status_dir)

print(string.format("workspaces=%d tabs/ws=%d panes/tab=%d => %d panes total | gui_windows=%d", WS, T, P, total_panes, GUI))
print(string.format("update-status fires %d times/sec (once per GUI window)", GUI))
print(string.format("status-file reads: %d total over %d ticks", read_count, TICKS))
print(string.format("  -> %.1f reads per SECOND", read_count / TICKS))
print(string.format("  -> %.2f reads per pane per second", read_count / TICKS / total_panes))
print(string.format("wall-clock: %.3f ms per update-status call", elapsed * 1000 / (GUI * TICKS)))
