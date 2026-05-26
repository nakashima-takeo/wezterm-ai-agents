package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test, load_mod = H.test, H.load_mod

H.section("タブ表示用パス省略")

test("正常系：深いパスの中間ディレクトリを1文字に省略し末尾は保持する", function()
  local ui = load_mod("ui")

  H.assert_eq(ui.shorten_path("/Users/foo/bar/baz/qux"), "/U/f/b/b/qux")
  H.assert_eq(ui.shorten_path("~/dev/projects/myapp"), "~/d/p/myapp")
end)

test("正常系：省略不要なパスはそのまま返す", function()
  local ui = load_mod("ui")

  H.assert_eq(ui.shorten_path("/single"), "/single")
  H.assert_eq(ui.shorten_path("~"), "~")
  H.assert_eq(ui.shorten_path("/"), "/")
  H.assert_eq(ui.shorten_path(""), "")
end)

H.section("ステータスバー集計セグメント")

test("正常系：unknown状態がステータスバーに表示される", function()
  local ui = load_mod("ui")
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
  local ui = load_mod("ui")
  local mock_agent = {
    count = function() return { working = 1, waiting = 0, done = 0, idle = 0, error = 0, unknown = 0 } end,
  }
  local colors = {}
  local icons = {}

  local segs = ui.agent_count_segments({}, mock_agent, colors, icons)

  H.assert_eq(#segs, 0)
end)

H.finish()
