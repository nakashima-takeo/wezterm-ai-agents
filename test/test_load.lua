package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test, load_mod = H.test, H.load_mod

H.section("プラグイン初期化")

test("正常系：全モジュールがエラーなくロードできる", function()
  local modules = {
    "agent",
    "workspace/init",
    "workspace/session",
    "worktree",
    "layout",
    "ui",
    "selector/init",
    "selector/workspace",
    "selector/worktree",
    "selector/ui",
    "editor",
    "links",
    "agents/claude",
    "agents/codex",
    "agents/cursor",
    "agents/gemini",
  }
  for _, name in ipairs(modules) do
    local ok, err = pcall(load_mod, name)
    if not ok then error("load " .. name .. " failed: " .. tostring(err)) end
  end
end)

test("正常系：デフォルト設定でapply()が完了しハンドラとキーバインドが設定される", function()
  wezterm._events = {}
  local init = load_mod("init")
  local config = wezterm.config_builder()

  init.apply(config, { plugin_dir = H.plugin_dir })

  H.assert_not_nil(wezterm._events["format-tab-title"])
  H.assert_not_nil(wezterm._events["update-status"])
  H.assert_true(type(config.keys) == "table" and #config.keys > 0)
end)

test("正常系：デフォルトでタブバースタイルがconfigに設定される", function()
  wezterm._events = {}
  local init = load_mod("init")
  local config = wezterm.config_builder()

  init.apply(config, { plugin_dir = H.plugin_dir })

  H.assert_eq(config.use_fancy_tab_bar, true)
  H.assert_eq(config.show_close_tab_button_in_tabs, false)
  H.assert_eq(config.show_new_tab_button_in_tab_bar, false)
  H.assert_eq(config.hide_tab_bar_if_only_one_tab, false)
  H.assert_eq(config.tab_max_width, 32) -- max_chars(24) + 8
end)

test("正常系：tab_max_width が max_chars に連動する", function()
  wezterm._events = {}
  local init = load_mod("init")
  local config = wezterm.config_builder()

  init.apply(config, { plugin_dir = H.plugin_dir, ui = { tab_title = { max_chars = 40 } } })

  H.assert_eq(config.tab_max_width, 48)
end)

test("正常系：未設定の見た目デフォルトを補う", function()
  wezterm._events = {}
  local init = load_mod("init")
  local config = wezterm.config_builder()

  init.apply(config, { plugin_dir = H.plugin_dir })

  H.assert_eq(config.color_scheme, "Catppuccin Mocha")
  H.assert_eq(config.window_background_opacity, 0.92)
  H.assert_eq(config.macos_window_background_blur, 18)
  H.assert_eq(config.window_decorations, "RESIZE")
  H.assert_eq(config.colors.tab_bar.background, "#11111b")
  H.assert_eq(config.notification_handling, "SuppressFromFocusedPane")
  H.assert_eq(config.scrollback_lines, 20000)
  H.assert_eq(config.freetype_load_target, "Light")
  H.assert_eq(config.window_close_confirmation, "NeverPrompt")
  H.assert_eq(config.initial_cols, 120)
  H.assert_eq(config.initial_rows, 30)
  H.assert_eq(config.window_frame.active_titlebar_bg, "#11111b")
  H.assert_eq(config.window_frame.inactive_titlebar_bg, "#11111b")
  -- 日本語フォールバック (mock は darwin → Hiragino Sans)
  H.assert_eq(config.font.fallback[1], "JetBrains Mono")
  H.assert_eq(config.font.fallback[2], "Hiragino Sans")
end)

test("正常系：opts.font を渡すと primary になり日本語が自動付加される", function()
  wezterm._events = {}
  local init = load_mod("init")
  local config = wezterm.config_builder()

  init.apply(config, { plugin_dir = H.plugin_dir, font = "HackGen Nerd Font" })

  H.assert_eq(config.font.fallback[1], "HackGen Nerd Font") -- primary は利用者指定
  H.assert_eq(config.font.fallback[2], "Hiragino Sans") -- 日本語フォールバックは自動付加
end)

test("正常系：利用者が config.font を直接設定済みなら触らない (非破壊)", function()
  wezterm._events = {}
  local init = load_mod("init")
  local config = wezterm.config_builder()

  config.font = wezterm.font("HackGen Console NF")

  init.apply(config, { plugin_dir = H.plugin_dir })

  H.assert_eq(config.font.family, "HackGen Console NF") -- font_with_fallback で上書きされない
end)

test(
  "正常系：window_frame は利用者の他フィールドを残しつつ titlebar 色を補う (フィールド単位非破壊)",
  function()
    wezterm._events = {}
    local init = load_mod("init")
    local config = wezterm.config_builder()

    config.window_frame = { font_size = 12.0, active_titlebar_bg = "#ff0000" }

    init.apply(config, { plugin_dir = H.plugin_dir })

    H.assert_eq(config.window_frame.font_size, 12.0) -- 利用者の設定は残る
    H.assert_eq(config.window_frame.active_titlebar_bg, "#ff0000") -- 明示値は潰さない
    H.assert_eq(config.window_frame.inactive_titlebar_bg, "#11111b") -- 未設定フィールドは補う
  end
)

test("正常系：見た目デフォルトは利用者の明示設定を潰さない (非破壊)", function()
  wezterm._events = {}
  local init = load_mod("init")
  local config = wezterm.config_builder()

  config.color_scheme = "Tokyo Night"
  config.window_background_opacity = 1.0
  config.notification_handling = "AlwaysShow"
  config.scrollback_lines = 5000
  config.freetype_load_target = "Normal"
  config.window_close_confirmation = "AlwaysPrompt"
  config.initial_cols = 200

  init.apply(config, { plugin_dir = H.plugin_dir })

  H.assert_eq(config.color_scheme, "Tokyo Night")
  H.assert_eq(config.window_background_opacity, 1.0)
  H.assert_eq(config.notification_handling, "AlwaysShow")
  H.assert_eq(config.scrollback_lines, 5000)
  H.assert_eq(config.freetype_load_target, "Normal")
  H.assert_eq(config.window_close_confirmation, "AlwaysPrompt")
  H.assert_eq(config.initial_cols, 200) -- 利用者の値を保持
  H.assert_eq(config.initial_rows, 30) -- 未設定は補う
  H.assert_eq(config.window_decorations, "RESIZE") -- 未設定の項目は補われる
end)

test("正常系：bool フィールドは利用者の false を潰さない (非破壊)", function()
  wezterm._events = {}
  local init = load_mod("init")
  local config = wezterm.config_builder()

  config.use_fancy_tab_bar = false
  config.show_new_tab_button_in_tab_bar = true

  init.apply(config, { plugin_dir = H.plugin_dir })

  H.assert_eq(config.use_fancy_tab_bar, false) -- == nil ガードにより false が保持される
  H.assert_eq(config.show_new_tab_button_in_tab_bar, true)
  H.assert_eq(config.show_close_tab_button_in_tabs, false) -- 未設定の項目は補われる
end)

test("正常系：利用者の tab_max_width を潰さない (非破壊)", function()
  wezterm._events = {}
  local init = load_mod("init")
  local config = wezterm.config_builder()

  config.tab_max_width = 64

  init.apply(config, { plugin_dir = H.plugin_dir })

  H.assert_eq(config.tab_max_width, 64)
end)

test("正常系：ユーザーカスタム設定でapply()が完了する", function()
  wezterm._events = {}
  local init = load_mod("init")
  local config = wezterm.config_builder()

  init.apply(config, {
    plugin_dir = H.plugin_dir,
    agents = { claude = { command = "claude --verbose" } },
    default_tabs = { {}, { agent = "claude" } },
  })

  H.assert_true(#config.keys > 0)
end)

test("正常系：ユーザーのキーバインドがプラグインより後方に配置される", function()
  wezterm._events = {}
  local init = load_mod("init")
  local config = wezterm.config_builder()
  local user_action = function() end
  config.keys = {
    { key = "t", mods = "CMD", action = user_action },
    { key = "Z", mods = "CMD|SHIFT", action = user_action },
  }

  init.apply(config, { plugin_dir = H.plugin_dir })

  local last_cmd_t = nil
  local last_cmd_shift_z = nil
  for _, k in ipairs(config.keys) do
    if k.key == "t" and k.mods == "CMD" then last_cmd_t = k end
    if k.key == "Z" and k.mods == "CMD|SHIFT" then last_cmd_shift_z = k end
  end
  H.assert_eq(last_cmd_t.action, user_action, "user Cmd+T should be last (wins in WezTerm)")
  H.assert_eq(last_cmd_shift_z.action, user_action, "user Cmd+Shift+Z should be last")
end)

test("正常系：WezTermサンドボックス環境（debugライブラリなし）でも動作する", function()
  local saved_debug = _G.debug
  _G.debug = nil
  wezterm._events = {}
  local init = load_mod("init")
  local config = wezterm.config_builder()

  local ok, err = pcall(init.apply, config, { plugin_dir = H.plugin_dir })

  _G.debug = saved_debug
  if not ok then error(err) end
end)

H.finish()
