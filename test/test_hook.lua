package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test = H.test

local hook_path = H.plugin_dir .. "/hooks/agent_status.sh"

H.section("統一hookスクリプト (agent_status.sh)")

test("正常系：WEZTERM_PANEが設定されていればJSONステートファイルを書き込む", function()
  local tmp = H.tmp_dir()
  local cmd =
    string.format('echo \'{"session_id":"sess-001"}\' | WEZTERM_PANE=42 WEZTERM_AGENT_STATUS_DIR=%s bash %s claude working', tmp, hook_path)
  os.execute(cmd)

  local content = H.read_file(tmp .. "/wezterm-agent-42")
  H.assert_not_nil(content)
  local data = wezterm.json_parse(content)
  H.assert_eq(data.agent, "claude")
  H.assert_eq(data.state, "working")
  H.assert_eq(data.session_id, "sess-001")
  H.assert_not_nil(data.ts)

  os.execute("rm -rf " .. tmp)
end)

test("正常系：cursor agentの状態を書き込める", function()
  local tmp = H.tmp_dir()
  local cmd =
    string.format('echo \'{"session_id":"cur-abc"}\' | WEZTERM_PANE=99 WEZTERM_AGENT_STATUS_DIR=%s bash %s cursor done', tmp, hook_path)
  os.execute(cmd)

  local content = H.read_file(tmp .. "/wezterm-agent-99")
  H.assert_not_nil(content)
  local data = wezterm.json_parse(content)
  H.assert_eq(data.agent, "cursor")
  H.assert_eq(data.state, "done")
  H.assert_eq(data.session_id, "cur-abc")

  os.execute("rm -rf " .. tmp)
end)

test("正常系：clearアクションでステートファイルを削除する", function()
  local tmp = H.tmp_dir()
  H.write_file(tmp .. "/wezterm-agent-10", '{"agent":"claude","state":"working","ts":1,"session_id":"x"}')

  local cmd = string.format('echo "" | WEZTERM_PANE=10 WEZTERM_AGENT_STATUS_DIR=%s bash %s claude clear', tmp, hook_path)
  os.execute(cmd)

  H.assert_nil(H.read_file(tmp .. "/wezterm-agent-10"))

  os.execute("rm -rf " .. tmp)
end)

test("正常系：WEZTERM_PANEが未設定の場合は何もしない", function()
  local tmp = H.tmp_dir()
  local cmd =
    string.format('echo \'{"session_id":"x"}\' | WEZTERM_PANE= WEZTERM_AGENT_STATUS_DIR=%s bash %s claude working', tmp, hook_path)
  os.execute(cmd)

  H.assert_nil(H.read_file(tmp .. "/wezterm-agent-"))

  os.execute("rm -rf " .. tmp)
end)

test("正常系：session_idが含まれないJSONでも空文字で書き込む", function()
  local tmp = H.tmp_dir()
  local cmd = string.format("echo '{}' | WEZTERM_PANE=7 WEZTERM_AGENT_STATUS_DIR=%s bash %s claude idle", tmp, hook_path)
  os.execute(cmd)

  local content = H.read_file(tmp .. "/wezterm-agent-7")
  H.assert_not_nil(content)
  local data = wezterm.json_parse(content)
  H.assert_eq(data.agent, "claude")
  H.assert_eq(data.state, "idle")
  H.assert_eq(data.session_id, "")

  os.execute("rm -rf " .. tmp)
end)

test("正常系：アトミック書き込み（tmpファイル経由のmv）でファイルが壊れない", function()
  local tmp = H.tmp_dir()
  local cmd =
    string.format('echo \'{"session_id":"s1"}\' | WEZTERM_PANE=5 WEZTERM_AGENT_STATUS_DIR=%s bash %s claude working', tmp, hook_path)
  os.execute(cmd)

  -- .tmp ファイルが残っていないことを確認
  local f = io.open(tmp .. "/wezterm-agent-5.tmp", "r")
  H.assert_nil(f)

  os.execute("rm -rf " .. tmp)
end)

H.finish()
