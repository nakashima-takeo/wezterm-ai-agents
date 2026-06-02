package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test = H.test

local function build_with_opts(opts)
  local selector = H.load_selector()
  local agent = H.load_mod("agent")
  agent.register({
    id = "test",
    display_name = "Test",
    default_opts = {},
    detect = function() return false end,
    state = function() return "idle" end,
    session_id = function() return nil end,
    spawn_args = function() return {} end,
  })
  local workspace = H.load_workspace()
  local layout = H.load_mod("layout")
  local deps = {
    opts = opts,
    agent = agent,
    workspace = workspace,
    layout = layout,
  }
  return selector.build_keybinds(deps)
end

local function find_keybind(keys, id_key, id_mods)
  for _, k in ipairs(keys) do
    if k.key == id_key and k.mods == id_mods then return k end
  end
  return nil
end

local function find_by_action_key(keys, target_key)
  for _, k in ipairs(keys) do
    if k.key == target_key then return k end
  end
  return nil
end

H.section("keybinds オーバーライド")

test("正常系：key と mods の両方をオーバーライドできる", function()
  local keys = build_with_opts({
    disabled_keybinds = {},
    keybinds = { workspace_selector = { key = "p", mods = "CTRL|SHIFT" } },
  })
  local found = find_by_action_key(keys, "p")
  H.assert_not_nil(found, "overridden keybind should exist")
  H.assert_eq(found.mods, "CTRL|SHIFT")
  local original = find_keybind(keys, "S", "CMD|SHIFT")
  H.assert_nil(original, "original keybind should not exist")
end)

test("正常系：key のみオーバーライドで mods はデフォルト維持", function()
  local keys = build_with_opts({
    disabled_keybinds = {},
    keybinds = { new_tab = { key = "n" } },
  })
  local found = find_by_action_key(keys, "n")
  H.assert_not_nil(found, "overridden keybind should exist")
  H.assert_eq(found.mods, "CMD", "mods should remain default")
end)

test("正常系：mods のみオーバーライドで key はデフォルト維持", function()
  local keys = build_with_opts({
    disabled_keybinds = {},
    keybinds = { new_tab = { mods = "CTRL" } },
  })
  local found = find_keybind(keys, "t", "CTRL")
  H.assert_not_nil(found, "keybind with overridden mods should exist")
end)

test("disabled_keybinds が keybinds オーバーライドより優先される", function()
  local keys = build_with_opts({
    disabled_keybinds = { "workspace_selector" },
    keybinds = { workspace_selector = { key = "p", mods = "CTRL" } },
  })
  local found = find_by_action_key(keys, "p")
  H.assert_nil(found, "disabled keybind should not appear even with override")
end)

local function count_by_action_key(keys, target_key)
  local n = 0
  for _, k in ipairs(keys) do
    if k.key == target_key then n = n + 1 end
  end
  return n
end

test("正常系：同一ID複数キー（move_tab_left）はオーバーライドなしで両方登録される", function()
  local keys = build_with_opts({ disabled_keybinds = {}, keybinds = {} })
  local bracket = find_keybind(keys, "[", "CMD|SHIFT")
  local brace = find_keybind(keys, "{", "CMD|SHIFT")
  H.assert_not_nil(bracket, "[ keybind should exist")
  H.assert_not_nil(brace, "{ keybind should exist")
end)

test("正常系：同一ID複数キーのオーバーライドでキーバインドが1つだけ登録される", function()
  local keys = build_with_opts({
    disabled_keybinds = {},
    keybinds = { move_tab_left = { key = "h" } },
  })
  local count = count_by_action_key(keys, "h")
  H.assert_eq(count, 1, "overridden key should appear exactly once")
  local bracket = find_keybind(keys, "[", "CMD|SHIFT")
  H.assert_nil(bracket, "original [ keybind should not exist")
  local brace = find_keybind(keys, "{", "CMD|SHIFT")
  H.assert_nil(brace, "original { keybind should not exist")
end)

