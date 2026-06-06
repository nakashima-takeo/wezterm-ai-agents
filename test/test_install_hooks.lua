package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test = H.test

local script = H.plugin_dir .. "/hooks/install_hooks.sh"
local hooks_dir = H.plugin_dir .. "/hooks"

local function sh(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- install_hooks.sh を HOME 差し替えで実行し、stdout を返す。
local function run(home, dir, ids)
  local args = {}
  for _, id in ipairs(ids) do
    args[#args + 1] = sh(id)
  end
  local cmd = string.format("HOME=%s bash %s %s %s 2>&1", sh(home), sh(script), sh(dir), table.concat(args, " "))
  local p = io.popen(cmd)
  local out = p:read("*a")
  p:close()
  return out
end

local function cleanup(home) os.execute("rm -rf " .. sh(home)) end

H.section("hooks 自動インストール (install_hooks.sh)")

test("新規生成：claude の settings.json が正規 hooks を持つ", function()
  local home = H.tmp_dir()
  local out = run(home, hooks_dir, { "claude" })
  H.assert_match(out, "applied claude")
  local content = H.read_file(home .. "/.claude/settings.json")
  H.assert_not_nil(content, "ファイルが生成される")
  local data = wezterm.json_parse(content)
  H.assert_not_nil(data.hooks.SessionStart)
  H.assert_match(content, "agent_status.sh claude idle")
  H.assert_match(content, "agent_status.sh claude waiting") -- matcher 付き PreToolUse
  cleanup(home)
end)

test("冪等：2回実行で2回目は unchanged、.bak は作られない", function()
  local home = H.tmp_dir()
  run(home, hooks_dir, { "claude" })
  local first = H.read_file(home .. "/.claude/settings.json")
  local out2 = run(home, hooks_dir, { "claude" })
  H.assert_match(out2, "unchanged claude")
  H.assert_eq(H.read_file(home .. "/.claude/settings.json"), first, "内容が変わらない")
  H.assert_nil(H.read_file(home .. "/.claude/settings.json.bak"), "新規→無変更なので .bak なし")
  cleanup(home)
end)

test("既存保持：無関係キー・他フックを残し、.bak は作らない", function()
  local home = H.tmp_dir()
  os.execute("mkdir -p " .. sh(home .. "/.claude"))
  H.write_file(
    home .. "/.claude/settings.json",
    '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo other"}]}]}}'
  )
  local out = run(home, hooks_dir, { "claude" })
  H.assert_match(out, "applied claude")
  local content = H.read_file(home .. "/.claude/settings.json")
  local data = wezterm.json_parse(content)
  H.assert_eq(data.model, "opus", "無関係キーを保持")
  H.assert_match(content, "echo other", "既存の他フックを保持")
  H.assert_match(content, "agent_status.sh claude done", "自分のフックを追加")
  H.assert_nil(H.read_file(home .. "/.claude/settings.json.bak"), "変更しても .bak は作らない")
  cleanup(home)
end)

test("symlink はスキップし、リンク先を変更しない", function()
  local home = H.tmp_dir()
  os.execute("mkdir -p " .. sh(home .. "/.claude"))
  local real = home .. "/real.json"
  H.write_file(real, '{"keep":1}')
  os.execute(string.format("ln -s %s %s", sh(real), sh(home .. "/.claude/settings.json")))
  local out = run(home, hooks_dir, { "claude" })
  H.assert_match(out, "skip%-symlink claude")
  H.assert_true(not H.read_file(real):find("agent_status", 1, true), "リンク先は触らない")
  cleanup(home)
end)

test("不正 JSON はスキップし、内容を変更しない", function()
  local home = H.tmp_dir()
  os.execute("mkdir -p " .. sh(home .. "/.claude"))
  H.write_file(home .. "/.claude/settings.json", "{ this is : not json, }")
  local out = run(home, hooks_dir, { "claude" })
  H.assert_match(out, "skip%-invalid%-json claude")
  H.assert_true(not H.read_file(home .. "/.claude/settings.json"):find("agent_status", 1, true), "不正JSONは触らない")
  cleanup(home)
end)

test("空/空白のみの設定ファイルは {} 扱いで applied になる (unchanged に化けない)", function()
  local home = H.tmp_dir()
  os.execute("mkdir -p " .. sh(home .. "/.claude"))
  H.write_file(home .. "/.claude/settings.json", "  \n\t")
  local out = run(home, hooks_dir, { "claude" })
  H.assert_match(out, "applied claude")
  H.assert_match(H.read_file(home .. "/.claude/settings.json"), "agent_status.sh claude idle")
  cleanup(home)
end)

test("スペースを含む hooks_dir でも冪等 (.bak が増えない)", function()
  local home = H.tmp_dir()
  local dir = home .. "/h o o k s"
  os.execute("mkdir -p " .. sh(dir))
  run(home, dir, { "claude" })
  local out2 = run(home, dir, { "claude" })
  H.assert_match(out2, "unchanged claude")
  H.assert_nil(H.read_file(home .. "/.claude/settings.json.bak"), "2回目で .bak が増えない")
  H.assert_match(H.read_file(home .. "/.claude/settings.json"), "h o o k s/agent_status.sh", "スペース込みパスが入る")
  cleanup(home)
end)

test("jq 無しでは何も書かず jq-missing を exit 3 で返す", function()
  local home = H.tmp_dir()
  local cmd = string.format('PATH=/var/empty HOME=%s /bin/bash %s %s claude 2>&1; echo "__EXIT:$?"', sh(home), sh(script), sh(hooks_dir))
  local p = io.popen(cmd)
  local out = p:read("*a")
  p:close()
  H.assert_match(out, "jq%-missing")
  H.assert_match(out, "__EXIT:3")
  H.assert_nil(H.read_file(home .. "/.claude/settings.json"), "何も書かれない")
  cleanup(home)
end)

test("cursor は version:1 と camelCase イベントで生成される", function()
  local home = H.tmp_dir()
  local out = run(home, hooks_dir, { "cursor" })
  H.assert_match(out, "applied cursor")
  local content = H.read_file(home .. "/.cursor/hooks.json")
  local data = wezterm.json_parse(content)
  H.assert_eq(data.version, 1)
  H.assert_not_nil(data.hooks.sessionStart)
  H.assert_match(content, "agent_status.sh cursor unknown")
  cleanup(home)
end)

test("spec 外イベントに残った自分の古いエントリも除去される", function()
  local home = H.tmp_dir()
  os.execute("mkdir -p " .. sh(home .. "/.codex"))
  -- codex spec に無い SubagentStop に古い agent_status エントリが残っている状態
  H.write_file(
    home .. "/.codex/hooks.json",
    '{"hooks":{"SubagentStop":[{"hooks":[{"type":"command","command":"/old/hooks/agent_status.sh codex done"}]}]}}'
  )
  run(home, hooks_dir, { "codex" })
  local data = wezterm.json_parse(H.read_file(home .. "/.codex/hooks.json"))
  H.assert_nil(data.hooks.SubagentStop, "spec 外イベントの自分の残骸は除去され、空イベントは掃除される")
  H.assert_not_nil(data.hooks.SessionStart, "spec のイベントは追加される")
  cleanup(home)
end)

test("command 単位で除去し、同一グループに同居する他フックは残す", function()
  local home = H.tmp_dir()
  os.execute("mkdir -p " .. sh(home .. "/.codex"))
  -- 同一 matcher グループ内に他フックと古い自分のフックが同居
  H.write_file(
    home .. "/.codex/hooks.json",
    '{"hooks":{"Stop":[{"hooks":[{"command":"echo keep"},{"command":"/old/agent_status.sh codex done"}]}]}}'
  )
  run(home, hooks_dir, { "codex" })
  local content = H.read_file(home .. "/.codex/hooks.json")
  H.assert_match(content, "echo keep", "同居する他フックは残る")
  H.assert_true(not content:find("/old/agent_status", 1, true), "古い自分のフックだけ消える")
  H.assert_match(content, "agent_status.sh codex done", "正規版が追加される")
  cleanup(home)
end)

test("codex は PermissionRequest→waiting を含む", function()
  local home = H.tmp_dir()
  run(home, hooks_dir, { "codex" })
  local data = wezterm.json_parse(H.read_file(home .. "/.codex/hooks.json"))
  H.assert_not_nil(data.hooks.PermissionRequest)
  H.assert_match(H.read_file(home .. "/.codex/hooks.json"), "agent_status.sh codex waiting")
  cleanup(home)
end)

test("gemini は Notification→waiting を含む", function()
  local home = H.tmp_dir()
  run(home, hooks_dir, { "gemini" })
  local data = wezterm.json_parse(H.read_file(home .. "/.gemini/settings.json"))
  H.assert_not_nil(data.hooks.Notification)
  H.assert_match(H.read_file(home .. "/.gemini/settings.json"), "agent_status.sh gemini waiting")
  cleanup(home)
end)

-- install_hooks.sh の結果 (ran, stdout) を原因別に解釈する判定ロジック。
-- 推測 ("jq 未導入?") をやめ、sh が返した結果コードだけに基づいて文言を決める。
H.section("install_hooks 失敗判定 (init._install_hooks_diagnostic)")

local diag = H.load_mod("init")._install_hooks_diagnostic

test("成功 (applied/unchanged) は通知しない", function() H.assert_nil(diag(true, "applied codex\nunchanged gemini\n")) end)

test(
  "symlink/unknown のスキップは正常で通知しない",
  function() H.assert_nil(diag(true, "skip-symlink claude\nskip-unknown foo\n")) end
)

test("どのケースもユーザーが体感する機能名で言う (内部用語を出さない)", function()
  H.assert_match(diag(false, "jq-missing\n"), "状態表示")
  H.assert_true(not diag(false, "jq-missing\n"):find("フック", 1, true), "内部用語『フック』を出さない")
end)

test("jq-missing は jq 欠如だけを言う (推測しない)", function()
  local msg = diag(false, "jq-missing\n")
  H.assert_match(msg, "jq")
  H.assert_true(not msg:find("未導入?", 1, true), "煽る推測文言を含まない")
end)

test("skip-invalid-json は壊れた設定ファイルとして id 付きで知らせる", function()
  local msg = diag(true, "applied claude\nskip-invalid-json codex\n")
  H.assert_match(msg, "壊れて")
  H.assert_match(msg, "codex")
end)

test("複数の skip-invalid-json は全 id を列挙する", function()
  local msg = diag(true, "skip-invalid-json codex\nskip-invalid-json gemini\n")
  H.assert_match(msg, "codex")
  H.assert_match(msg, "gemini")
end)

test(
  "jq-missing は他の失敗より優先される",
  function() H.assert_match(diag(false, "skip-invalid-json codex\njq-missing\n"), "jq") end
)

test("結果無し (実行エラー) は原因を断定せず次の一手 (手動設定) を示す", function()
  local msg = diag(false, "")
  H.assert_match(msg, "README")
  H.assert_true(not msg:find("jq", 1, true), "jq のせいにしない")
end)

H.finish()
