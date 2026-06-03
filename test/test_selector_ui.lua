package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test, load_mod = H.test, H.load_mod

local function seg_text(fmt)
  local t = {}
  for _, s in ipairs(fmt) do
    if s.Text then t[#t + 1] = s.Text end
  end
  return table.concat(t)
end

H.section("shorten_path (home → ~)")

test("正常系：ホーム配下は ~ に置換し、境界(/foobar)は誤マッチしない", function()
  local sui = load_mod("ui/selector/ui")
  local orig = wezterm.home_dir
  wezterm.home_dir = "/foo"

  H.assert_eq(sui.shorten_path("/foo"), "~")
  H.assert_eq(sui.shorten_path("/foo/dev/app"), "~/dev/app")
  -- /foobar はホーム /foo に "/" 境界がないため置換されない
  H.assert_eq(sui.shorten_path("/foobar"), "/foobar")
  -- ホーム外はそのまま
  H.assert_eq(sui.shorten_path("/etc/x"), "/etc/x")

  wezterm.home_dir = orig
end)

H.section("parent_dir")

test("正常系：末尾スラッシュ正規化とルート処理", function()
  local sui = load_mod("ui/selector/ui")

  H.assert_eq(sui.parent_dir("/a/b/c"), "/a/b")
  H.assert_eq(sui.parent_dir("/a/b/"), "/a")
  H.assert_eq(sui.parent_dir("/a"), "/")
  H.assert_eq(sui.parent_dir("/"), "/")
end)

H.section("list_subdirs")

test("正常系：ls -1Ap の出力からディレクトリ行のみ抽出し末尾スラッシュを除く", function()
  local sui = load_mod("ui/selector/ui")
  local orig = wezterm.run_child_process
  wezterm.run_child_process = function() return true, "dirA/\nfile.txt\n.hidden/\nlink@\ndirB/\n" end

  local dirs = sui.list_subdirs("/x")

  wezterm.run_child_process = orig
  H.assert_eq(#dirs, 3)
  H.assert_eq(dirs[1], "dirA")
  H.assert_eq(dirs[2], ".hidden")
  H.assert_eq(dirs[3], "dirB")
end)

test("異常系：ls 失敗時は空リストを返す", function()
  local sui = load_mod("ui/selector/ui")
  local orig = wezterm.run_child_process
  wezterm.run_child_process = function() return false, nil end

  H.assert_eq(#sui.list_subdirs("/x"), 0)

  wezterm.run_child_process = orig
end)

H.section("append_agents_colored")

test("正常系：CHIP順で色+アイコン+×nを積む(working前、done後)", function()
  local sui = load_mod("ui/selector/ui")
  local deps = {
    agent = { count = function() return { working = 2, waiting = 0, done = 1, idle = 0, error = 0 } end },
    opts = {
      ui = {
        right_status = {
          colors = { working = "#f00", done = "#0f0" },
          icons = { working = "W", done = "D" },
        },
      },
    },
  }
  local fmt = {}

  local any = sui.append_agents_colored(fmt, deps, "ws")

  H.assert_true(any)
  local text = seg_text(fmt)
  H.assert_true(text:find("\xC3\x972", 1, true) ~= nil, "working=2 は ×2 サフィックス")
  H.assert_true(text:find("D", 1, true) ~= nil, "done=1 はアイコンのみ")
  -- CHIP_STATE_ORDER で working は done より前
  H.assert_true(text:find("W", 1, true) < text:find("D", 1, true), "working が done より前に並ぶ")
end)

test("正常系：色またはアイコン未定義の状態は積まれない", function()
  local sui = load_mod("ui/selector/ui")
  local deps = {
    agent = { count = function() return { working = 1, waiting = 0, done = 0, idle = 0, error = 0 } end },
    opts = { ui = { right_status = { colors = {}, icons = {} } } },
  }
  local fmt = {}

  H.assert_false(sui.append_agents_colored(fmt, deps, "ws"))
  H.assert_eq(#fmt, 0)
end)

H.section("append_ws_status")

test("正常系：停止中で保存セッションがあれば idle チップを出す", function()
  local sui = load_mod("ui/selector/ui")
  local deps = {
    workspace = { count_saved_sessions = function() return 3 end },
    opts = { ui = { right_status = { icons = { idle = "I" } } } },
  }
  local fmt = {}

  sui.append_ws_status(fmt, { name = "ws" }, false, deps)

  local text = seg_text(fmt)
  H.assert_true(text:find("I", 1, true) ~= nil)
  H.assert_true(text:find("\xC3\x973", 1, true) ~= nil, "保存 3 セッション → ×3")
end)

test("正常系：停止中で保存セッションが無ければ何も積まない", function()
  local sui = load_mod("ui/selector/ui")
  local deps = {
    workspace = { count_saved_sessions = function() return 0 end },
    opts = { ui = { right_status = { icons = {} } } },
  }
  local fmt = {}

  sui.append_ws_status(fmt, { name = "ws" }, false, deps)

  H.assert_eq(#fmt, 0)
end)

H.finish()
