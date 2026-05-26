-- Claude Code agent implementation.
-- State comes from the unified JSON state file:
--   <status_dir>/wezterm-agent-<pane_id>
--   {"agent":"claude","state":"...","ts":...,"session_id":"..."}
-- Written by hooks/agent_status.sh, invoked from ~/.claude/settings.json hooks.

local M = {}

M.id = "claude"
M.display_name = "Claude Code"
M.icons = { working = "\xEF\x83\xA7", waiting = "\xEF\x81\x99", done = "\xF3\xB0\x82\x9A", idle = "\xF3\xB0\x92\xB2" }
M.colors = {
  working = "#f5c778",
  waiting = "#f38ba8",
  done = "#f9e2af",
  idle = "#89b4fa",
  error = "#f38ba8",
}

M.default_opts = {
  command = "claude",
  shell = os.getenv("SHELL") or "/bin/sh",
}

return M
