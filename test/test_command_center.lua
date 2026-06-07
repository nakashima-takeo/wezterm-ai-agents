-- Command center: orchestrator launch command assembly (build_command).

package.path = package.path .. ";test/?.lua"
local H = require("helper")
local cc = H.load_mod("ui/selector/command_center")

H.section("command center: build_command")

-- 構造だけ検証する簡易クォータ (本物の shell_quote は agent 側でテスト済み)。
local q = function(s) return "{" .. s .. "}" end

H.test("base + slash command when no system prompt", function()
  local cmd = cc.build_command("claude --x", nil, q)
  H.assert_eq(cmd, 'claude --x "/wezterm-ai-agents:supervise"', "prefix then slash")
end)

H.test("empty system prompt is ignored", function()
  local cmd = cc.build_command("claude", "", q)
  H.assert_false(cmd:find("append%-system%-prompt"), "no append flag for empty prompt")
  H.assert_match(cmd, "supervise", "slash command still present")
end)

H.test("system prompt injects quoted --append-system-prompt before the slash command", function()
  local cmd = cc.build_command("claude", "be careful", q)
  H.assert_match(cmd, "%-%-append%-system%-prompt {be careful}", "quoted append flag")
  H.assert_match(cmd, '{be careful} "/wezterm%-ai%-agents:supervise"$', "slash command stays last")
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
