package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test = H.test

local function build_with_opts(opts)
  local selector = H.load_mod("selector")
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
  local workspace = H.load_mod("workspace")
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

H.finish()
