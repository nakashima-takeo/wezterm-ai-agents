package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test = H.test

local hook_path = H.plugin_dir .. "/hooks/agent_status.sh"

-- フックは WEZTERM_UNIX_SOCKET(=…/gui-sock-<pid>) 末尾の PID で名前空間化する。
-- テストは固定 socket を渡して決定的にし、その名前空間配下を検証する。
local SOCK = "/run/wezterm/gui-sock-12345"
local NS = "12345"
local function ns(dir) return dir .. "/" .. NS end

H.section("統一hookスクリプト (agent_status.sh)")

test("正常系：WEZTERM_PANEが設定されていればJSONステートファイルを書き込む", function()
  local tmp = H.tmp_dir()
  local cmd = string.format(
    'echo \'{"session_id":"sess-001"}\' | WEZTERM_PANE=42 WEZTERM_UNIX_SOCKET=%s WEZTERM_AGENT_STATUS_DIR=%s bash %s claude working',
    SOCK,
    tmp,
    hook_path
  )
  os.execute(cmd)

  local content = H.read_file(ns(tmp) .. "/wezterm-agent-42")
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
  local cmd = string.format(
    'echo \'{"session_id":"cur-abc"}\' | WEZTERM_PANE=99 WEZTERM_UNIX_SOCKET=%s WEZTERM_AGENT_STATUS_DIR=%s bash %s cursor done',
    SOCK,
    tmp,
    hook_path
  )
  os.execute(cmd)

  local content = H.read_file(ns(tmp) .. "/wezterm-agent-99")
  H.assert_not_nil(content)
  local data = wezterm.json_parse(content)
  H.assert_eq(data.agent, "cursor")
  H.assert_eq(data.state, "done")
  H.assert_eq(data.session_id, "cur-abc")

  os.execute("rm -rf " .. tmp)
end)

test("正常系：clearアクションでステートファイルを削除する", function()
  local tmp = H.tmp_dir()
  os.execute('mkdir -p "' .. ns(tmp) .. '"')
  H.write_file(ns(tmp) .. "/wezterm-agent-10", '{"agent":"claude","state":"working","ts":1,"session_id":"x"}')

  local cmd =
    string.format('echo "" | WEZTERM_PANE=10 WEZTERM_UNIX_SOCKET=%s WEZTERM_AGENT_STATUS_DIR=%s bash %s claude clear', SOCK, tmp, hook_path)
  os.execute(cmd)

  H.assert_nil(H.read_file(ns(tmp) .. "/wezterm-agent-10"))

  os.execute("rm -rf " .. tmp)
end)

test("正常系：WEZTERM_PANEが未設定の場合は何もしない", function()
  local tmp = H.tmp_dir()
  local cmd = string.format(
    'echo \'{"session_id":"x"}\' | WEZTERM_PANE= WEZTERM_UNIX_SOCKET=%s WEZTERM_AGENT_STATUS_DIR=%s bash %s claude working',
    SOCK,
    tmp,
    hook_path
  )
  os.execute(cmd)

  H.assert_nil(H.read_file(ns(tmp) .. "/wezterm-agent-"))

  os.execute("rm -rf " .. tmp)
end)

test("正常系：session_idが含まれないJSONでも空文字で書き込む", function()
  local tmp = H.tmp_dir()
  local cmd =
    string.format("echo '{}' | WEZTERM_PANE=7 WEZTERM_UNIX_SOCKET=%s WEZTERM_AGENT_STATUS_DIR=%s bash %s claude idle", SOCK, tmp, hook_path)
  os.execute(cmd)

  local content = H.read_file(ns(tmp) .. "/wezterm-agent-7")
  H.assert_not_nil(content)
  local data = wezterm.json_parse(content)
  H.assert_eq(data.agent, "claude")
  H.assert_eq(data.state, "idle")
  H.assert_eq(data.session_id, "")

  os.execute("rm -rf " .. tmp)
end)

test("正常系：アトミック書き込み（tmpファイル経由のmv）でファイルが壊れない", function()
  local tmp = H.tmp_dir()
  local cmd = string.format(
    'echo \'{"session_id":"s1"}\' | WEZTERM_PANE=5 WEZTERM_UNIX_SOCKET=%s WEZTERM_AGENT_STATUS_DIR=%s bash %s claude working',
    SOCK,
    tmp,
    hook_path
  )
  os.execute(cmd)

  -- .tmp ファイルが残っていないことを確認
  local f = io.open(ns(tmp) .. "/wezterm-agent-5.tmp", "r")
  H.assert_nil(f)

  os.execute("rm -rf " .. tmp)
end)

test("正常系：WEZTERM_UNIX_SOCKETが非数値/未設定なら base 直下に退避する", function()
  local tmp = H.tmp_dir()
  -- 親シェルの WEZTERM_UNIX_SOCKET を空で上書きして名前空間導出不可にする。
  local cmd =
    string.format("echo '{}' | WEZTERM_PANE=8 WEZTERM_UNIX_SOCKET= WEZTERM_AGENT_STATUS_DIR=%s bash %s claude working", tmp, hook_path)
  os.execute(cmd)

  H.assert_not_nil(H.read_file(tmp .. "/wezterm-agent-8"), "PID を導出できない場合は base 直下に書く")

  os.execute("rm -rf " .. tmp)
end)

H.finish()
