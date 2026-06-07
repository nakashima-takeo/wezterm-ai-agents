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

H.finish()
