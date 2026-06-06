-- Agent registry and aggregation helpers.
--
-- An agent implementation must expose:
--   id            : string identifier ("claude", "cursor", ...)
--   display_name  : human-readable name
--   colors        : { working, waiting, done, idle [, error] }
--   spawn_args(opts, session_id, cwd) -> table  -- args for wezterm spawn
--   default_opts  : table merged under opts.agents[id]
-- icons is injected by init.lua from resource/icons.lua (unicode or nerd font).
--
-- Optional (injected by register() if not provided):
--   default_state : fallback state when file is absent (default "idle")
--   detect, state, session_id, consume_done, spawn_args
-- spawn_args receives agent_opts (from opts_for), which carries:
--   shell_quote(s) — POSIX single-quote escaping utility

local wezterm = require("wezterm")
local mux = wezterm.mux

local M = {}

function M.shell_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

-- 状態ファイルは自 GUI プロセス PID のサブディレクトリに名前空間化される (複数プロセス間の誤削除・pane_id 衝突を防ぐ)。
-- 書き込み側 (hooks) は WEZTERM_UNIX_SOCKET 由来、読み取り側 (ここ) は procinfo.pid() 由来で同一 PID に合意する。
local own_pid_cache
local function own_pid()
  if not own_pid_cache then own_pid_cache = tostring(wezterm.procinfo.pid()) end
  return own_pid_cache
end
local function ns_dir(base) return base .. "/" .. own_pid() end

function M.read_state_file(pane_id, status_dir)
  local path = status_dir .. "/wezterm-agent-" .. pane_id
  local f = io.open(path, "r")
  if not f then return nil end
  local raw = f:read("*a")
  f:close()
  if not raw or raw == "" then return nil end
  local ok, data = pcall(wezterm.json_parse, raw)
  if not ok or type(data) ~= "table" then return nil end
  return data
end

local registry = {}
local order = {}

function M.register(impl)
  if not impl or not impl.id then error("agent.register: impl.id is required") end

  local agent_id = impl.id
  local fallback = impl.default_state or "idle"

  if not impl.detect then
    impl.detect = function(pane, opts)
      local data = M.read_state_file(pane:pane_id(), opts.status_dir)
      return data ~= nil and data.agent == agent_id
    end
  end

  if not impl.state then
    impl.state = function(pane, opts)
      local data = M.read_state_file(pane:pane_id(), opts.status_dir)
      if not data or not data.state then return fallback end
      return data.state
    end
  end

  if not impl.session_id then
    impl.session_id = function(pane, opts)
      local data = M.read_state_file(pane:pane_id(), opts.status_dir)
      if not data or not data.session_id or data.session_id == "" then return nil end
      return data.session_id
    end
  end

  if not impl.consume_done then
    impl.consume_done = function(pane, opts)
      local path = opts.status_dir .. "/wezterm-agent-" .. pane:pane_id()
      local f = io.open(path, "r")
      if not f then return false end
      local raw = f:read("*a")
      f:close()
      if not raw or raw == "" then return false end
      local ok, data = pcall(wezterm.json_parse, raw)
      if not ok or type(data) ~= "table" then return false end
      if data.state ~= "done" or data.agent ~= agent_id then return false end
      data.state = fallback
      data.ts = os.time()
      local wf = io.open(path, "w")
      if not wf then return false end
      wf:write(wezterm.json_encode(data) .. "\n")
      wf:close()
      return true
    end
  end

  if not impl.spawn_args then
    impl.spawn_args = function(opts, session_id, cwd)
      local cmd = opts.command
      if session_id then cmd = cmd .. " --resume " .. M.shell_quote(session_id) end
      local cd_prefix = ""
      if cwd then cd_prefix = "cd " .. M.shell_quote(cwd) .. " && " end
      local shell = opts.shell
      return { shell, "-lc", string.format("%s%s; exec %s -l", cd_prefix, cmd, shell) }
    end
  end

  if not registry[impl.id] then table.insert(order, impl.id) end
  registry[impl.id] = impl
end

function M.get(id) return registry[id] end

function M.all()
  local list = {}
  for _, id in ipairs(order) do
    table.insert(list, registry[id])
  end
  return list
end

