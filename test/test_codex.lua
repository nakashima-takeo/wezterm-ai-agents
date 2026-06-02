package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test, load_agent, load_mod = H.test, H.load_agent, H.load_mod

H.section("Codex 状態追跡")

test("正常系：JSONステートファイルが存在するペインをCodexとして検出する", function()
  local codex = load_agent("service/agents/codex")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.assert_false(codex.detect(pane, opts))

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"codex","state":"idle","ts":1716000000,"session_id":"019d2fac-0b38"}')
  H.assert_true(codex.detect(pane, opts))

  os.execute("rm -rf " .. tmp)
end)

test("正常系：別agentのステートファイルではCodexとして検出しない", function()
  local codex = load_agent("service/agents/codex")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"claude","state":"working","ts":1716000000,"session_id":""}')
  H.assert_false(codex.detect(pane, opts))

  os.execute("rm -rf " .. tmp)
end)

test("正常系：JSONステートファイルからエージェントの状態を読み取れる", function()
  local codex = load_agent("service/agents/codex")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.assert_eq(codex.state(pane, opts), "idle")

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"codex","state":"working","ts":1716000000,"session_id":""}')
  H.assert_eq(codex.state(pane, opts), "working")

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"codex","state":"done","ts":1716000000,"session_id":""}')
  H.assert_eq(codex.state(pane, opts), "done")

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"codex","state":"waiting","ts":1716000000,"session_id":""}')
  H.assert_eq(codex.state(pane, opts), "waiting")

  os.execute("rm -rf " .. tmp)
end)

test("正常系：JSONステートファイルからセッションIDを取得できる", function()
  local codex = load_agent("service/agents/codex")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.assert_nil(codex.session_id(pane, opts))

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"codex","state":"idle","ts":1716000000,"session_id":"019d2fac-0b38-70f0"}')
  H.assert_eq(codex.session_id(pane, opts), "019d2fac-0b38-70f0")

  os.execute("rm -rf " .. tmp)
end)

test("異常系：空ファイルや不正JSONの場合はidleまたはnilを返す", function()
  local codex = load_agent("service/agents/codex")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.write_file(tmp .. "/wezterm-agent-p1", "")
  H.assert_eq(codex.state(pane, opts), "idle")
  H.assert_nil(codex.session_id(pane, opts))

  H.write_file(tmp .. "/wezterm-agent-p1", "broken")
  H.assert_false(codex.detect(pane, opts))

  os.execute("rm -rf " .. tmp)
end)

H.section("Codex done→idle自動遷移")

test("正常系：done状態のペインを閲覧するとidleに遷移する", function()
  local codex = load_agent("service/agents/codex")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }
  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"codex","state":"done","ts":1716000000,"session_id":"s1"}')

  local consumed = codex.consume_done(pane, opts)

  H.assert_true(consumed)
  local content = H.read_file(tmp .. "/wezterm-agent-p1")
  H.assert_match(content, '"state":"idle"')
  H.assert_match(content, '"agent":"codex"')

  os.execute("rm -rf " .. tmp)
end)

test("正常系：別agentのdone状態ではconsume_doneは何もしない", function()
  local codex = load_agent("service/agents/codex")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"claude","state":"done","ts":1716000000,"session_id":""}')
  H.assert_false(codex.consume_done(pane, opts))

  os.execute("rm -rf " .. tmp)
end)

H.section("Codex セッション起動コマンド生成")

test("正常系：シェル経由でCodexを起動するコマンドを生成する", function()
  local agent = load_mod("service/agent")
  local codex = load_agent("service/agents/codex")
  local opts = agent.opts_for(codex, { status_dir = "/tmp", agents = { codex = { shell = "/bin/zsh" } } })

  local args = codex.spawn_args(opts)

  H.assert_eq(#args, 3)
  H.assert_eq(args[1], "/bin/zsh")
  H.assert_eq(args[2], "-lc")
  H.assert_match(args[3], "codex")
end)

test("正常系：session_id指定時はresumeサブコマンドで起動する", function()
  local agent = load_mod("service/agent")
  local codex = load_agent("service/agents/codex")
  local opts = agent.opts_for(codex, { status_dir = "/tmp", agents = { codex = { shell = "/bin/zsh" } } })

  local args = codex.spawn_args(opts, "019d2fac-0b38")

  H.assert_match(args[3], "codex resume '019d2fac%-0b38'")
end)

test("正常系：cwd指定時は--cdフラグで起動する", function()
  local agent = load_mod("service/agent")
  local codex = load_agent("service/agents/codex")
  local opts = agent.opts_for(codex, { status_dir = "/tmp", agents = { codex = { shell = "/bin/zsh" } } })

  local args = codex.spawn_args(opts, nil, "/home/user/project")

  H.assert_match(args[3], "%-%-cd '/home/user/project'")
end)

test("正常系：cwd+session_id両方指定時はresumeサブコマンドに--cdを渡す", function()
  local agent = load_mod("service/agent")
  local codex = load_agent("service/agents/codex")
  local opts = agent.opts_for(codex, { status_dir = "/tmp", agents = { codex = { shell = "/bin/zsh" } } })

  local args = codex.spawn_args(opts, "sess-1", "/home/user/project")

  H.assert_match(args[3], "resume")
  H.assert_match(args[3], "%-%-cd '/home/user/project'")
  H.assert_match(args[3], "'sess%-1'")
end)

H.finish()
