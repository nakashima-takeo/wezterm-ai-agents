-- wezterm-ai-agents: entry point.
-- Usage:
--   local plugin = wezterm.plugin.require("https://github.com/nakashima-takeo/wezterm-ai-agents")
--   plugin.apply(config, { agents = { claude = { command = "..." } } })
--
-- Or for local development (no `debug` library in WezTerm Lua sandbox, so the
-- plugin directory must be provided explicitly via opts.plugin_dir):
--   local plugin_dir = wezterm.home_dir .. "/github/wezterm-ai-agents"
--   local plugin = dofile(plugin_dir .. "/plugin/init.lua")
--   plugin.apply(config, { plugin_dir = plugin_dir, ... })

local wezterm = require("wezterm")

-- 状態ファイルの保存先。XDG_STATE_HOME 準拠の永続領域に置く (OS の reaping 対象外)。
-- hooks/agent_status.sh のフォールバックと同一規則 (末尾スラッシュ正規化なしの素朴連結) で揃える。
local function default_status_dir()
  local base = os.getenv("XDG_STATE_HOME")
  if not base or base == "" then base = wezterm.home_dir .. "/.local/state" end
  return base .. "/wezterm-ai-agents"
end

-- ============== Module loader ==============

local function detect_plugin_dir(user_dir)
  if user_dir then return user_dir end
  for _, p in ipairs(wezterm.plugin.list()) do
    if p.url:find("wezterm%-ai%-agents") or p.component:find("wezterm%-ai%-agents") then return p.plugin_dir end
  end
  error("wezterm-ai-agents: plugin_dir not detected. Pass opts.plugin_dir or load via wezterm.plugin.require.")
end

local workspace, worktree, layout, selector, agent, ui, builtin_labels, builtin_icons, editor, links, diagnostics

local all_agent_ids = { "claude", "cursor", "codex", "gemini" }

-- モジュールを層順 (下位→上位) にロードする。配置と並びがそのまま依存階層を表す。
-- 下位は UI を知らず、上位 (selector/ui) が deps 経由で下位を呼ぶ。循環は引数注入で回避済み。
local function load_modules(plugin_dir, enabled_agents)
  local function load(rel) return dofile(plugin_dir .. "/plugin/" .. rel .. ".lua") end

  -- resource/ 下位層: データ (他に依存しない)
  builtin_labels = load("resource/labels")
  builtin_icons = load("resource/icons")

  -- service/ 下位層: I/O・外部コマンド (UI に依存しない)
  diagnostics = load("service/diagnostics")
  agent = load("service/agent")
  worktree = load("service/worktree/init")
  worktree.setup(load("service/worktree/github"))
  editor = load("service/editor")
  links = load("service/links")

  -- state/ 中位層: 永続化・レイアウト (agent/layout を引数注入し循環回避)
  workspace = load("state/workspace/init")
  workspace.setup(load("state/workspace/session"))
  layout = load("state/layout")

  -- ui/ 上位層: UI・オーケストレーション (deps 経由で下位/中位を呼ぶ)
  ui = load("ui/ui")
  selector = load("ui/selector/init")
  selector.setup(load("ui/selector/workspace"), load("ui/selector/worktree"), load("ui/selector/ui"))

  for _, id in ipairs(enabled_agents or all_agent_ids) do
    local found = false
    for _, valid in ipairs(all_agent_ids) do
      if id == valid then
        found = true
        break
      end
    end
    if not found then error("wezterm-ai-agents: unknown agent '" .. id .. "'. Available: " .. table.concat(all_agent_ids, ", ")) end
    agent.register(load("service/agents/" .. id))
  end
end

local M = {
  version = "0.12.0",
  workspace = nil,
  worktree = nil,
  layout = nil,
  selector = nil,
  agent = nil,
  ui = nil,
}

