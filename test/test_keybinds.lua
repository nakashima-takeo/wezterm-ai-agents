package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test = H.test

local function build_with_opts(opts)
  local selector = H.load_selector()
  local agent = H.load_mod("service/agent")
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
  local layout = H.load_mod("state/layout")
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

  local agent = H.load_mod("service/agent")
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

  local labels = H.load_mod("resource/labels")
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
    layout = H.load_mod("state/layout"),
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

  -- update-status から毎回呼ばれる主要結線点 maybe_prefetch の再エクスポート (setup 内 M.maybe_prefetch = wt.maybe_prefetch) も踏む。
  -- pane.get_current_working_dir が nil を返すため cwd nil で早期 return し、worktree モック未参照で nil 参照しない。
  H.assert_not_nil(selector.maybe_prefetch, "maybe_prefetch should be re-exported by setup()")
  selector.maybe_prefetch(window, pane, deps)
end)

H.section("format_keybind の修飾キー記号 (OS / nerd_font 分岐)")

-- ⌃⇧⌘ の Unicode バイト列
local U_CTRL, U_SHIFT, U_CMD = "\xE2\x8C\x83", "\xE2\x87\xA7", "\xE2\x8C\x98"

test("non-darwin では nerd でも Unicode 記号に倒す (Apple グリフ豆腐化を防ぐ)", function()
  local ui = H.load_mod("ui/selector/ui")
  local orig = wezterm.target_triple
  wezterm.target_triple = "x86_64-unknown-linux-gnu"
  -- CTRL|SHIFT は表示順 ⌃⌥⇧⌘ に並び、key はそのまま。NERD_MODS (Apple グリフ) は使われない。
  H.assert_eq(ui.format_keybind("S", "CTRL|SHIFT", true), U_CTRL .. " " .. U_SHIFT .. " S")
  wezterm.target_triple = orig
end)

test("darwin + nerd_font では NERD_MODS (Apple グリフ) を使う", function()
  local ui = H.load_mod("ui/selector/ui")
  local orig = wezterm.target_triple
  wezterm.target_triple = "aarch64-apple-darwin"
  -- mock の nerdfonts は全グリフ "?" を返す。SHIFT/CMD の 2 グリフが引かれることを確認。
  H.assert_eq(ui.format_keybind("S", "CMD|SHIFT", true), "? ? S")
  wezterm.target_triple = orig
end)

test("nerd_font=false は OS 非依存で Unicode 記号 (表示順 ⌃⌥⇧⌘)", function()
  local ui = H.load_mod("ui/selector/ui")
  H.assert_eq(ui.format_keybind("S", "CMD|SHIFT", false), U_SHIFT .. " " .. U_CMD .. " S")
end)

H.section("セレクタ選択ロジック (InputSelector 内側 callback)")

-- 共通の opts/deps を組む。create を spy で差し替えて実 spawn を避ける。
local function selector_env()
  local selector = H.load_selector()
  local agent = H.load_mod("service/agent")
  agent.register({
    id = "test",
    display_name = "T",
    default_opts = {},
    detect = function() return false end,
    state = function() return "idle" end,
    session_id = function() return nil end,
    spawn_args = function() return {} end,
  })
  local ws_file = H.tmp_dir() .. "/ws.json"
  H.write_file(ws_file, '{"workspaces":[{"name":"demo","cwd":"/tmp"}]}')
  local labels = H.load_mod("resource/labels")
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
  local deps = { opts = opts, agent = agent, workspace = H.load_workspace(), layout = H.load_mod("state/layout") }
  return selector, deps
end

test("正常系：pin_toggle を2回踏むと pinned_windows が true→nil とトグルする", function()
  local selector, deps = selector_env()
  local keys = selector.build_keybinds(deps)
  local pin = find_by_action_key(keys, "P")
  H.assert_not_nil(pin, "pin_toggle keybind should exist")

  local window = { perform_action = function() end, toast_notification = function() end, window_id = function() return 42 end }
  local id = "42"

  pin.action.__callback(window, {})
  H.assert_true(selector.pinned_windows[id] == true, "1回目で pin される")
  pin.action.__callback(window, {})
  H.assert_nil(selector.pinned_windows[id], "2回目で pin 解除される")
end)

-- InputSelector をキャプチャし、内側 callback の perform_action を記録する window を作る。
local function capturing_window()
  local actions = {}
  local captured
  local window = {
    perform_action = function(_, action)
      if type(action) == "table" and action.__action == "InputSelector" then
        captured = action.arg
      else
        table.insert(actions, action)
      end
    end,
    toast_notification = function() end,
    window_id = function() return 1 end,
    active_workspace = function() return "default" end,
  }
  return window, function() return captured end, actions
end

test("正常系：workspace_selector で未起動 ws:demo を選ぶと create + SwitchToWorkspace が走る", function()
  local selector, deps = selector_env()

  -- create を spy (実 spawn を避ける)
  local created
  deps.workspace.create = function(cfg) created = cfg and cfg.name end

  local keys = selector.build_keybinds(deps)
  local s = find_by_action_key(keys, "S") -- workspace_selector
  H.assert_not_nil(s, "workspace_selector keybind should exist")

  local window, get_captured, actions = capturing_window()
  local pane = { get_current_working_dir = function() return nil end }

  s.action.__callback(window, pane) -- セレクタを開く (InputSelector をキャプチャ)
  local captured = get_captured()
  H.assert_not_nil(captured, "InputSelector が発行される")

  -- 内側 callback を id="ws:demo" で起動 (= 実際の選択処理)
  captured.action.__callback(window, pane, "ws:demo")

  H.assert_eq(created, "demo", "未起動WSの選択で create が呼ばれる")
  local switched
  for _, a in ipairs(actions) do
    if type(a) == "table" and a.__action == "SwitchToWorkspace" then switched = a.arg.name end
  end
  H.assert_eq(switched, "demo", "create 後に当該WSへ SwitchToWorkspace する")
end)

test("正常系：InputSelector の内側 callback は id=nil / 区切り行で何もしない", function()
  local selector, deps = selector_env()
  local keys = selector.build_keybinds(deps)
  local s = find_by_action_key(keys, "S")

  local window, get_captured = capturing_window()
  local pane = { get_current_working_dir = function() return nil end }

  s.action.__callback(window, pane)
  local captured = get_captured()
  -- nil / 区切り行は早期 return (nil 参照やクラッシュしないこと)
  captured.action.__callback(window, pane, nil)
  captured.action.__callback(window, pane, "_sep_actions")
end)

H.finish()
