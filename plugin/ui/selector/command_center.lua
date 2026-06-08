-- Command center (司令塔) overlay: lists the current workspace's agent panes and lets the human
-- toggle which ones are supervised by that workspace's orchestrator. Supervised (✓) and
-- unsupervised (○) are shown in separate sections; selecting a pane flips its membership and
-- re-opens the console so multiple panes can be toggled in place. Supervision is per-workspace:
-- each workspace keeps its own managed set and its own orchestrator. The always-on tab/right-status
-- carry the ambient cue and stay unchanged.
--
-- Data join: managed set (state/managed) X live state (service/agent.resolve) X mux panes.
-- Only panes in the current workspace and still alive in the mux are shown, so closed panes
-- and other workspaces self-hide.

local wezterm = require("wezterm")
local act = wezterm.action

local M = {}

local ui

-- selector/init.lua injects the shared UI helpers (selector/ui.lua).
function M.setup(ui_mod) ui = ui_mod end

-- Every alive pane in workspace `ws` that is either a detected agent or already in its managed set.
-- The workspace's orchestrator pane is always excluded (self-supervision guard).
function M.collect_rows(deps, ws)
  local opts = deps.opts
  local set = deps.managed.read(opts.managed_file, ws)
  local orchestrator = deps.managed.read_orchestrator(opts.orchestrator_file, ws)
  local rows = {}
  for _, win in ipairs(wezterm.mux.all_windows()) do
    if win:get_workspace() == ws then
      for _, tab in ipairs(win:tabs()) do
        for _, p in ipairs(tab:panes()) do
          local pid = p:pane_id()
          local impl, st = deps.agent.resolve(pid, opts)
          local is_managed = set[pid] == true
          -- オーケストレーター自身のペインは一覧から除外する (自己監督の防止)。
          if pid ~= orchestrator and (impl or is_managed) then
            st = st or "idle"
            rows[#rows + 1] = {
              pane_id = pid,
              managed = is_managed,
              name = (impl and (impl.display_name or impl.id)) or "?",
              icon = (impl and impl.icons and impl.icons[st]) or "",
              color = (impl and impl.colors and impl.colors[st]) or nil,
              title = p:get_title() or "",
            }
          end
        end
      end
    end
  end
  return rows
end

local function row_choice(r)
  local fmt = {
    { Foreground = { AnsiColor = r.managed and "Green" or "Grey" } },
    { Text = r.managed and "\xE2\x9C\x93 " or "\xE2\x97\x8B " }, -- ✓ / ○
    "ResetAttributes",
  }
  if r.color then table.insert(fmt, { Foreground = { Color = r.color } }) end
  if r.icon ~= "" then table.insert(fmt, { Text = r.icon .. " " }) end
  if r.color then table.insert(fmt, "ResetAttributes") end
  table.insert(fmt, { Text = r.name .. "  " .. r.title })
  return { id = "pane:" .. r.pane_id, label = wezterm.format(fmt) }
end

-- 各社の supervise 決定的起動トークン。スラッシュ等はプラグインの内部詳細で利用者は意識しなくてよい。
--   claude: 位置引数の slash コマンド (シェルで1引数になるよう二重引用済み)
--   codex : skill 参照 $supervise (openai.yaml の allow_implicit_invocation:false により明示必須)
--   gemini: slash コマンド (commands/supervise.toml)
local SUPERVISE = {
  claude = '"/wezterm-ai-agents:supervise"',
  codex = "$supervise",
  gemini = "/supervise",
}
-- gemini は system prompt と併用すると slash が先頭でなくなり効かないため、その時だけ平文トリガに切替える
-- (skill は extension から自動ロード済みなのでスキル名指定で起動できる)。
local GEMINI_PLAIN_TRIGGER =
  "supervise スキルに従って WezTerm 監督オーケストレーターとして動作せよ。まず get_agents で監督対象を把握し監視ループを開始せよ。"

-- 起動シェルコマンドを組み立てる。base (エージェント本体＋フラグ) に、選んだエージェント流の
-- システムプロンプト付与と supervise 起動トークンを足す。各社で渡し方が異なるため分岐する。
function M.build_command(agent_id, base, system_prompt, shell_quote)
  local sp = (system_prompt and system_prompt ~= "") and system_prompt or nil
  if agent_id == "claude" then
    -- 真の system prompt は専用フラグ。トリガは位置引数の slash。
    local cmd = base
    if sp then cmd = cmd .. " --append-system-prompt " .. shell_quote(sp) end
    return cmd .. " " .. SUPERVISE.claude
  elseif agent_id == "codex" then
    -- inline な system-prompt フラグが無いのでプロンプトに前置。skill は $supervise でのみ読み込まれる。
    local prompt = sp and (sp .. "\n\n" .. SUPERVISE.codex) or SUPERVISE.codex
    return base .. " " .. shell_quote(prompt)
  elseif agent_id == "gemini" then
    -- -i で初期プロンプトを実行し対話継続。sp 併用時のみ平文トリガに切替 (上記の理由)。
    local prompt = sp and (sp .. "\n\n" .. GEMINI_PLAIN_TRIGGER) or SUPERVISE.gemini
    return base .. " -i " .. shell_quote(prompt)
  end
  error("unknown orchestrator_agent: " .. tostring(agent_id))
