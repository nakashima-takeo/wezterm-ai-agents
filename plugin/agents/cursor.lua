-- Cursor Agent CLI implementation.
-- State comes from the unified JSON state file:
--   <status_dir>/wezterm-agent-<pane_id>
--   {"agent":"cursor","state":"...","ts":...,"session_id":"..."}
-- Written by hooks/agent_status.sh, invoked from .cursor/hooks.json.

local M = {}

M.id = "cursor"
M.display_name = "Cursor Agent"
M.default_state = "unknown"
M.colors = {
  unknown = "#6c7086",
  waiting = "#f38ba8",
  done = "#86efac",
  idle = "#67e8f9",
  error = "#ef4444",
}

M.default_opts = {
  command = "cursor-agent",
  shell = os.getenv("SHELL") or "/bin/sh",
}

return M
