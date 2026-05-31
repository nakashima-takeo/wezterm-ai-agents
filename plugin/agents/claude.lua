-- Claude Code agent implementation.
-- State comes from the unified JSON state file:
--   <status_dir>/<gui_pid>/wezterm-agent-<pane_id>
--   {"agent":"claude","state":"...","ts":...,"session_id":"..."}
-- Written by hooks/agent_status.sh, invoked from ~/.claude/settings.json hooks.

local M = {}

M.id = "claude"
M.display_name = "Claude Code"
M.colors = {
  working = "#f5c778",
  waiting = "#f38ba8",
  done = "#f9e2af",
  idle = "#89b4fa",
  error = "#ef4444",
}

M.default_opts = {
  command = "claude",
  shell = os.getenv("SHELL") or "/bin/sh",
}

return M
