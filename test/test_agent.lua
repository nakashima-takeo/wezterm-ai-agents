package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test, load_mod = H.test, H.load_mod

local function new_agent(overrides)
  local base = {
    id = "test",
    display_name = "Test Agent",
    default_opts = {},
    detect = function() return false end,
    state = function() return "idle" end,
    session_id = function() return nil end,
    spawn_args = function() return {} end,
  }
  if overrides then
    for k, v in pairs(overrides) do
      base[k] = v
    end
  end
  return base
end

H.section("エージェント登録と取得")

test("正常系：登録したエージェントをIDで取得できる", function()
  local agent = load_mod("agent")
  local impl = new_agent({ id = "claude" })

  agent.register(impl)

  H.assert_eq(agent.get("claude"), impl)
  H.assert_eq(#agent.all(), 1)
end)

test("正常系：同一IDの再登録は既存を置き換え、一覧が重複しない", function()
  local agent = load_mod("agent")
  local v1 = new_agent({ id = "claude", display_name = "v1" })
  local v2 = new_agent({ id = "claude", display_name = "v2" })

  agent.register(v1)
  agent.register(v2)

  H.assert_eq(agent.get("claude").display_name, "v2")
  H.assert_eq(#agent.all(), 1)
end)

test("異常系：idなしやnilの登録はエラーになる", function()
  local agent = load_mod("agent")

  H.assert_error(function() agent.register({ display_name = "NoId" }) end)
  H.assert_error(function() agent.register(nil) end)
end)

H.section("設定マージ")

test("正常系：ユーザー設定がデフォルト設定を上書きし、未指定のデフォルトは保持される", function()
  local agent = load_mod("agent")
  local impl = new_agent({
    id = "claude",
    default_opts = { command = "claude", shell = "/bin/zsh" },
  })
  agent.register(impl)

  local opts = agent.opts_for(impl, {
    agents = { claude = { command = "claude --verbose", extra = true } },
  })

  H.assert_eq(opts.command, "claude --verbose")
  H.assert_eq(opts.shell, "/bin/zsh")
  H.assert_true(opts.extra)
end)

test("正常系：ユーザー設定がない場合はデフォルトがそのまま使われる", function()
  local agent = load_mod("agent")
  local impl = new_agent({
    id = "claude",
    default_opts = { command = "claude", shell = "/bin/zsh" },
  })
  agent.register(impl)

  local opts = agent.opts_for(impl, {})

  H.assert_eq(opts.command, "claude")
  H.assert_eq(opts.shell, "/bin/zsh")
end)

H.section("状態集計")

test("正常系：unknown状態のペインがカウントされる", function()
  local agent = load_mod("agent")
  local tmp = H.tmp_dir()
  local cursor = load_mod("agents/cursor")
  agent.register(cursor)

  local pane = H.mock_pane("agg1")
  H.write_file(tmp .. "/wezterm-agent-agg1", '{"agent":"cursor","state":"unknown","ts":1716000000,"session_id":""}')

  local mock_win = {
    get_workspace = function() return "test-ws" end,
    tabs = function()
      return {
        { panes = function() return { pane } end },
      }
    end,
  }
  local orig = wezterm.mux.all_windows
  wezterm.mux.all_windows = function() return { mock_win } end

  local counts = agent.count({ agents = { cursor = { status_dir = tmp } } })

  H.assert_eq(counts.unknown, 1)
  H.assert_eq(counts.working, 0)

  wezterm.mux.all_windows = orig
  os.execute("rm -rf " .. tmp)
end)

H.finish()