end

-- 記録済みオーケストレーター (ワークスペース ws 用) のペインが今も生きているか。
local function orchestrator_alive(deps, ws)
  local oid = deps.managed.read_orchestrator(deps.opts.orchestrator_file, ws)
  return oid ~= nil and wezterm.mux.get_pane(oid) ~= nil
end

-- ワークスペース ws 用の supervise オーケストレーターを最左タブで起動し、その pane_id を記録する。
-- claude が終了するとログインシェルも終わりペインが閉じる (skill 側の自己終了と合わせ自動クローズ)。
-- WEZTERM_AGENT_WORKSPACE を渡し、MCP (get_agents/wait_for_event) がこのワークスペースの監督集合だけを読む。
-- フォーカスは利用者の元タブへ戻し、司令塔から押しても画面を奪わない (タブ色で定位置を見分けられる)。
local function launch_orchestrator(window, pane, deps, ws)
  local opts = deps.opts
  local shell = os.getenv("SHELL") or "/bin/sh"
  local cwd = deps.workspace and deps.workspace.get_cwd_path(pane) or nil
  local orig_tab = window:active_tab()
  -- build_command は orchestrator_agent が未知だと error する。spawn と一緒に pcall で隔離し、
  -- 失敗が action_callback の外へ伝播して無反応になるのを防ぐ (誤値は apply() で起動時に通知済み)。
  local ok, new_pane = pcall(function()
    local cmd = M.build_command(opts.orchestrator_agent, opts.orchestrator_command, opts.orchestrator_system_prompt, deps.agent.shell_quote)
    local _, p = window:mux_window():spawn_tab({
      args = { shell, "-lc", cmd },
      cwd = cwd,
      set_environment_variables = { WEZTERM_AGENT_STATUS_DIR = opts.status_dir, WEZTERM_AGENT_WORKSPACE = ws },
    })
    return p
  end)
  if not ok or not new_pane then return end
  deps.managed.write_orchestrator(opts.orchestrator_file, ws, new_pane:pane_id())
  -- 最左へ寄せて定位置にしつつ、フォーカスは元タブへ戻す (spawn_tab は新タブを前面化するため明示的に戻す)。
  pcall(function()
    window:perform_action(act.MoveTab(0), pane)
    if orig_tab then orig_tab:activate() end
  end)
end

function M.open(window, pane, deps)
  local L = deps.opts.labels
  local ws = window:active_workspace()
  local rows = M.collect_rows(deps, ws)
  if #rows == 0 then
    ui.toast(window, L.cc_empty)
    return
  end

  local supervised, unsupervised = {}, {}
  for _, r in ipairs(rows) do
    table.insert(r.managed and supervised or unsupervised, r)
  end

  local choices = {}
  local function add_section(title, list)
    if #list == 0 then return end
    table.insert(choices, { id = "_sep_" .. title, label = "── " .. title .. " ──" })
    for _, r in ipairs(list) do
      table.insert(choices, row_choice(r))
    end
  end
  add_section(L.cc_supervised, supervised)
  add_section(L.cc_unsupervised, unsupervised)

  window:perform_action(
    act.InputSelector({
      title = L.cc_title,
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(iw, ip, id)
        if not id or id:match("^_sep_") then return end
        local pid = tonumber(id:match("^pane:(%d+)$"))
        if not pid then return end
        deps.managed.toggle(deps.opts.managed_file, ws, pid)
        -- 監督対象が非空になり、まだオーケストレーターが居なければ起動する (手動クローズ後も次トグルで復活)。
        -- 背景起動でフォーカスは奪わないので、そのまま司令塔を再オープンして続けて管理できる。
        local nonempty = next(deps.managed.read(deps.opts.managed_file, ws)) ~= nil
        if nonempty and deps.opts.auto_orchestrator and not orchestrator_alive(deps, ws) then launch_orchestrator(iw, ip, deps, ws) end
        M.open(iw, ip, deps)
      end),
    }),
    pane
  )
end

return M
