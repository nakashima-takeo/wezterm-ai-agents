-- Cursor Agent CLI implementation.
-- State comes from the unified JSON state file:
--   <status_dir>/<gui_pid>/wezterm-agent-<pane_id>
--   {"agent":"cursor","state":"...","ts":...,"session_id":"..."}
-- Written by agent_status.sh。cursor はプラグイン CLI を持たない二級市民: 自動導入の対象外
-- (状態追跡は手動で .cursor/hooks.json に agent_status.sh を設定するか、非対応)。

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

-- cursor-agent の再開は `--resume=<chatId>` (= 区切り。公式が --resume=-1 を正規表記とする)。
M.resume_flag = "--resume=%s"

M.default_opts = {
  command = "cursor-agent",
  shell = os.getenv("SHELL") or "/bin/sh",
}

return M