-- install_hooks.sh の実行結果 (ran=終了コード0か, stdout=結果行) から、
-- ユーザーに知らせるべき失敗文言を返す (知らせる必要が無ければ nil)。原因を推測せず、
-- sh が返した結果コードを原因別に解釈する。symlink/unknown スキップや成功は通知しない。
local function install_hooks_diagnostic(ran, stdout)
  stdout = stdout or ""
  -- ユーザーが体感する機能名 (タブ等の状態表示) で、原因と次の一手を示す。内部用語と推測は使わない。
  local headline = "エージェントの状態表示を有効化できませんでした。"
  if stdout:find("jq-missing", 1, true) then return headline .. "jq を入れて WezTerm を再起動してください" end
  -- 既存設定が不正な JSON で触れなかったエージェントを集める (握りつぶさず id 付きで知らせる)。
  local broken = {}
  for id in stdout:gmatch("skip%-invalid%-json%s+(%S+)") do
    broken[#broken + 1] = id
  end
  if #broken > 0 then return headline .. "設定ファイルが壊れています: " .. table.concat(broken, ", ") end
  if not ran then return headline .. "手動設定は README を参照してください" end
  return nil
end
M._install_hooks_diagnostic = install_hooks_diagnostic

-- ============== Defaults ==============

local default_opts = {
  workspace = {
    -- 状態ファイルと同一の base (XDG_STATE_HOME 配下) 直下に集約する。PID 名前空間は付けない
    -- (全 GUI プロセスで共有するデータであり、名前空間配下に置くと PID 終了時の dir 掃除で消えるため)。
    file = default_status_dir() .. "/workspaces.json",
    -- default_workspace は持たない。WezTerm 本体の config.default_workspace を単一の真実源とし、
    -- apply() 内で opts.workspace.default_workspace に反映する (起動 WS 名との食い違いを構造的に防ぐ)。
  },
  default_tabs = { {} },

  worktree = {
    path = "sibling", -- "sibling" | "subdirectory" | custom template with {git_root}, {parent}, {repo}, {branch}
  },

  nerd_font = true,
  font = nil, -- primary フォント (family 文字列 or { family=..., 属性 })。nil = JetBrains Mono。日本語フォールバックは自動付加
  status_dir = default_status_dir(),
  enabled_agents = nil, -- nil = all; or { "claude" } to register only specific agents
  default_agent = nil, -- nil = first registered; or "claude" to set default agent for Cmd+Shift+C
  default_editor = nil, -- nil = auto-detect (code/cursor/windsurf/zed/subl); or "/usr/local/bin/cursor" etc.
  -- ターミナル出力中のファイルパスをクリックでエディタの該当行に開く (editor:// / editor-rel://)。
  -- 実在しないパスにも下線が出る WezTerm の制約上、誤クリックの空振りが起こりうるため既定 off。
  editor_links = false,
  agents = {
    -- agent-specific overrides, e.g. claude = { command = "claude --foo" }
  },

  ui = {
    tab_title = {
      max_chars = 24,
      active_bg = "#1e1e2e",
      active_fg = "#cdd6f4",
      accent_fg = "#b4befe",
      inactive_bg = "#11111b",
      inactive_fg = "#585b70",
    },
    right_status = {
      fg = "#a6adc8",
      cwd_width = 20, -- 右ステータスの cwd 表示の最大幅 (桁)。超過時のみ切り詰め、短い時は右へ詰める
      reserve = 48, -- タブバー幅算出で差し引く右ステータスの占有幅 (桁)
      -- colors: derived from first registered agent at apply() time.
      -- Override here to use custom colors instead of agent defaults.
    },
  },

  install_ui_tab_title = true,
  install_ui_status = true,
  install_keybinds = true,
  install_hooks = true,
  disabled_keybinds = {},
  keybinds = {},
  modifier_prefix = wezterm.target_triple:find("darwin") and "CMD" or "CTRL",
  locale = nil, -- nil = apply() 時に自動判定 (detect_locale)。"ja"/"en" を明示指定で固定も可

  status_update_interval = 1, -- right-status refresh (sec)
  session_sync_interval = 5, -- workspace full snapshot sync (sec)

  right_status_extra = nil, -- function(window, pane, deps) -> segments
}

local function is_array(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
    if t[n] == nil then return false end
  end
  return n > 0
end

local function merge(base, override)
  local out = {}
  for k, v in pairs(base) do
    if type(v) == "table" then
      out[k] = merge(v, {})
    else
      out[k] = v
    end
  end
  if override then
    for k, v in pairs(override) do
      if type(v) == "table" and type(out[k]) == "table" and not is_array(v) then
        out[k] = merge(out[k], v)
      else
        out[k] = v
      end
    end
  end
  return out
end

-- 表示言語の判定。POSIX のロケール優先順位 (LC_ALL > LC_MESSAGES > LANG) に従う。
-- すべて空かつ macOS の場合のみ、GUI 起動 (Dock 等) では環境変数が継承されず LANG が
-- 空になるため、システムロケール (AppleLocale) を参照する。判定は言語部分の先頭2文字のみ。
local function detect_locale()
  local v = os.getenv("LC_ALL")
  if not v or v == "" then v = os.getenv("LC_MESSAGES") end
  if not v or v == "" then v = os.getenv("LANG") end
  if (not v or v == "") and wezterm.target_triple:find("darwin") then
    local ok, stdout = wezterm.run_child_process({ "defaults", "read", "-g", "AppleLocale" })
    if ok then v = stdout end
  end
  return (v or ""):sub(1, 2) == "ja" and "ja" or "en"
end

-- ============== Apply ==============

function M.apply(config, user_opts)
  local opts = merge(default_opts, user_opts)
  M.opts = opts

  -- 言語は apply ごとに判定し、設定リロードでシステム言語変更に追従する。
  -- user_opts で明示指定があればそれを尊重 (merge 済み)。
  opts.locale = opts.locale or detect_locale()

  local plugin_dir = detect_plugin_dir(opts.plugin_dir)
  load_modules(plugin_dir, opts.enabled_agents)
  M.workspace, M.worktree, M.layout, M.selector, M.agent, M.ui = workspace, worktree, layout, selector, agent, ui

  if opts.default_agent and not agent.get(opts.default_agent) then
    wezterm.log_error(
      "wezterm-ai-agents: default_agent '" .. opts.default_agent .. "' is not registered. Check enabled_agents or spelling."
    )
  end

  local icon_set = opts.nerd_font and builtin_icons.nerd or builtin_icons.unicode
  opts.icons = icon_set
  for _, impl in ipairs(agent.all()) do
    impl.icons = icon_set
  end

  opts.labels = merge(builtin_labels[opts.locale] or builtin_labels.en, opts.labels or {})

  -- 起動 WS 名の単一の真実源は WezTerm 本体の config.default_workspace (未設定なら WezTerm 既定 "default")。
  -- selector はこの値で default WS を特別扱いするため、ここで opts に反映して食い違いを防ぐ。
  opts.workspace.default_workspace = config.default_workspace or "default"

  M.hooks_dir = plugin_dir .. "/hooks"
  wezterm.log_info("wezterm-ai-agents v" .. M.version .. " loaded (hooks_dir = " .. M.hooks_dir .. ")")

  wezterm.on("gui-startup", function()
    -- 死んだ GUI プロセスの状態ファイル名前空間と、旧バージョンのフラット残置を回収する。
    local ok, err = pcall(agent.cleanup_dead_namespaces, opts)
    if not ok then wezterm.log_warn("[ai-agents] cleanup_dead_namespaces failed: " .. tostring(err)) end
    -- 各エージェントの設定ファイルに状態追跡フックを冪等マージする (既定 ON)。複数回発火しても冪等。
    -- jq 欠如・不正JSON など「知らせるべき失敗」は原因別に diagnostics へ上げる (symlink/unknown スキップは正常)。
    if opts.install_hooks then
      local cmd = { "bash", M.hooks_dir .. "/install_hooks.sh", M.hooks_dir }
      for _, impl in ipairs(agent.all()) do
        cmd[#cmd + 1] = impl.id
      end
      local ran, stdout = wezterm.run_child_process(cmd)
      local msg = install_hooks_diagnostic(ran, stdout)
      if msg then diagnostics.report("install_hooks", msg) end
    end
    wezterm.plugin.update_all()
  end)

  -- Derive status colors/icons from all registered agents (first wins), merged with user overrides.
  local agent_colors, agent_icons = {}, {}
  for _, impl in ipairs(agent.all()) do
    for k, v in pairs(impl.colors or {}) do
      if not agent_colors[k] then agent_colors[k] = v end
    end
    for k, v in pairs(impl.icons or {}) do
      if not agent_icons[k] then agent_icons[k] = v end
    end
  end
  opts.ui.right_status.colors = merge(agent_colors, opts.ui.right_status.colors or {})
  opts.ui.right_status.icons = merge(agent_icons, opts.ui.right_status.icons or {})

  local pin_icon_set = opts.nerd_font and builtin_icons.nerd or builtin_icons.unicode
  opts.ui.right_status.pin_icon = opts.ui.right_status.pin_icon or pin_icon_set.pin
  opts.ui.right_status.pin_color = opts.ui.right_status.pin_color or "#b4befe"

  local deps = {
    workspace = workspace,
    worktree = worktree,
    layout = layout,
    selector = selector,
    agent = agent,
    ui = ui,
    editor = editor,
    opts = opts,
  }
  M.deps = deps

  -- 見た目・タブバーのデフォルトを常時・非破壊で適用する (キュレートされた見た目がこのプラグインのデフォルト)。
  -- 利用者は config.X = ... を書けば自分の値に置換できる。
  -- 文字列/数値/テーブルは `config.X = config.X or default`、bool は `if config.X == nil` で入れる
  -- (bool に `or` を使うと利用者の false を true で潰してしまうため)。
  -- フォント本体 (font family) は環境依存のため指定しない。ただし WezTerm 同梱 JetBrains Mono は
  -- 日本語を持たず、WezTerm のフォールバックも不出来なので、OS 標準の日本語フォントだけをフォールバックに足す。
  local tt = opts.ui.tab_title
  config.color_scheme = config.color_scheme or "Catppuccin Mocha"
  config.window_background_opacity = config.window_background_opacity or 0.92
  if config.macos_window_background_blur == nil and wezterm.target_triple:find("darwin") then config.macos_window_background_blur = 18 end
  config.window_decorations = config.window_decorations or "RESIZE"
  config.window_padding = config.window_padding or { left = 10, right = 10, top = 10, bottom = 6 }
  -- RESIZE で閉じるボタンを除去し disable_quit で終了もNopしているため、誤爆は構造的に塞がれている。
  -- 意図的クローズ時の確認は摩擦でしかないので NeverPrompt。
  config.window_close_confirmation = config.window_close_confirmation or "NeverPrompt"
  -- 字形重視の軽いヒンティング (やや柔らかめ。WezTerm 既定は "Normal")。
  config.freetype_load_target = config.freetype_load_target or "Light"
  -- WezTerm 既定 80x24 は手狭。セル数なので環境非依存 (Windows Terminal も 120x30 を共通既定に採用)。
  config.initial_cols = config.initial_cols or 120
  config.initial_rows = config.initial_rows or 30
  -- 日本語フォールバック: primary フォント (opts.font 既定 JetBrains Mono) に OS 標準の和文フォントを足す。
  -- opts.font に好きなフォントを渡しても日本語が自動で付く (primary がその字を持てば primary 優先)。
  -- 利用者が config.font を直接設定していれば触らない。WezTerm が既定フォールバックを後ろに自動付加する。
  if config.font == nil then
    local jp = "Noto Sans CJK JP" -- Linux: 標準保証はないが入っていれば改善、無ければ素のフォールバックのまま
    if wezterm.target_triple:find("darwin") then
      jp = "Hiragino Sans" -- macOS に自動インストールされる和文ゴシック
    elseif wezterm.target_triple:find("windows") then
      jp = "Yu Gothic"
    end
    config.font = wezterm.font_with_fallback({ opts.font or "JetBrains Mono", jp })
  end
  -- フィールド単位で補う: 利用者が window_frame をフォント等のために設定していても titlebar 色は適用される。
  -- active=フォーカス中 / inactive=非フォーカス時の fancy タブバー背景色。
  config.window_frame = config.window_frame or {}
  if config.window_frame.active_titlebar_bg == nil then config.window_frame.active_titlebar_bg = tt.inactive_bg end
  if config.window_frame.inactive_titlebar_bg == nil then config.window_frame.inactive_titlebar_bg = tt.inactive_bg end
  config.colors = config.colors or {}
  config.colors.tab_bar = config.colors.tab_bar
    or {
      background = tt.inactive_bg,
      active_tab = { bg_color = tt.active_bg, fg_color = tt.active_fg },
      inactive_tab = { bg_color = tt.inactive_bg, fg_color = tt.inactive_fg },
      inactive_tab_hover = { bg_color = tt.active_bg, fg_color = opts.ui.right_status.fg },
    }
  if config.use_fancy_tab_bar == nil then config.use_fancy_tab_bar = true end
  if config.show_close_tab_button_in_tabs == nil then config.show_close_tab_button_in_tabs = false end
  if config.show_new_tab_button_in_tab_bar == nil then config.show_new_tab_button_in_tab_bar = false end
  if config.hide_tab_bar_if_only_one_tab == nil then config.hide_tab_bar_if_only_one_tab = false end -- 1タブ時もエージェント状態UIを表示
  -- WezTerm の tab_max_width (既定16) がタブタイトル幅の上限になるため、max_chars に余裕分を足して連動させる。
  config.tab_max_width = config.tab_max_width or (tt.max_chars + 8)
  -- 並列ペインでエージェントを動かすため、フォーカス中ペイン由来 (OSC 9/777) の通知のみ抑制し、
  -- 同一タブの兄弟ペインの通知は出す。他の値: AlwaysShow / NeverShow / SuppressFromFocusedTab / SuppressFromFocusedWindow
  config.notification_handling = config.notification_handling or "SuppressFromFocusedPane"
  -- エージェントの大量出力向けに既定 3500 から拡張。
  config.scrollback_lines = config.scrollback_lines or 20000

  if opts.install_ui_tab_title then
    wezterm.on(
      "format-tab-title",
      function(tab, tabs, _panes, _config, _hover, max_width) return ui.format_tab_title(tab, deps, max_width, #tabs) end
    )
  end

  if opts.install_ui_status then
    local last_status_tick = 0
    local last_sync_tick = 0
    local prev_win_id = nil
    local prev_pane_id = {} -- win_id ごとのフォーカスペイン (マルチウィンドウで誤検出しないよう分離)
    wezterm.on("update-status", function(window, pane)
      local now = os.time()
      pcall(selector.maybe_prefetch, window, pane, deps)
      local win_id = tostring(window:window_id())
      if prev_win_id and prev_win_id ~= win_id and selector.pinned_windows[prev_win_id] then
        selector.pinned_windows[prev_win_id] = nil
        selector.pinned_windows[win_id] = true
      end
      prev_win_id = win_id
      -- フォーカスペインが変わった瞬間は、そのペインの完了ベルを即クリアできるよう更新を強制する
      -- (利用者が完了ペインに切替/フォーカスした直後にベルが残り続けるのを防ぐ)。
      local pane_id = pane:pane_id()
      local focus_changed = prev_pane_id[win_id] ~= pane_id
      prev_pane_id[win_id] = pane_id
      if focus_changed or (now - last_status_tick) >= opts.status_update_interval then
        last_status_tick = now
        -- 知らせるべき失敗 (window 不在の経路で溜まった分) を、アクティブペインへ端末出力する。
        -- 通常の出力としてスクロールバックに残り、ユーザーは Ctrl+L 等で消せる。
        for _, msg in ipairs(diagnostics.take_pending()) do
          pcall(function() pane:inject_output("\r\n\27[33m[wezterm-ai-agents] " .. msg .. "\27[0m\r\n") end)
        end
        local impl, agent_opts = agent.detect(pane, opts)
        if impl and impl.consume_done then pcall(impl.consume_done, pane, agent_opts) end
        local segs = ui.right_status_segments(window, pane, deps)
        window:set_right_status(wezterm.format(segs))
      end
      if (now - last_sync_tick) >= opts.session_sync_interval then
        last_sync_tick = now
        pcall(workspace.sync_all, opts.workspace, agent, layout, opts)
        -- 生存 pane に対応しない孤立状態ファイルを掃除する (reaping を失った分を継続的に解消)。
        pcall(agent.sweep_orphan_files, opts)
      end
    end)
  end

  if opts.install_keybinds then
    local user_keys = config.keys or {}
    local plugin_keys = selector.build_keybinds(deps)
    local merged = {}
    for _, k in ipairs(plugin_keys) do
      table.insert(merged, k)
    end
    for _, k in ipairs(user_keys) do
      table.insert(merged, k)
    end
    config.keys = merged
  end

  -- ターミナル出力のファイルパスをクリック可能にする (opt-in)。
  if opts.editor_links then links.setup(config, deps) end

  return M
end

return M
