-- update-status の読み取り経路を対象としたパフォーマンス再現用ハーネス。
--
-- WezTerm のセッションを実挙動どおりにモデル化する:
--   * GUI ウィンドウ -> update-status は GUI ウィンドウごとに 1 ティック 1 回発火する。
--                       一般的な使い方は GUI ウィンドウ 1 枚 (gui=1)。
--   * MuxWindow      -> mux.all_windows() はワークスペースごとに 1 つ返し、非表示
--                       (バックグラウンド) のワークスペースも含む。count() はそれら
--                       すべてを走査してセッション全体の「全ワークスペース合計」を作る。
--   * タブ / ペイン  -> ワークスペースごと。
--
-- 各ペインに実際のペイン別状態ファイルを書き込み、実際の経路:
-- ui.right_status_segments -> agent.count -> classify_pane -> read_state_file
-- を通して、1 ティックあたりの状態ファイル読み取り回数と所要時間を計測する。
--
-- 実行: luajit test/bench_status.lua [workspaces] [tabs] [panes_per_tab] [gui_windows]

package.path = package.path .. ";test/?.lua"
local mock = require("mock_wezterm")
package.preload["wezterm"] = function() return mock end
_G.wezterm = mock

local PLUGIN_DIR = io.popen("pwd"):read("*l")
local function load_mod(rel) return dofile(PLUGIN_DIR .. "/plugin/" .. rel .. ".lua") end

-- ===== プラグインモジュールを読み込み、4 つのエージェントを全て登録 =====
local agent = load_mod("agent")
for _, id in ipairs({ "claude", "codex", "cursor", "gemini" }) do
  agent.register(load_mod("agents/" .. id))
end
local ui = load_mod("ui")
local icons = load_mod("icons")

-- ===== read_state_file をラップ (スパイ) して状態ファイル読み取り回数を数える =====
-- ホットパス (right_status_segments -> count) はこの関数経由でしか読まないため、
-- ここをラップすればグローバルな io.open に触れずに目的の読み取りだけを正確に計測できる。
local read_count = 0
local real_read = agent.read_state_file
agent.read_state_file = function(pane_id, dir)
  read_count = read_count + 1
  return real_read(pane_id, dir)
end

-- ===== パラメータ =====
local WS = tonumber(arg[1]) or 3 -- ワークスペース数 (== mux が返す MuxWindow 数)
local T = tonumber(arg[2]) or 5 -- ワークスペースあたりのタブ数
local P = tonumber(arg[3]) or 3 -- タブあたりのペイン数
local GUI = tonumber(arg[4]) or 1 -- GUI ウィンドウ数 (== 1 ティックあたりの update-status 発火回数)
local TICKS = 60 -- 60 ティック (1Hz でおよそ 1 分) をシミュレート

-- ===== 一時 status_dir + ペイン別状態ファイル =====
local status_dir = os.tmpname()
os.remove(status_dir)
os.execute("mkdir -p " .. status_dir)

local STATES = { "working", "waiting", "done", "idle" }
local pane_seq = 0
local function make_pane()
  pane_seq = pane_seq + 1
  local id = pane_seq
  -- ペインの約 80% は実際の claude エージェント、残りは状態ファイルなし (非エージェント)。
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

-- ===== モック mux を構築: ワークスペースごとに MuxWindow 1 つ =====
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

local function make_gui_window(wid)
  return {
    window_id = function() return wid end,
    active_workspace = function() return "ws-1" end,
  }
end

-- ===== 最小限の opts/deps (ui が必要とする init.lua のデフォルトを再現) =====
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
-- 各エージェント impl にアイコンを注入 (通常は init.lua が行う)
for _, impl in ipairs(agent.all()) do
  impl.icons = icons.unicode
end
local deps = { opts = opts, agent = agent, selector = { pinned_windows = {} } }

-- ===== 計測: 各ティックで update-status は GUI ウィンドウごとに 1 回発火する =====
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
