package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test, load_mod = H.test, H.load_mod

H.section("タブ表示用パス省略")

test("正常系：深いパスの中間ディレクトリを1文字に省略し末尾は保持する", function()
  local ui = load_mod("ui/ui")

  H.assert_eq(ui.shorten_path("/Users/foo/bar/baz/qux"), "/U/f/b/b/qux")
  H.assert_eq(ui.shorten_path("~/dev/projects/myapp"), "~/d/p/myapp")
end)

test("正常系：省略不要なパスはそのまま返す", function()
  local ui = load_mod("ui/ui")

  H.assert_eq(ui.shorten_path("/single"), "/single")
  H.assert_eq(ui.shorten_path("~"), "~")
  H.assert_eq(ui.shorten_path("/"), "/")
  H.assert_eq(ui.shorten_path(""), "")
end)

H.section("ステータスバー用パス幅収め (truncate_cwd)")

test("正常系：超過時は前方(祖先)を残し末尾を切って … を付す", function()
  local ui = load_mod("ui/ui")
  H.assert_eq(ui.truncate_cwd("~/g/wezterm-ai-agents", 20), "~/g/wezterm-ai-agen…")
end)

test("正常系：収まる場合はパディングせずそのまま返す (短いパスは右へ詰まる)", function()
  local ui = load_mod("ui/ui")
  H.assert_eq(ui.truncate_cwd("~/code", 10), "~/code")
end)

test("正常系：全角(CJK)が収まる場合もパディングせずそのまま返す", function()
  local ui = load_mod("ui/ui")
  -- "~/プロジェクト" = ASCII 2 + 全角 6×2 = 14 桁 ≤ 20 なので無加工。
  H.assert_eq(ui.truncate_cwd("~/プロジェクト", 20), "~/プロジェクト")
end)

test(
  "正常系：全角(CJK)が超過する場合もセル幅基準で切り、多バイト境界を割らずオーバーフローしない",
  function()
    local ui = load_mod("ui/ui")
    -- "~/プロジェクト管理システム" = ASCII 2 + 全角 12×2 = 26 桁 > 20。
    -- truncate_right(s, 19) は 18 桁(~/ + 全角8) で止まり、+ "…" で 19 桁に収まる。
    -- バイト基準で切ると全角の途中で割れて壊れた UTF-8 になり、結果も桁も崩れる。
    H.assert_eq(ui.truncate_cwd("~/プロジェクト管理システム", 20), "~/プロジェクト管理…")
    -- fix の主張 (オーバーフローしない) を直接検証: 結果のセル幅は必ず w 以下。
    H.assert_eq(wezterm.column_width(ui.truncate_cwd("~/プロジェクト管理システム", 20)) <= 20, true)
  end
)

H.section("ステータスバー集計セグメント")

test("正常系：unknown状態がステータスバーに表示される", function()
  local ui = load_mod("ui/ui")
  local mock_agent = {
    count = function() return { working = 0, waiting = 0, done = 0, idle = 0, error = 0, unknown = 2 } end,
  }
  local colors = { unknown = "#6c7086", working = "#f5c778" }
  local icons = { unknown = "U", working = "W" }

  local segs = ui.agent_count_segments({}, mock_agent, colors, icons)

  local text = ""
  for _, s in ipairs(segs) do
    if s.Text then text = text .. s.Text end
  end
  H.assert_match(text, "U 2")
end)

