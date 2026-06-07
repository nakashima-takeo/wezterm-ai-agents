-- Command center: orchestrator launch command assembly (build_command).

package.path = package.path .. ";test/?.lua"
local H = require("helper")
local cc = H.load_mod("ui/selector/command_center")

H.section("command center: build_command")

-- 構造だけ検証する簡易クォータ (本物の shell_quote は agent 側でテスト済み)。
local q = function(s) return "{" .. s .. "}" end

-- claude: 専用フラグ＋位置引数 slash
H.test("claude: base + slash command when no system prompt", function()
  local cmd = cc.build_command("claude", "claude --x", nil, q)
  H.assert_eq(cmd, 'claude --x "/wezterm-ai-agents:supervise"', "prefix then slash")
end)

H.test("claude: empty system prompt is ignored", function()
  local cmd = cc.build_command("claude", "claude", "", q)
  H.assert_false(cmd:find("append%-system%-prompt"), "no append flag for empty prompt")
  H.assert_match(cmd, "supervise", "slash command still present")
end)

H.test("claude: system prompt injects quoted --append-system-prompt before the slash command", function()
  local cmd = cc.build_command("claude", "claude", "be careful", q)
  H.assert_match(cmd, "%-%-append%-system%-prompt {be careful}", "quoted append flag")
  H.assert_match(cmd, '{be careful} "/wezterm%-ai%-agents:supervise"$', "slash command stays last")
end)

-- codex: $supervise をプロンプトに (明示必須)、sp は前置
H.test("codex: $supervise as quoted prompt when no system prompt", function()
  local cmd = cc.build_command("codex", "codex --yolo", nil, q)
  H.assert_eq(cmd, "codex --yolo {$supervise}", "base then quoted $supervise")
end)

H.test("codex: system prompt is folded before $supervise in one quoted arg", function()
  local cmd = cc.build_command("codex", "codex", "be careful", q)
  H.assert_match(cmd, "{be careful\n\n%$supervise}$", "sp then blank line then $supervise, quoted as one arg")
end)

-- gemini: -i で起動。sp 無しは /supervise、sp 有りは平文トリガ
H.test("gemini: -i with /supervise slash when no system prompt", function()
  local cmd = cc.build_command("gemini", "gemini --yolo", nil, q)
  H.assert_eq(cmd, "gemini --yolo -i {/supervise}", "base -i then quoted slash")
end)

H.test("gemini: system prompt switches to plain trigger (slash would not fire)", function()
  local cmd = cc.build_command("gemini", "gemini", "be careful", q)
  H.assert_false(cmd:find("/supervise"), "no slash command when sp present")
  H.assert_match(cmd, "{be careful\n\nsupervise スキルに従って", "sp then plain trigger")
end)

H.test("unknown orchestrator agent errors", function()
  local ok = pcall(cc.build_command, "cursor", "cursor-agent", nil, q)
  H.assert_false(ok, "unknown agent raises")
end)

H.section("command center: collect_rows 自己ペイン除外")

local function mock_pane(id, title)
  return {
    pane_id = function() return id end,
    get_title = function() return title or "" end,
  }
end

H.test("オーケストレーター自身のペインは一覧から除外される", function()
  local mock_win = {
    tabs = function()
      return { { panes = function() return { mock_pane(1, "a"), mock_pane(2, "orch"), mock_pane(3, "b") } end } }
    end,
  }
  local orig = wezterm.mux.all_windows
  wezterm.mux.all_windows = function() return { mock_win } end

  local deps = {
    opts = { managed_file = "m", orchestrator_file = "o" },
    managed = {
      read = function() return { [1] = true, [2] = true, [3] = true } end,
      read_orchestrator = function() return 2 end,
    },
    agent = { resolve = function() return nil, nil end },
  }

  local ok, rows = pcall(cc.collect_rows, deps)
  wezterm.mux.all_windows = orig
  H.assert_true(ok, "collect_rows が例外なく動く")

  local ids = {}
  for _, r in ipairs(rows) do
    ids[r.pane_id] = true
  end
  H.assert_true(ids[1], "通常ペインは含まれる")
  H.assert_true(ids[3], "通常ペインは含まれる")
  H.assert_false(ids[2], "オーケストレーター自身は除外される")
  H.assert_eq(#rows, 2, "除外後は2件")
end)

H.finish()
