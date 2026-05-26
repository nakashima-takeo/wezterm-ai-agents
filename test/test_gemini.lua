package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test, load_agent = H.test, H.load_agent

H.section("Gemini 状態追跡")

test("正常系：JSONステートファイルが存在するペインをGeminiとして検出する", function()
  local gemini = load_agent("agents/gemini")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.assert_false(gemini.detect(pane, opts))

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"gemini","state":"idle","ts":1716000000,"session_id":"a1b2c3d4"}')
  H.assert_true(gemini.detect(pane, opts))

  os.execute("rm -rf " .. tmp)
end)

test("正常系：別agentのステートファイルではGeminiとして検出しない", function()
  local gemini = load_agent("agents/gemini")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"claude","state":"working","ts":1716000000,"session_id":""}')
  H.assert_false(gemini.detect(pane, opts))

  os.execute("rm -rf " .. tmp)
end)

test("正常系：JSONステートファイルからエージェントの状態を読み取れる", function()
  local gemini = load_agent("agents/gemini")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.assert_eq(gemini.state(pane, opts), "idle")

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"gemini","state":"working","ts":1716000000,"session_id":""}')
  H.assert_eq(gemini.state(pane, opts), "working")

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"gemini","state":"done","ts":1716000000,"session_id":""}')
  H.assert_eq(gemini.state(pane, opts), "done")

  os.execute("rm -rf " .. tmp)
end)

test("正常系：JSONステートファイルからセッションIDを取得できる", function()
  local gemini = load_agent("agents/gemini")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.assert_nil(gemini.session_id(pane, opts))

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"gemini","state":"idle","ts":1716000000,"session_id":"a1b2c3d4-e5f6-7890"}')
  H.assert_eq(gemini.session_id(pane, opts), "a1b2c3d4-e5f6-7890")

  os.execute("rm -rf " .. tmp)
end)

test("異常系：空ファイルや不正JSONの場合はidleまたはnilを返す", function()
  local gemini = load_agent("agents/gemini")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.write_file(tmp .. "/wezterm-agent-p1", "")
  H.assert_eq(gemini.state(pane, opts), "idle")

  H.write_file(tmp .. "/wezterm-agent-p1", "broken")
  H.assert_false(gemini.detect(pane, opts))

  os.execute("rm -rf " .. tmp)
end)

H.section("Gemini done→idle自動遷移")

test("正常系：done状態のペインを閲覧するとidleに遷移する", function()
  local gemini = load_agent("agents/gemini")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }
  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"gemini","state":"done","ts":1716000000,"session_id":"s1"}')

  local consumed = gemini.consume_done(pane, opts)

  H.assert_true(consumed)
  local content = H.read_file(tmp .. "/wezterm-agent-p1")
  H.assert_match(content, '"state":"idle"')
  H.assert_match(content, '"agent":"gemini"')

  os.execute("rm -rf " .. tmp)
end)

test("正常系：別agentのdone状態ではconsume_doneは何もしない", function()
  local gemini = load_agent("agents/gemini")
  local tmp = H.tmp_dir()
  local pane = H.mock_pane("p1")
  local opts = { status_dir = tmp }

  H.write_file(tmp .. "/wezterm-agent-p1", '{"agent":"codex","state":"done","ts":1716000000,"session_id":""}')
  H.assert_false(gemini.consume_done(pane, opts))

  os.execute("rm -rf " .. tmp)
end)

H.section("Gemini セッション起動コマンド生成")

test("正常系：シェル経由でGeminiを起動するコマンドを生成する", function()
  local gemini = load_agent("agents/gemini")
  local opts = { command = "gemini", shell = "/bin/zsh", status_dir = "/tmp" }

  local args = gemini.spawn_args(opts)

  H.assert_eq(#args, 3)
  H.assert_eq(args[1], "/bin/zsh")
  H.assert_eq(args[2], "-lc")
  H.assert_match(args[3], "gemini")
end)

test("正常系：session_id指定時は--resumeフラグ付きで起動する", function()
  local gemini = load_agent("agents/gemini")
  local opts = { command = "gemini", shell = "/bin/zsh", status_dir = "/tmp" }

  local args = gemini.spawn_args(opts, "a1b2c3d4")

  H.assert_match(args[3], "%-%-resume 'a1b2c3d4'")
end)

test("正常系：cwd指定時はcdプレフィックス付きで起動する", function()
  local gemini = load_agent("agents/gemini")
  local opts = { command = "gemini", shell = "/bin/zsh", status_dir = "/tmp" }

  local args = gemini.spawn_args(opts, nil, "/home/user/project")

  H.assert_match(args[3], "cd '/home/user/project'")
end)

H.finish()
