-- Manager summon (CMD+SHIFT+M): bring up the current workspace's reception manager. If a manager
-- pane already runs for this workspace, focus it; otherwise spawn one and focus it (you are going
-- to talk to it). One manager per workspace; its tab is marked distinctly (ui.lua).
--
-- The manager runs an agent (claude/codex/gemini) under the shared `manager` skill. It triages
-- your request, delegates to agent tabs (spawn_agent + worktree tools), and may watch/unstick
-- panes (its own spawned tabs or existing ones) at its own discretion.

local wezterm = require("wezterm")
local act = wezterm.action

local M = {}

-- 各社の manager 決定的起動トークン。スラッシュ等はプラグインの内部詳細で利用者は意識しなくてよい。
--   claude: 位置引数の slash コマンド (シェルで1引数になるよう二重引用済み)
--   codex : skill 参照 $manager (openai.yaml の allow_implicit_invocation:false により明示必須)
--   gemini: slash コマンド (commands/manager.toml)
local MANAGER = {
  claude = '"/wezterm-ai-agents:manager"',
  codex = "$manager",
  gemini = "/manager",
}
-- gemini は system prompt と併用すると slash が先頭でなくなり効かないため、その時だけ平文トリガに切替える
-- (skill は extension から自動ロード済みなのでスキル名指定で起動できる)。
local GEMINI_PLAIN_TRIGGER =
  "manager スキルに従って WezTerm のワークスペース受付マネージャーとして動作せよ。まず list_panes で自分のワークスペースを把握し、相談を受けてタブへ委譲せよ。"

-- 起動シェルコマンドを組み立てる。base (エージェント本体＋フラグ) に、選んだエージェント流の
-- システムプロンプト付与と manager 起動トークンを足す。各社で渡し方が異なるため分岐する。
function M.build_command(agent_id, base, system_prompt, shell_quote)
  local sp = (system_prompt and system_prompt ~= "") and system_prompt or nil
  if agent_id == "claude" then
    -- 真の system prompt は専用フラグ。トリガは位置引数の slash。
    local cmd = base
    if sp then cmd = cmd .. " --append-system-prompt " .. shell_quote(sp) end
    return cmd .. " " .. MANAGER.claude
  elseif agent_id == "codex" then
    -- inline な system-prompt フラグが無いのでプロンプトに前置。skill は $manager でのみ読み込まれる。
    local prompt = sp and (sp .. "\n\n" .. MANAGER.codex) or MANAGER.codex
    return base .. " " .. shell_quote(prompt)
  elseif agent_id == "gemini" then
    -- -i で初期プロンプトを実行し対話継続。sp 併用時のみ平文トリガに切替 (上記の理由)。
    local prompt = sp and (sp .. "\n\n" .. GEMINI_PLAIN_TRIGGER) or MANAGER.gemini
    return base .. " -i " .. shell_quote(prompt)
  end
  error("unknown manager_agent: " .. tostring(agent_id))
end

-- ワークスペース ws 用の manager を新規起動し、その pane_id を記録してフォーカスする。
-- WEZTERM_AGENT_WORKSPACE を渡し、manager が自分のワークスペースを把握できるようにする。
-- claude が終了するとログインシェルも終わりペインが閉じる (skill 側の自己終了と合わせ自動クローズ)。
local function spawn_manager(window, pane, deps, ws)
  local opts = deps.opts
  local shell = os.getenv("SHELL") or "/bin/sh"
  local cwd = deps.workspace and deps.workspace.get_cwd_path(pane) or nil
  -- build_command は manager_agent が未知だと error する。spawn と一緒に pcall で隔離し、
  -- 失敗が action_callback の外へ伝播して無反応になるのを防ぐ (誤値は apply() で起動時に通知済み)。
  local ok, new_pane = pcall(function()
    local cmd = M.build_command(opts.manager_agent, opts.manager_command, opts.manager_system_prompt, deps.agent.shell_quote)
    local _, p = window:mux_window():spawn_tab({
      args = { shell, "-lc", cmd },
      cwd = cwd,
      set_environment_variables = { WEZTERM_AGENT_STATUS_DIR = opts.status_dir, WEZTERM_AGENT_WORKSPACE = ws },
    })
    return p
  end)
  -- 失敗は握り潰さず通知する (無反応だと「召喚しても何も起きない」になり原因が掴めないため)。
  if not ok or not new_pane then
    if deps.diagnostics then
      deps.diagnostics.report("manager_spawn_failed", "マネージャーの起動に失敗しました: " .. tostring(new_pane))
    end
    return
  end
  deps.manager.write(opts.manager_file, ws, new_pane:pane_id())
  -- 最左へ寄せて定位置にする。召喚なので新タブのフォーカスはそのまま (人間がここで相談する)。
  pcall(function() window:perform_action(act.MoveTab(0), pane) end)
end

-- pane_id が今も生きているか。mux の全ペインを列挙して権威的に判定し、生きていればその MuxPane を返す。
-- wezterm.mux.get_pane は閉じたペインに nil を返さないことがあり、それに依存すると「閉じた manager を
-- 生存と誤判定 → 再起動されない」不具合になるため、列挙で確実に確かめる。
local function alive_pane(pane_id)
  for _, win in ipairs(wezterm.mux.all_windows()) do
    for _, tab in ipairs(win:tabs()) do
      for _, p in ipairs(tab:panes()) do
        if p:pane_id() == pane_id then return p end
      end
    end
  end
  return nil
end

-- 現在のワークスペースの manager を呼び出す。居れば前面化、居なければ起動。
function M.summon(window, pane, deps)
  local opts = deps.opts
  local ws = window:active_workspace()
  local existing = deps.manager.read(opts.manager_file, ws)
  local p = existing and alive_pane(existing)
  if p then
    pcall(function() p:activate() end)
    return
  end
  spawn_manager(window, pane, deps, ws)
end

return M
