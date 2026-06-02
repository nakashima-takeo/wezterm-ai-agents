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

H.section("ステータスバー用パス幅収め (fixed_width)")

test("正常系：超過時は前方(祖先)を残し末尾を切って … を付す", function()
  local ui = load_mod("ui/ui")
  H.assert_eq(ui.fixed_width("~/g/wezterm-ai-agents", 20), "~/g/wezterm-ai-agen…")
end)

test("正常系：収まる場合は左パディングで桁を揃える", function()
  local ui = load_mod("ui/ui")
  H.assert_eq(ui.fixed_width("~/code", 10), "    ~/code")
end)

test("正常系：全角(CJK)はセル幅2桁で数えてパディングを揃える", function()
  local ui = load_mod("ui/ui")
  -- "~/プロジェクト" = ASCII 2 + 全角 6×2 = 14 桁。20 桁なら左に 6 桁ぶんの空白。
  -- コードポイント数 (8) で数える旧実装だと空白が 12 個になり整列が崩れる。
  H.assert_eq(ui.fixed_width("~/プロジェクト", 20), string.rep(" ", 6) .. "~/プロジェクト")
end)

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
