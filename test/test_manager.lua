-- Manager: summon command assembly (build_command), summon focus, and per-workspace pane tracking.

package.path = package.path .. ";test/?.lua"
local H = require("helper")
local mgr = H.load_mod("ui/selector/manager")

H.section("manager: build_command")

-- 構造だけ検証する簡易クォータ (本物の shell_quote は agent 側でテスト済み)。
local q = function(s) return "{" .. s .. "}" end

-- claude: 専用フラグ＋位置引数 slash
H.test("claude: base + slash command when no system prompt", function()
  local cmd = mgr.build_command("claude", "claude --x", nil, q)
  H.assert_eq(cmd, 'claude --x "/wezterm-ai-agents:manager"', "prefix then slash")
end)

H.test("claude: empty system prompt is ignored", function()
  local cmd = mgr.build_command("claude", "claude", "", q)
  H.assert_false(cmd:find("append%-system%-prompt"), "no append flag for empty prompt")
  H.assert_match(cmd, "manager", "slash command still present")
end)

H.test("claude: system prompt injects quoted --append-system-prompt before the slash command", function()
  local cmd = mgr.build_command("claude", "claude", "be careful", q)
  H.assert_match(cmd, "%-%-append%-system%-prompt {be careful}", "quoted append flag")
  H.assert_match(cmd, '{be careful} "/wezterm%-ai%-agents:manager"$', "slash command stays last")
end)

-- codex: $manager をプロンプトに (明示必須)、sp は前置
H.test("codex: $manager as quoted prompt when no system prompt", function()
  local cmd = mgr.build_command("codex", "codex --yolo", nil, q)
  H.assert_eq(cmd, "codex --yolo {$manager}", "base then quoted $manager")
end)

H.test("codex: system prompt is folded before $manager in one quoted arg", function()
  local cmd = mgr.build_command("codex", "codex", "be careful", q)
  H.assert_match(cmd, "{be careful\n\n%$manager}$", "sp then blank line then $manager, quoted as one arg")
end)

-- gemini: -i で起動。sp 無しは /manager、sp 有りは平文トリガ
H.test("gemini: -i with /manager slash when no system prompt", function()
  local cmd = mgr.build_command("gemini", "gemini --yolo", nil, q)
  H.assert_eq(cmd, "gemini --yolo -i {/manager}", "base -i then quoted slash")
end)

H.test("gemini: system prompt switches to plain trigger (slash would not fire)", function()
  local cmd = mgr.build_command("gemini", "gemini", "be careful", q)
  H.assert_false(cmd:find("/manager"), "no slash command when sp present")
  H.assert_match(cmd, "{be careful\n\nmanager スキルに従って", "sp then plain trigger")
end)

H.test("unknown manager agent errors", function()
  local ok = pcall(mgr.build_command, "cursor", "cursor-agent", nil, q)
  H.assert_false(ok, "unknown agent raises")
end)

H.section("manager: summon")

H.test("既存のマネージャーが居れば前面化し再起動しない", function()
  local activated = false
  local orig = wezterm.mux.get_pane
  wezterm.mux.get_pane = function(id)
    if id == 5 then return { activate = function() activated = true end } end
  end
  -- mux_window を呼んだら spawn 経路に入った証拠 (existing 経路では到達しない)。
  local window = {
    active_workspace = function() return "a" end,
    mux_window = function() error("should not spawn when a manager already exists") end,
  }
  local deps = { opts = { manager_file = "m" }, manager = { read = function() return 5 end } }

  local ok = pcall(mgr.summon, window, {}, deps)
  wezterm.mux.get_pane = orig
  H.assert_true(ok, "例外なく前面化する")
  H.assert_true(activated, "既存ペインが activate された")
end)

H.section("manager state: per-workspace pane tracking")

local state = H.load_mod("state/manager")

H.test("manager pane id round-trips per workspace and clears", function()
  local file = H.tmp_dir() .. "/manager.json"
  H.assert_nil(state.read(file, "a"), "absent initially")
  state.write(file, "a", 12)
  H.assert_eq(state.read(file, "a"), 12, "stored")
  H.assert_true(state.is_manager(file, 12), "recognized as manager")
  H.assert_false(state.is_manager(file, 99), "other pane is not the manager")
  H.assert_nil(state.read(file, "b"), "other ws has no manager")
  state.write(file, "a", nil)
  H.assert_nil(state.read(file, "a"), "cleared")
end)

H.finish()