test("正常系：色またはアイコンが未定義の状態はセグメントに含まれない", function()
  local ui = load_mod("ui/ui")
  local mock_agent = {
    count = function() return { working = 1, waiting = 0, done = 0, idle = 0, error = 0, unknown = 0 } end,
  }
  local colors = {}
  local icons = {}

  local segs = ui.agent_count_segments({}, mock_agent, colors, icons)

  H.assert_eq(#segs, 0)
end)

H.section("タブタイトルの組み立て (format_tab_title)")

-- format_tab_title 用の deps。resolve は (impl, state) を返すスタブ。
local function tab_deps(resolve)
  return {
    opts = {
      ui = {
        tab_title = {
          max_chars = 20,
          active_bg = "#000",
          active_fg = "#fff",
          accent_fg = "#b4befe",
          inactive_bg = "#111",
          inactive_fg = "#888",
        },
        right_status = { reserve = 40 },
      },
    },
    agent = { resolve = resolve },
  }
end

local function seg_text(segs)
  local t = {}
  for _, s in ipairs(segs) do
    if s.Text then t[#t + 1] = s.Text end
  end
  return table.concat(t)
end

-- mux スタブ: get_pane は pane_id を返すペイン、get_window は cols 固定のタブを返す
local function with_mux(cols, fn)
  local op, ow = wezterm.mux.get_pane, wezterm.mux.get_window
  wezterm.mux.get_pane = function(id)
    return { pane_id = function() return id end }
  end
  wezterm.mux.get_window = function()
    return {
      active_tab = function()
        return { get_size = function() return { cols = cols } end }
      end,
    }
  end
  local ok, err = pcall(fn)
  wezterm.mux.get_pane, wezterm.mux.get_window = op, ow
  if not ok then error(err) end
end

test("正常系：active+アイコンありでアイコンとタイトルが描画される", function()
  local ui = load_mod("ui/ui")
  local deps = tab_deps(function() return { icons = { working = "W" }, colors = { working = "#0f0" } }, "working" end)
  with_mux(120, function()
    local tab = { active_pane = { pane_id = "p1", title = "server" }, window_id = 1, is_active = true }
    local txt = seg_text(ui.format_tab_title(tab, deps, nil, 1))
    H.assert_match(txt, "W")
    H.assert_match(txt, "server")
  end)
end)

test("正常系：idle状態ではアイコンが落ちる", function()
  local ui = load_mod("ui/ui")
  local deps = tab_deps(function() return { icons = { idle = "I" }, colors = {} }, "idle" end)
  with_mux(120, function()
    local tab = { active_pane = { pane_id = "p1", title = "server" }, window_id = 1, is_active = false }
    local txt = seg_text(ui.format_tab_title(tab, deps, nil, 1))
    H.assert_true(not txt:find("I", 1, true), "idle ではアイコン I が出ないこと")
    H.assert_match(txt, "server")
  end)
end)

test("監督オーケストレーターのタブは専用アイコンで描画される (idle でも落ちない)", function()
  local ui = load_mod("ui/ui")
  local deps = tab_deps(function() return { icons = { idle = "I" }, colors = {} }, "idle" end)
  deps.opts.icons = { orchestrator = "EYE" }
  deps.opts.ui.tab_title.orchestrator_fg = "#f9e2af"
  deps.opts.orchestrator_file = "o"
  deps.managed = { is_orchestrator = function(_, pid) return pid == "p1" end }
  with_mux(120, function()
    local tab = { active_pane = { pane_id = "p1", title = "claude" }, window_id = 1, is_active = true }
    local txt = seg_text(ui.format_tab_title(tab, deps, nil, 1))
    H.assert_match(txt, "EYE")
  end)
end)

test("正常系：長いタイトルは…付きで切り詰められる", function()
  local ui = load_mod("ui/ui")
  local deps = tab_deps(function() return nil end)
  with_mux(120, function()
    local tab = { active_pane = { pane_id = "p1", title = string.rep("a", 100) }, window_id = 1, is_active = false }
    local txt = seg_text(ui.format_tab_title(tab, deps, nil, 1))
    H.assert_match(txt, "…")
  end)
end)

test("正常系：num_tabsが多いほどavailが縮みタイトルが短くなる", function()
  local ui = load_mod("ui/ui")
  local deps = tab_deps(function() return nil end)
  with_mux(120, function()
    local tab = { active_pane = { pane_id = "p1", title = string.rep("a", 100) }, window_id = 1, is_active = false }
    local txt1 = seg_text(ui.format_tab_title(tab, deps, nil, 1))
    local txt8 = seg_text(ui.format_tab_title(tab, deps, nil, 8))
    H.assert_true(#txt8 < #txt1, "タブ数が多いほど表示タイトルが短いこと")
  end)
end)

H.finish()
