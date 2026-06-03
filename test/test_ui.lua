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

H.finish()
