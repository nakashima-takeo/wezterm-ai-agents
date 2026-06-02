package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test, load_agent = H.test, H.load_agent

H.section("状態追跡（統一JSONフォーマット）")

test("正常系：JSONステートファイルが存在するペインをClaude Codeとして検出する", function()
  local claude = load_agent("service/agents/claude")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.assert_false(claude.detect(pane, opts))

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"claude","state":"idle","ts":1716000000,"session_id":"sess-123"}')
  H.assert_true(claude.detect(pane, opts))

  os.execute("rm -rf " .. tmp)
end)

test("正常系：別agentのステートファイルではClaude Codeとして検出しない", function()
  local claude = load_agent("service/agents/claude")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"cursor","state":"working","ts":1716000000,"session_id":""}')
  H.assert_false(claude.detect(pane, opts))

  os.execute("rm -rf " .. tmp)
end)

test("正常系：JSONステートファイルからエージェントの状態を読み取れる", function()
  local claude = load_agent("service/agents/claude")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.assert_eq(claude.state(pane, opts), "idle")

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"claude","state":"working","ts":1716000000,"session_id":""}')
  H.assert_eq(claude.state(pane, opts), "working")

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"claude","state":"done","ts":1716000000,"session_id":""}')
  H.assert_eq(claude.state(pane, opts), "done")

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"claude","state":"waiting","ts":1716000000,"session_id":""}')
  H.assert_eq(claude.state(pane, opts), "waiting")

  os.execute("rm -rf " .. tmp)
end)

test("正常系：JSONステートファイルからセッションIDを取得できる", function()
  local claude = load_agent("service/agents/claude")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.assert_nil(claude.session_id(pane, opts))

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"claude","state":"idle","ts":1716000000,"session_id":"sess-abc-123"}')
  H.assert_eq(claude.session_id(pane, opts), "sess-abc-123")

  os.execute("rm -rf " .. tmp)
end)

test("異常系：空ファイルや不正JSONの場合はidleまたはnilを返す", function()
  local claude = load_agent("service/agents/claude")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.write_file(tmp .. "/wezterm-agent-p1", "")
  H.assert_eq(claude.state(pane, opts), "idle")
  H.assert_nil(claude.session_id(pane, opts))

  H.write_file(tmp .. "/wezterm-agent-p1", "not json at all")
  H.assert_eq(claude.state(pane, opts), "idle")
  H.assert_false(claude.detect(pane, opts))

  os.execute("rm -rf " .. tmp)
end)

H.section("done→idle自動遷移")

test("正常系：done状態のペインを閲覧するとidleに遷移する", function()
  local claude = load_agent("service/agents/claude")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }
  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"claude","state":"done","ts":1716000000,"session_id":"s1"}')

  local consumed = claude.consume_done(pane, opts)

  H.assert_true(consumed)
  local content = H.read_file(tmp .. "/wezterm-agent-p1")
  H.assert_match(content, '"state":"idle"')
  H.assert_match(content, '"agent":"claude"')

  os.execute("rm -rf " .. tmp)
end)

test("正常系：done以外の状態やファイル未存在ではconsume_doneは何もしない", function()
  local claude = load_agent("service/agents/claude")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.assert_false(claude.consume_done(pane, opts))

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"claude","state":"working","ts":1716000000,"session_id":""}')
  H.assert_false(claude.consume_done(pane, opts))

  os.execute("rm -rf " .. tmp)
end)

test("正常系：別agentのdone状態ではconsume_doneは何もしない", function()
  local claude = load_agent("service/agents/claude")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"cursor","state":"done","ts":1716000000,"session_id":""}')
  H.assert_false(claude.consume_done(pane, opts))

  os.execute("rm -rf " .. tmp)
end)

H.section("セッション起動コマンド生成")

test("正常系：シェル経由でClaude Codeを起動するコマンドを生成する", function()
  local claude = load_agent("service/agents/claude")
  local opts = { command = "claude", shell = "/bin/zsh", status_dir = "/tmp" }

  local args = claude.spawn_args(opts)

  H.assert_eq(#args, 3)
  H.assert_eq(args[1], "/bin/zsh")
  H.assert_eq(args[2], "-lc")
  H.assert_match(args[3], "claude")
end)

test("正常系：session_id指定時は--resumeフラグ付きで起動する", function()
  local claude = load_agent("service/agents/claude")
  local opts = { command = "claude", shell = "/bin/zsh", status_dir = "/tmp" }

  local args = claude.spawn_args(opts, "session-abc")

  H.assert_match(args[3], "%-%-resume 'session%-abc'")
end)

test("正常系：cwd指定時はcdプレフィックス付きで起動する", function()
  local claude = load_agent("service/agents/claude")
  local opts = { command = "claude", shell = "/bin/zsh", status_dir = "/tmp" }

  local args = claude.spawn_args(opts, nil, "/home/user/project")

  H.assert_match(args[3], "cd '/home/user/project'")
end)

test("正常系：cwdにシングルクォートを含む場合はシェルエスケープされる", function()
  local claude = load_agent("service/agents/claude")
  local opts = { command = "claude", shell = "/bin/zsh", status_dir = "/tmp" }

  local args = claude.spawn_args(opts, nil, "/path/it's here")

  H.assert_true(args[3]:find("'\\''", 1, true) ~= nil)
end)

H.finish()
