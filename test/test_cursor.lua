package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test, load_agent = H.test, H.load_agent

H.section("Cursor Agent 状態追跡")

test("正常系：JSONステートファイルが存在するペインをCursor Agentとして検出する", function()
  local cursor = load_agent("service/agents/cursor")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.assert_false(cursor.detect(pane, opts))

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"cursor","state":"idle","ts":1716000000,"session_id":"cur-123"}')
  H.assert_true(cursor.detect(pane, opts))

  os.execute("rm -rf " .. tmp)
end)

test("正常系：別agentのステートファイルではCursor Agentとして検出しない", function()
  local cursor = load_agent("service/agents/cursor")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"claude","state":"working","ts":1716000000,"session_id":""}')
  H.assert_false(cursor.detect(pane, opts))

  os.execute("rm -rf " .. tmp)
end)

test("正常系：JSONステートファイルからエージェントの状態を読み取れる", function()
  local cursor = load_agent("service/agents/cursor")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.assert_eq(cursor.state(pane, opts), "unknown")

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"cursor","state":"unknown","ts":1716000000,"session_id":""}')
  H.assert_eq(cursor.state(pane, opts), "unknown")

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"cursor","state":"done","ts":1716000000,"session_id":""}')
  H.assert_eq(cursor.state(pane, opts), "done")

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"cursor","state":"waiting","ts":1716000000,"session_id":""}')
  H.assert_eq(cursor.state(pane, opts), "waiting")

  os.execute("rm -rf " .. tmp)
end)

test("正常系：JSONステートファイルからセッションIDを取得できる", function()
  local cursor = load_agent("service/agents/cursor")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.assert_nil(cursor.session_id(pane, opts))

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"cursor","state":"idle","ts":1716000000,"session_id":"2fae251a-fec0-46ce"}')
  H.assert_eq(cursor.session_id(pane, opts), "2fae251a-fec0-46ce")

  os.execute("rm -rf " .. tmp)
end)

test("異常系：空ファイルや不正JSONの場合はunknownまたはnilを返す", function()
  local cursor = load_agent("service/agents/cursor")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.write_file(tmp .. "/wezterm-agent-p1", "")
  H.assert_eq(cursor.state(pane, opts), "unknown")
  H.assert_nil(cursor.session_id(pane, opts))

  H.write_file(tmp .. "/wezterm-agent-p1", "{invalid json")
  H.assert_eq(cursor.state(pane, opts), "unknown")
  H.assert_false(cursor.detect(pane, opts))

  os.execute("rm -rf " .. tmp)
end)

H.section("Cursor Agent done→unknown自動遷移")

test("正常系：done状態のペインを閲覧するとunknownに遷移する", function()
  local cursor = load_agent("service/agents/cursor")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }
  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"cursor","state":"done","ts":1716000000,"session_id":"s1"}')

  local consumed = cursor.consume_done(pane, opts)

  H.assert_true(consumed)
  local content = H.read_file(tmp .. "/wezterm-agent-p1")
  H.assert_match(content, '"state":"unknown"')
  H.assert_match(content, '"agent":"cursor"')

  os.execute("rm -rf " .. tmp)
end)

test("正常系：done以外の状態ではconsume_doneは何もしない", function()
  local cursor = load_agent("service/agents/cursor")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.assert_false(cursor.consume_done(pane, opts))

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"cursor","state":"working","ts":1716000000,"session_id":""}')
  H.assert_false(cursor.consume_done(pane, opts))

  os.execute("rm -rf " .. tmp)
end)

test("正常系：別agentのdone状態ではconsume_doneは何もしない", function()
  local cursor = load_agent("service/agents/cursor")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"claude","state":"done","ts":1716000000,"session_id":""}')
  H.assert_false(cursor.consume_done(pane, opts))

  os.execute("rm -rf " .. tmp)
end)

H.section("Cursor Agent セッション起動コマンド生成")

test("正常系：シェル経由でCursor Agentを起動するコマンドを生成する", function()
  local cursor = load_agent("service/agents/cursor")
  local opts = { command = "cursor-agent", shell = "/bin/zsh", status_dir = "/tmp" }

  local args = cursor.spawn_args(opts)

  H.assert_eq(#args, 3)
  H.assert_eq(args[1], "/bin/zsh")
  H.assert_eq(args[2], "-lc")
  H.assert_match(args[3], "cursor%-agent")
end)

test("正常系：session_id指定時は--resumeフラグ付きで起動する", function()
  local cursor = load_agent("service/agents/cursor")
  local opts = { command = "cursor-agent", shell = "/bin/zsh", status_dir = "/tmp" }

  local args = cursor.spawn_args(opts, "2fae251a-fec0-46ce")

  H.assert_match(args[3], "%-%-resume '2fae251a%-fec0%-46ce'")
end)

test("正常系：cwd指定時はcdプレフィックス付きで起動する", function()
  local cursor = load_agent("service/agents/cursor")
  local opts = { command = "cursor-agent", shell = "/bin/zsh", status_dir = "/tmp" }

  local args = cursor.spawn_args(opts, nil, "/home/user/project")

  H.assert_match(args[3], "cd '/home/user/project'")
end)

H.finish()
