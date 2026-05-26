-- Google Gemini CLI agent implementation.
-- State comes from the unified JSON state file:
--   <status_dir>/wezterm-agent-<pane_id>
--   {"agent":"gemini","state":"...","ts":...,"session_id":"..."}
-- Written by hooks/agent_status.sh, invoked from ~/.gemini/settings.json hooks.

local M = {}

M.id = "gemini"
M.display_name = "Gemini"
M.icons = { working = "\xEF\x83\xA7", waiting = "\xEF\x81\x99", done = "\xF3\xB0\x82\x9A", idle = "\xF3\xB0\x92\xB2" }
M.colors = {
  working = "#60a5fa",
  waiting = "#f38ba8",
  done = "#93c5fd",
  idle = "#fbbf24",
  error = "#f38ba8",
}

M.default_opts = {
  command = "gemini",
  shell = os.getenv("SHELL") or "/bin/sh",
}

return M