-- 各エージェントの実行バイナリが PATH 上に在るかを 1 回のログインシェル実行で判定する。
-- candidates: { {id=, bin=}, ... }。戻り値: インストール済み id の集合 ({ id = true })。
-- ただしシェル実行自体に失敗した場合 (検出不能) は nil を返し、呼び出し側のフォールバックに委ねる。
-- run はテスト差し替え用 (既定 wezterm.run_child_process)。
function M.detect_installed(candidates, shell, run)
  run = run or wezterm.run_child_process
  if not candidates or #candidates == 0 then return {} end
  -- 各 bin: 見つかったら id を 1 行出力。bin/id は単一引用符エスケープして注入を防ぐ。
  -- command -v は PATH 上の実行ファイル/絶対パス/シェル関数のいずれでも真を返す。
  local parts = {}
  for _, c in ipairs(candidates) do
    parts[#parts + 1] = "command -v " .. M.shell_quote(c.bin) .. " >/dev/null 2>&1 && printf '%s\\n' " .. M.shell_quote(c.id)
  end
  local ok, stdout = run({ shell, "-lc", table.concat(parts, "; ") })
  if not ok then return nil end
  local installed = {}
  -- 既知 id の集合として扱うため、profile 由来のノイズ行が混ざっても無害。
  for id in (stdout or ""):gmatch("[^\r\n]+") do
    installed[id] = true
  end
  return installed
end

-- Build per-agent opts by merging defaults + user overrides.
-- Plugin-level status_dir is injected unless agent-specific override exists.
function M.opts_for(agent_impl, plugin_opts)
  local out = {}
  for k, v in pairs(agent_impl.default_opts or {}) do
    out[k] = v
  end
  local user = plugin_opts.agents and plugin_opts.agents[agent_impl.id] or {}
  for k, v in pairs(user) do
    out[k] = v
  end
  if not out.status_dir and plugin_opts.status_dir then out.status_dir = plugin_opts.status_dir end
  -- status_base はフック/spawn に渡す名前空間なしの base。読み取りは PID 名前空間配下を見る。
  out.status_base = out.status_dir
  if out.status_dir then out.status_dir = ns_dir(out.status_dir) end
  out.shell_quote = M.shell_quote
  return out
end

-- hooks へは名前空間なしの base を渡す。フック側が WEZTERM_UNIX_SOCKET 由来の PID で名前空間を付ける。
function M.spawn_env(agent_opts) return { WEZTERM_AGENT_STATUS_DIR = agent_opts.status_base or agent_opts.status_dir } end

-- Find which agent (if any) is running in the given pane.
function M.detect(pane, plugin_opts)
  for _, impl in ipairs(M.all()) do
    local agent_opts = M.opts_for(impl, plugin_opts)
    if impl.detect(pane, agent_opts) then return impl, agent_opts end
  end
  return nil, nil
end

-- 重複のない base status_dir 一覧 (名前空間なし): プラグイン共通 + エージェント別オーバーライド。
-- 名前空間 dir の親であり、死んだ PID dir の掃除 (cleanup_dead_namespaces) はこの base を走査する。
local function base_dirs(plugin_opts)
  local seen, dirs = {}, {}
  local function add(d)
    if d and not seen[d] then
      seen[d] = true
      dirs[#dirs + 1] = d
    end
  end
  add(plugin_opts.status_dir)
  if plugin_opts.agents then
    for _, a in pairs(plugin_opts.agents) do
      if type(a) == "table" then add(a.status_dir) end
    end
  end
  return dirs
end

-- 読み取り/掃除の探索対象: 各 base を自 PID で名前空間化した dir 一覧。
-- 単一 dir の一般的な構成ではエントリは 1 つだけなので、ペインは 1 回だけ読まれる。
local function candidate_dirs(plugin_opts)
  local seen, dirs = {}, {}
  for _, base in ipairs(base_dirs(plugin_opts)) do
    local d = ns_dir(base)
    if not seen[d] then
      seen[d] = true
      dirs[#dirs + 1] = d
    end
  end
  return dirs
end

-- 1 ペインの (impl, state) を状態ファイル 1 回読み取りで解決する。
local function resolve_in_dirs(pane_id, dirs)
  for _, dir in ipairs(dirs) do
    local data = M.read_state_file(pane_id, dir)
    if data and data.agent then
      local impl = registry[data.agent]
      if impl then return impl, data.state or impl.default_state or "idle" end
    end
  end
  return nil, nil
end

-- 公開用の 1 回読み取りリゾルバ。タブタイトル描画 (1 ペインずつ) から使う。
function M.resolve(pane_id, plugin_opts) return resolve_in_dirs(pane_id, candidate_dirs(plugin_opts)) end

-- 自プロセスの閉じたペインの孤立状態ファイルを掃除する。candidate_dirs は自 PID 名前空間配下
-- なので、他プロセスのファイルには構造的に触れない。定期 sync と同じタイミングで実行する。
function M.sweep_orphan_files(plugin_opts)
  -- 生存 pane 集合。pane_id は mux 内で大域一意なので全 window/workspace を合算した 1 集合でよい。
  -- ファイル名から抽出する文字列 id と型を揃えるため tostring で文字列化する。
  local live, any = {}, false
  for _, win in ipairs(mux.all_windows()) do
    for _, tab in ipairs(win:tabs()) do
      for _, p in ipairs(tab:panes()) do
        live[tostring(p:pane_id())] = true
        any = true
      end
    end
  end
  -- 空集合ガード: all_windows() が一時的に空を返す瞬間に全削除へ倒れるのを防ぐ必須の安全弁。
  if not any then return end

  for _, dir in ipairs(candidate_dirs(plugin_opts)) do
    local ok, entries = pcall(wezterm.read_dir, dir)
    if ok and entries then
      for _, path in ipairs(entries) do
        -- 末尾が数値のものだけを pane_id として扱う。書き込み中の .tmp や非数値名は対象外。
        local id = path:match("/wezterm%-agent%-(%d+)$")
        if id and not live[id] then os.remove(path) end
      end
    end
  end
end

-- 名前空間 dir (中はフラットな状態ファイルのみ) を中身ごと削除する。
local function remove_dir_with_files(dir)
  local ok, entries = pcall(wezterm.read_dir, dir)
  if ok and entries then
    for _, path in ipairs(entries) do
      os.remove(path)
    end
  end
  os.remove(dir)
end

-- 起動時に呼ぶ掃除。base 直下を 1 回走査し、(1) 死んだ GUI プロセスの PID 名前空間 dir と
-- (2) 旧バージョンが base 直下に書いたフラットなレガシー残置を回収する。PID dir 単位
-- (エージェント非依存) なので impl ごとに繰り返さず 1 回だけ実行する。
function M.cleanup_dead_namespaces(plugin_opts)
  local self_ns = own_pid()
  for _, base in ipairs(base_dirs(plugin_opts)) do
    local ok, entries = pcall(wezterm.read_dir, base)
    if ok and entries then
      for _, path in ipairs(entries) do
        local name = path:match("[^/]+$")
        local pid = name and name:match("^(%d+)$")
        if pid then
          -- 自分と、get_info_for_pid が情報を返すプロセス (生存とみなす) の dir は残す。
          if pid ~= self_ns and wezterm.procinfo.get_info_for_pid(tonumber(pid)) == nil then remove_dir_with_files(path) end
        elseif name and name:match("^wezterm%-agent%-") then
          os.remove(path) -- 名前空間化以前のフラット残置
        end
      end
    end
  end
end

-- Aggregate state counts across panes, optionally scoped to a workspace.
function M.count(plugin_opts, ws_name)
  local counts = { working = 0, waiting = 0, done = 0, idle = 0, error = 0, unknown = 0 }
  local dirs = candidate_dirs(plugin_opts)
  for _, win in ipairs(mux.all_windows()) do
    if not ws_name or win:get_workspace() == ws_name then
      for _, tab in ipairs(win:tabs()) do
        for _, p in ipairs(tab:panes()) do
          local _, st = resolve_in_dirs(p:pane_id(), dirs)
          if st and counts[st] then counts[st] = counts[st] + 1 end
        end
      end
    end
  end
  return counts
end

function M.all_workspaces(plugin_opts)
  local result = {}
  local dirs = candidate_dirs(plugin_opts)
  for _, win in ipairs(mux.all_windows()) do
    local ws = win:get_workspace()
    local bucket = result[ws] or { working = 0, waiting = 0, done = 0, idle = 0, error = 0, unknown = 0 }
    for _, tab in ipairs(win:tabs()) do
      for _, p in ipairs(tab:panes()) do
        -- count と同じ 1 回読み取りに統一。impl が nil = エージェント未検出のペインは数えない。
        local impl, st = resolve_in_dirs(p:pane_id(), dirs)
        if impl and bucket[st] then bucket[st] = bucket[st] + 1 end
      end
    end
    result[ws] = bucket
  end
  return result
end

-- Find first agent pane in a tab, returning (agent_impl, agent_opts, pane).
function M.find_in_tab(tab, plugin_opts)
  for _, p in ipairs(tab:panes()) do
    local impl, agent_opts = M.detect(p, plugin_opts)
    if impl then return impl, agent_opts, p end
  end
  return nil, nil, nil
end

return M
