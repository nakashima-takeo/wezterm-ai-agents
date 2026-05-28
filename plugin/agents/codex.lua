-- OpenAI Codex CLI agent implementation.
-- State comes from the unified JSON state file:
--   <status_dir>/wezterm-agent-<pane_id>
--   {"agent":"codex","state":"...","ts":...,"session_id":"..."}
-- Written by hooks/agent_status.sh, invoked from ~/.codex/hooks.json.

local M = {}

M.id = "codex"
M.display_name = "Codex"
M.colors = {
  working = "#10b981",
  waiting = "#f38ba8",
  done = "#6ee7b7",
  idle = "#a78bfa",
  error = "#ef4444",
}

function M.spawn_args(opts, session_id, cwd)
  local cmd = opts.command
  if session_id then cmd = cmd .. " resume" end
  if cwd then cmd = cmd .. " --cd " .. opts.shell_quote(cwd) end
  if session_id then cmd = cmd .. " " .. opts.shell_quote(session_id) end
  local shell = opts.shell
  return { shell, "-lc", string.format("%s; exec %s -l", cmd, shell) }
end

M.default_opts = {
  command = "codex",
  shell = os.getenv("SHELL") or "/bin/sh",
}

return M
