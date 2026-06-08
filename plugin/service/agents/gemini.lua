-- Google Gemini CLI agent implementation.
-- State comes from the unified JSON state file:
--   <status_dir>/<gui_pid>/wezterm-agent-<pane_id>
--   {"agent":"gemini","state":"...","ts":...,"session_id":"..."}
-- Written by agent-plugin/hooks/agent_status.sh, invoked from agent-plugin の同梱フック (hooks.json)。

local M = {}

M.id = "gemini"
M.display_name = "Gemini"
M.colors = {
  working = "#60a5fa",
  waiting = "#f38ba8",
  done = "#93c5fd",
  idle = "#fbbf24",
  error = "#ef4444",
}

-- Gemini CLI は `gemini --resume <UUID>` で特定セッションを再開する (v0.20.0 以降)。
M.resume_flag = "--resume %s"

M.default_opts = {
  command = "gemini",
  shell = os.getenv("SHELL") or "/bin/sh",
}

return M
