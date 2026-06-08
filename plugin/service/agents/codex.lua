-- OpenAI Codex CLI agent implementation.
-- State comes from the unified JSON state file:
--   <status_dir>/<gui_pid>/wezterm-agent-<pane_id>
--   {"agent":"codex","state":"...","ts":...,"session_id":"..."}
-- Written by agent-plugin/hooks/agent_status.sh, invoked from agent-plugin の同梱フック (codex-hooks.json)。

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

-- Codex は再開がフラグでなくサブコマンド (`codex resume <id>`) で、作業ルートも codex 固有の
-- `--cd` で渡すため、既定の resume_flag 方式に乗らず spawn_args を直接実装する。
-- (--cd は spawn 側 cwd と重複しうるが、codex の working root 明示として残す。shell ラッパは共有。)
function M.spawn_args(opts, session_id, cwd)
  local cmd = opts.command
  if session_id then cmd = cmd .. " resume" end
  if cwd then cmd = cmd .. " --cd " .. opts.shell_quote(cwd) end
  if session_id then cmd = cmd .. " " .. opts.shell_quote(session_id) end
  return opts.wrap_shell(opts.shell, cmd)
end

M.default_opts = {
  command = "codex",
  shell = os.getenv("SHELL") or "/bin/sh",
}

return M
