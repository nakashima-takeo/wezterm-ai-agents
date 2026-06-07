-- Command center (司令塔) overlay: lists every agent pane and lets the human toggle which ones are
-- supervised by the orchestrator. Supervised (✓) and unsupervised (○) are shown in separate
-- sections; selecting a pane flips its membership and re-opens the console so multiple panes
-- can be toggled in place. The always-on tab/right-status carry the ambient cue and stay unchanged.
--
-- Data join: managed set (state/managed) X live state (service/agent.resolve) X mux panes.
-- Only panes still alive in the mux are shown, so closed panes self-hide.

local wezterm = require("wezterm")
local act = wezterm.action

local M = {}

local ui

-- selector/init.lua injects the shared UI helpers (selector/ui.lua).
function M.setup(ui_mod) ui = ui_mod end

-- Every alive pane that is either a detected agent or already in the managed set.
local function collect_rows(deps)
  local opts = deps.opts
  local set = deps.managed.read(opts.managed_file)
  local orchestrator = deps.managed.read_orchestrator(opts.orchestrator_file)
  local rows = {}
  for _, win in ipairs(wezterm.mux.all_windows()) do
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

-- supervise スキルの起動指定。スラッシュコマンドはプラグインの内部詳細で、利用者は意識しなくてよい。
local SUPERVISE_SLASH = '"/wezterm-ai-agents:supervise"'

-- 起動シェルコマンドを組み立てる。base (claude＋フラグ) に、任意のシステムプロンプトを
-- --append-system-prompt として (shell_quote で安全に) 足し、最後に supervise スキルを起動する。
function M.build_command(base, system_prompt, shell_quote)
  local cmd = base
  if system_prompt and system_prompt ~= "" then cmd = cmd .. " --append-system-prompt " .. shell_quote(system_prompt) end
  return cmd .. " " .. SUPERVISE_SLASH
end

-- 記録済みオーケストレーターのペインが今も生きているか。
local function orchestrator_alive(deps)
  local oid = deps.managed.read_orchestrator(deps.opts.orchestrator_file)
  return oid ~= nil and wezterm.mux.get_pane(oid) ~= nil
end

-- supervise オーケストレーターを最左タブで起動し、その pane_id を記録する。
-- claude が終了するとログインシェルも終わりペインが閉じる (skill 側の自己終了と合わせ自動クローズ)。
local function launch_orchestrator(window, pane, deps)
  local opts = deps.opts
  local shell = os.getenv("SHELL") or "/bin/sh"
  local cwd = deps.workspace and deps.workspace.get_cwd_path(pane) or nil
  local cmd = M.build_command(opts.orchestrator_command, opts.orchestrator_system_prompt, deps.agent.shell_quote)
  local ok, new_pane = pcall(function()
    local _, p = window:mux_window():spawn_tab({
      args = { shell, "-lc", cmd },
      cwd = cwd,
      set_environment_variables = { WEZTERM_AGENT_STATUS_DIR = opts.status_dir },
    })
    return p
  end)
  if not ok or not new_pane then return end
  deps.managed.write_orchestrator(opts.orchestrator_file, new_pane:pane_id())
  -- 最左へ移動してフォーカス (人間がオーケストレーターを見ておけるように)。
  pcall(function()
    new_pane:activate()
    window:perform_action(act.MoveTab(0), pane)
  end)
end

function M.open(window, pane, deps)
  local L = deps.opts.labels
  local rows = collect_rows(deps)
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
      title = "司令塔",
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(iw, ip, id)
        if not id or id:match("^_sep_") then return end
        local pid = tonumber(id:match("^pane:(%d+)$"))
        if not pid then return end
        deps.managed.toggle(deps.opts.managed_file, pid)
        -- 監督対象が非空になり、まだオーケストレーターが居なければ起動する (手動クローズ後も次トグルで復活)。
        local nonempty = next(deps.managed.read(deps.opts.managed_file)) ~= nil
        if nonempty and deps.opts.auto_orchestrator and not orchestrator_alive(deps) then
          launch_orchestrator(iw, ip, deps)
          return -- 起動時はオーケストレーターを見せ、コンソールは閉じる
        end
        -- 既に稼働中 or 空: その場で続けて管理できるよう再オープン。
        M.open(iw, ip, deps)
      end),
    }),
    pane
  )
end

return M
