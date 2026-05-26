package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test, load_mod = H.test, H.load_mod

H.section("プラグイン初期化")

test("正常系：全モジュールがエラーなくロードできる", function()
  local modules = {
    "agent",
    "workspace",
    "worktree",
    "layout",
    "ui",
    "selector",
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