test("正常系：同一ID複数キーのdisabledで両方とも登録されない", function()
  local keys = build_with_opts({
    disabled_keybinds = { "move_tab_left" },
    keybinds = {},
  })
  local bracket = find_keybind(keys, "[", "CMD|SHIFT")
  local brace = find_keybind(keys, "{", "CMD|SHIFT")
  H.assert_nil(bracket, "disabled [ keybind should not exist")
  H.assert_nil(brace, "disabled { keybind should not exist")
end)

test("正常系：keybinds が空の場合はデフォルトが使われる", function()
  local keys = build_with_opts({
    disabled_keybinds = {},
    keybinds = {},
  })
  local found = find_keybind(keys, "S", "CMD|SHIFT")
  H.assert_not_nil(found, "default keybind should exist")
end)

test("正常系：ヘルプ (Cmd+Shift+H) が登録される", function()
  local keys = build_with_opts({ disabled_keybinds = {}, keybinds = {} })
  H.assert_not_nil(find_keybind(keys, "H", "CMD|SHIFT"), "help keybind should exist")
end)

test("disabled_keybinds でヘルプを無効化できる", function()
  local keys = build_with_opts({ disabled_keybinds = { "help" }, keybinds = {} })
  H.assert_nil(find_keybind(keys, "H", "CMD|SHIFT"), "disabled help keybind should not exist")
end)

H.section("セレクタ callback スモーク (注入配線の退行検出)")

-- selector を分割サブモジュール構成で結線し、主要セレクタ callback を mock window/pane で
-- 1 回ずつ実行する。build_keybinds は未実行クロージャを作るだけなので、setup() の結線漏れや
-- サブモジュールの再エクスポート漏れは「キー表の構築は成功・実行時に nil 参照」で表面化する。
-- この実行テストがその nil 参照を炙る。
test("退行検出：主要セレクタ callback が nil 参照なく実行できる", function()
  local selector = H.load_selector()

  local agent = H.load_mod("agent")
  agent.register({
    id = "test",
    display_name = "Test",
    default_opts = {},
    detect = function() return false end,
    state = function() return "idle" end,
    session_id = function() return nil end,
    spawn_args = function() return {} end,
  })

  -- ワークスペースを 1 件含む状態ファイル。workspace_selector が UI ヘルパー (build_ws_header
  -- 等) 経由でこれを描画するため、selector/ui の二段注入も実行経路で踏まれる。
  local ws_file = H.tmp_dir() .. "/ws.json"
  H.write_file(ws_file, '{"workspaces":[{"name":"demo","cwd":"/tmp"}]}')

  local labels = H.load_mod("labels")
  local opts = {
    labels = labels.en,
    workspace = { file = ws_file, default_workspace = "default" },
    ui = { right_status = { colors = {}, icons = { idle = "i" } } },
    icons = { folder = "F" },
    nerd_font = false,
    default_tabs = { {} },
    modifier_prefix = "CMD",
    disabled_keybinds = {},
    keybinds = {},
  }
  local deps = {
    opts = opts,
    agent = agent,
    workspace = H.load_workspace(),
    layout = H.load_mod("layout"),
    worktree = {}, -- cwd 取得不可で早期 return するため未参照
    editor = { detect = function() return nil end },
  }

  local window = {
    perform_action = function() end,
    toast_notification = function() end,
    window_id = function() return 1 end,
    active_workspace = function() return "default" end,
  }
  local pane = { get_current_working_dir = function() return nil end }

  local keys = selector.build_keybinds(deps)
  -- workspace/worktree/agent/help/editor/pin の各 callback (= 各サブモジュール境界) を踏む
  for _, target in ipairs({ "S", "X", "A", "H", "E", "P" }) do
    local k = find_by_action_key(keys, target)
    H.assert_not_nil(k, target .. " keybind should exist")
    local cb = k.action.__callback
    H.assert_not_nil(cb, target .. " keybind should have a callback")
    cb(window, pane) -- 結線漏れがあればここで nil 参照エラー → テスト fail
  end
end)

H.finish()
