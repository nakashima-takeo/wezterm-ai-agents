-- Selector UIs and keybinds for workspace + worktree management.
-- All public functions take `deps` (injected modules) to avoid cyclic loads.
--   deps = { workspace, layout, worktree, agent, opts }

local wezterm = require("wezterm")
local mux = wezterm.mux
local act = wezterm.action

local M = {}

M.pinned_windows = {}

-- ============== Helpers ==============

local function get_cwd_path(pane)
  local cwd = pane:get_current_working_dir()
  if not cwd then return nil end
  return cwd.file_path or tostring(cwd):gsub("^file://[^/]*", "")
end

local function toast(window, msg, ms) window:toast_notification("WezTerm", msg, nil, ms or 3000) end

local GUI_EDITORS = { "code", "cursor", "windsurf", "zed", "subl" }
local gui_editor_set = {}
for _, e in ipairs(GUI_EDITORS) do
  gui_editor_set[e] = true
end

local function is_gui_editor(cmd)
  if not cmd then return false end
  local basename = cmd:match("([^/]+)$") or cmd
  return gui_editor_set[basename] ~= nil
end

local cached_editor = nil
local function detect_gui_editor(explicit)
  if explicit then return explicit end
  if cached_editor ~= nil then return cached_editor or nil end
  for _, env in ipairs({ "VISUAL", "EDITOR" }) do
    local val = os.getenv(env)
    if is_gui_editor(val) then
      cached_editor = val
      return val
    end
  end
  local query = "command -v " .. table.concat(GUI_EDITORS, " ") .. " 2>/dev/null | head -1"
  local ok, stdout = wezterm.run_child_process({ "/bin/sh", "-lc", query })
  if ok and stdout then
    local path = stdout:match("(%S+)")
    if path then
      cached_editor = path
      return path
    end
  end
  cached_editor = false
  return nil
end

local function build_ws_header(fmt, ws_name, is_running)
  if is_running then
    table.insert(fmt, { Foreground = { AnsiColor = "Green" } })
    table.insert(fmt, { Text = "● " })
  else
    table.insert(fmt, { Foreground = { AnsiColor = "Grey" } })
    table.insert(fmt, { Text = "▸ " })
  end
  table.insert(fmt, { Attribute = { Intensity = "Bold" } })
  table.insert(fmt, { Foreground = { AnsiColor = "Aqua" } })
  table.insert(fmt, { Text = ws_name })
  table.insert(fmt, "ResetAttributes")
end

local CHIP_STATE_ORDER = { "working", "waiting", "done", "idle", "error" }

local function append_agents_colored(fmt, deps, ws_name)
  local c = deps.agent.count(deps.opts, ws_name)
  local colors = deps.opts.ui.right_status.colors
  local icons = deps.opts.ui.right_status.icons
  local any = false
  for _, key in ipairs(CHIP_STATE_ORDER) do
    local n = c[key] or 0
    if n > 0 and colors[key] and icons[key] then
      local suffix = n > 1 and ("\xC3\x97" .. n) or ""
      table.insert(fmt, { Foreground = { Color = colors[key] } })
      table.insert(fmt, { Text = (any and " " or "  ") .. icons[key] .. " " .. suffix })
      any = true
    end
  end
  return any
end

local function append_ws_status(fmt, ws, is_running, deps)
  if is_running then
    append_agents_colored(fmt, deps, ws.name)
  else
    local saved = deps.workspace.count_saved_sessions(ws)
    if saved > 0 then
      local idle_icon = deps.opts.ui.right_status.icons.idle or ""
      table.insert(fmt, { Foreground = { AnsiColor = "Grey" } })
      table.insert(fmt, { Text = "  " .. idle_icon .. " \xC3\x97" .. saved })
    end
  end
end

local function shorten_path(path)
  local home = wezterm.home_dir
  if path == home or path:sub(1, #home + 1) == home .. "/" then return "~" .. path:sub(#home + 1) end
  return path
end

-- List immediate subdirectories (incl. hidden) of `dir`, sorted, names only.
local function list_subdirs(dir)
  local ok, stdout = wezterm.run_child_process({ "ls", "-1Ap", "--", dir })
  if not ok or not stdout then return {} end
  local dirs = {}
  for line in stdout:gmatch("[^\n]+") do
    if line:sub(-1) == "/" then table.insert(dirs, line:sub(1, -2)) end
  end
  return dirs
end

local function parent_dir(dir)
  local parent = dir:gsub("/+$", ""):gsub("/[^/]*$", "")
  if parent == "" then return "/" end
  return parent
end

M.append_agents_colored = append_agents_colored
M.append_ws_status = append_ws_status
M.build_ws_header = build_ws_header
M.shorten_path = shorten_path

-- ============== Workspace selector (Cmd+Shift+S) ==============

function M.workspace_selector(window, pane, deps)
  local opts = deps.opts
  local L = opts.labels
  local data = deps.workspace.read(opts.workspace)
  local default_ws = opts.workspace.default_workspace

  local existing = {}
  for _, win in ipairs(mux.all_windows()) do
    existing[win:get_workspace()] = true
  end

  local choices = {}
  local sorted = deps.workspace.sort(data.workspaces, default_ws)

  for _, ws in ipairs(sorted) do
    local is_running = existing[ws.name] or false
    local fmt = {}
    build_ws_header(fmt, ws.name, is_running)
    append_ws_status(fmt, ws, is_running, deps)
    table.insert(choices, { id = "ws:" .. ws.name, label = wezterm.format(fmt) })
  end

  -- Unregistered running workspaces (default at top, others at bottom)
  local unregistered = {}
  for name, _ in pairs(existing) do
    if not deps.workspace.find(data, name) then table.insert(unregistered, name) end
  end
  for _, name in ipairs(unregistered) do
    local fmt = {}
    build_ws_header(fmt, name, true)
    append_agents_colored(fmt, deps, name)
    if name ~= default_ws then
      table.insert(fmt, { Foreground = { AnsiColor = "Red" } })
      table.insert(fmt, { Text = "  unregistered" })
    end
    local entry = { id = "ws:" .. name, label = wezterm.format(fmt) }
    if name == default_ws then
      table.insert(choices, 1, entry)
    else
      table.insert(choices, entry)
    end
  end

  -- Actions section
  table.insert(choices, { id = "_sep_actions", label = "── Actions ──" })
  table.insert(choices, { id = "action:new", label = L.ws_action_new })
  if #data.workspaces > 0 then table.insert(choices, { id = "action:delete", label = L.ws_action_delete }) end

  window:perform_action(
    act.InputSelector({
      title = "Workspaces",
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(iw, ip, id)
        if not id then return end
        if id:match("^_sep_") then return end

        if id == "action:new" then
          M.workspace_register(iw, ip, deps)
          return
        end
        if id == "action:delete" then
          M.workspace_delete(iw, ip, deps)
          return
        end

        local ws_name = id:match("^ws:(.+)$")
        if not ws_name then return end
        deps.workspace.update_last_used(opts.workspace, ws_name)
        if deps.workspace.exists(ws_name) then
          iw:perform_action(act.SwitchToWorkspace({ name = ws_name }), ip)
        else
          local ws_config = deps.workspace.find(data, ws_name)
          if ws_config then
            deps.workspace.create(ws_config, deps.agent, deps.layout, opts, opts.default_tabs)
            iw:perform_action(act.SwitchToWorkspace({ name = ws_name }), ip)
          end
        end
      end),
    }),
    pane
  )
end

-- ============== Workspace register (Cmd+Shift+N) ==============

-- InputSelector-based directory navigator. Fuzzy-filter subdirs, drill in/out,
-- and confirm. Calls on_select(dir) on confirmation. WezTerm has no native path
-- completion, so this is the substitute.
local function pick_directory(window, pane, dir, L, folder_icon, on_select)
  local function child(name) return (dir == "/" and "/" or dir .. "/") .. name end

  local choices = {}
  -- The primary "confirm here" action — colored/bold to stand apart from the plain
  -- navigation commands (up / mkdir) below it.
  table.insert(choices, {
    id = "_select",
    label = wezterm.format({
      { Foreground = { AnsiColor = "Green" } },
      { Attribute = { Intensity = "Bold" } },
      { Text = string.format(L.dir_select_here, shorten_path(dir)) },
      "ResetAttributes",
    }),
  })
  if dir ~= "/" then table.insert(choices, { id = "_up", label = L.dir_go_up }) end
  table.insert(choices, { id = "_mkdir", label = L.dir_make_new })
  for _, name in ipairs(list_subdirs(dir)) do
    table.insert(choices, { id = "dir:" .. name, label = folder_icon .. " " .. name })
  end

  window:perform_action(
    act.InputSelector({
      title = string.format(L.dir_picker_title, shorten_path(dir)),
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(iw, ip, id)
        if not id then return end
        if id == "_select" then
          on_select(dir)
        elseif id == "_up" then
          pick_directory(iw, ip, parent_dir(dir), L, folder_icon, on_select)
        elseif id == "_mkdir" then
          iw:perform_action(
            act.PromptInputLine({
              description = L.enter_new_dir_name,
              action = wezterm.action_callback(function(w2, p2, newname)
                newname = newname and newname:gsub("^/+", ""):gsub("/+$", "") or ""
                if newname == "" then
                  pick_directory(w2, p2, dir, L, folder_icon, on_select)
                  return
                end
                local target = child(newname)
                if not wezterm.run_child_process({ "mkdir", "-p", target }) then
                  toast(w2, string.format(L.mkdir_failed, newname))
                  pick_directory(w2, p2, dir, L, folder_icon, on_select)
                  return
                end
                pick_directory(w2, p2, target, L, folder_icon, on_select)
              end),
            }),
            ip
          )
        else
          local name = id:match("^dir:(.+)$")
          if name then pick_directory(iw, ip, child(name), L, folder_icon, on_select) end
        end
      end),
    }),
    pane
  )
end

function M.workspace_register(window, pane, deps)
  local opts = deps.opts
  local L = opts.labels
  local cwd_path = get_cwd_path(pane)
  if not cwd_path then
    toast(window, L.cannot_get_cwd)
    return
  end

  local folder_icon = (opts.icons and opts.icons.folder) or "📁"

  -- Pick the directory first, then suggest a workspace name from its basename.
  pick_directory(window, pane, cwd_path:gsub("/+$", ""):gsub("^$", "/"), L, folder_icon, function(cwd)
    cwd = cwd:gsub("/+$", ""):gsub("^$", "/")
    local default_name = cwd:match("([^/]+)$") or ""
    window:perform_action(
      act.PromptInputLine({
        description = L.enter_ws_name,
        initial_value = default_name,
        action = wezterm.action_callback(function(iw, ip, name)
          if name == nil then return end
          if name == "" then name = default_name end
          local data = deps.workspace.read(opts.workspace)
          local ws, idx = deps.workspace.find(data, name)
          if ws then
            data.workspaces[idx] = { name = name, cwd = cwd, tabs = ws.tabs }
          else
            table.insert(data.workspaces, { name = name, cwd = cwd, lastUsed = os.time() })
          end
          deps.workspace.write(opts.workspace, data)
          toast(iw, string.format(L.ws_registered, name, cwd))
          if not deps.workspace.exists(name) then
            local ws_config = deps.workspace.find(deps.workspace.read(opts.workspace), name)
            deps.workspace.create(ws_config, deps.agent, deps.layout, opts, opts.default_tabs)
          end
          iw:perform_action(act.SwitchToWorkspace({ name = name }), ip)
        end),
      }),
      pane
    )
  end)
end

-- ============== Workspace delete ==============

function M.workspace_delete(window, pane, deps)
  local opts = deps.opts
  local L = opts.labels
  local data = deps.workspace.read(opts.workspace)
  if #data.workspaces == 0 then
    toast(window, L.no_ws_to_delete)
    return
  end

  local active_ws = window:active_workspace()
  local running = {}
  for _, win in ipairs(mux.all_windows()) do
    running[win:get_workspace()] = true
  end

  local default_ws = opts.workspace.default_workspace
  local sorted = deps.workspace.sort(data.workspaces, default_ws)

  local choices = {}
  for _, ws in ipairs(sorted) do
    if ws.name ~= active_ws then
      local is_running = running[ws.name] or false
      local fmt = {}
      build_ws_header(fmt, ws.name, is_running)
      append_ws_status(fmt, ws, is_running, deps)
      table.insert(fmt, { Foreground = { AnsiColor = "Grey" } })
      table.insert(fmt, { Text = "  " .. shorten_path(ws.cwd or "") })
      table.insert(choices, { id = ws.name, label = wezterm.format(fmt) })
    end
  end

  if #choices == 0 then
    toast(window, L.no_deletable_ws)
    return
  end

  window:perform_action(
    act.InputSelector({
      title = L.select_ws_to_delete,
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(iw, ip, id)
        if not id then return end
        local msg = string.format(running[id] and L.confirm_delete_running or L.confirm_delete, id)
        iw:perform_action(
          act.InputSelector({
            title = msg,
            choices = {
              { id = "yes", label = L.yes_delete },
              { id = "no", label = L.no_cancel },
            },
            action = wezterm.action_callback(function(cw, _cp, cid)
              if cid ~= "yes" then return end
              local fresh = deps.workspace.read(opts.workspace)
              local ws = deps.workspace.find(fresh, id)
              local target_cwd = ws and ws.cwd or nil

              local removed_wt = false
              local is_wt = false
              if target_cwd then
                target_cwd = target_cwd:gsub("/$", "")
                local git_root = deps.worktree.get_git_root(target_cwd)
                if git_root and git_root ~= target_cwd then
                  local worktrees = deps.worktree.list(git_root)
                  for _, wt in ipairs(worktrees) do
                    if wt.path == target_cwd then
                      is_wt = true
                      break
                    end
                  end
                  if is_wt then
                    local ok = deps.worktree.remove(git_root, target_cwd, false)
                    if not ok then ok = deps.worktree.remove(git_root, target_cwd, true) end
                    removed_wt = ok
                  end
                end
              end

              if is_wt and not removed_wt then
                toast(cw, string.format(L.wt_remove_failed, id), 5000)
                return
              end

              local new_list = {}
              for _, w in ipairs(fresh.workspaces) do
                if w.name ~= id then table.insert(new_list, w) end
              end
              fresh.workspaces = new_list
              deps.workspace.write(opts.workspace, fresh)
              local m = string.format(L.ws_deleted, id)
              if removed_wt then m = m .. L.ws_deleted_with_wt end
              toast(cw, m)
            end),
          }),
          ip
        )
      end),
    }),
    pane
  )
end

-- ============== Worktree selector (Cmd+Shift+X) ==============

local function switch_to_worktree(window, pane, wt_path, ws_name, deps)
  local opts = deps.opts
  if deps.workspace.exists(ws_name) then
    window:perform_action(act.SwitchToWorkspace({ name = ws_name }), pane)
    return
  end
  local data = deps.workspace.read(opts.workspace)
  if not deps.workspace.find(data, ws_name) then
    table.insert(data.workspaces, { name = ws_name, cwd = wt_path, lastUsed = os.time() })
    deps.workspace.write(opts.workspace, data)
  end
  local ws_config = deps.workspace.find(deps.workspace.read(opts.workspace), ws_name)
  deps.workspace.create(ws_config, deps.agent, deps.layout, opts, opts.default_tabs)
  window:perform_action(act.SwitchToWorkspace({ name = ws_name }), pane)
end

local function create_worktree(window, git_root, branch, is_new, local_name, deps)
  local L = deps.opts.labels
  local_name = local_name or branch
  local ok, wt_path, stderr = deps.worktree.add(git_root, branch, local_name, is_new, deps.opts)
  if not ok then
    local err = stderr and stderr:gsub("%s+$", "") or ""
    local m = string.format(L.wt_create_failed, local_name)
    if err ~= "" then m = m .. "\n" .. err end
    toast(window, m, 5000)
    return nil
  end
  toast(window, string.format(L.wt_created, local_name))
  return wt_path
end

local function create_pr_worktree(window, git_root, number, deps)
  local L = deps.opts.labels
  local branch = "pr-" .. tostring(number)
  local ok, wt_path, stderr = deps.worktree.add_pr_worktree(git_root, number, deps.opts)
  if not ok then
    local err = stderr and stderr:gsub("%s+$", "") or ""
    local m = string.format(L.wt_create_failed, branch)
    if err ~= "" then m = m .. "\n" .. err end
    toast(window, m, 5000)
    return nil
  end
  toast(window, string.format(L.wt_created, branch))
  return wt_path
end

local function create_issue_worktree(window, git_root, number, deps)
  local L = deps.opts.labels
  local branch = "issue-" .. tostring(number)
  local ok, wt_path, stderr = deps.worktree.add_issue_worktree(git_root, number, deps.opts)
  if not ok then
    local err = stderr and stderr:gsub("%s+$", "") or ""
    local m = string.format(L.wt_create_failed, branch)
    if err ~= "" then m = m .. "\n" .. err end
    toast(window, m, 5000)
    return nil
  end
  toast(window, string.format(L.wt_created, branch))
  return wt_path
end

local function open_agent_tab_in_cwd(window, pane, cwd, agent_impl, deps)
  local opts = deps.opts
  deps.layout.add_tab(window, agent_impl and agent_impl.id or nil, deps.workspace, opts)
  if agent_impl then
    local agent_opts = deps.agent.opts_for(agent_impl, opts)
    local args = agent_impl.spawn_args(agent_opts, nil, cwd)
    local env = deps.agent.spawn_env(agent_opts)
    window:perform_action(act.SpawnCommandInNewTab({ args = args, cwd = cwd, set_environment_variables = env }), pane)
  else
    window:perform_action(act.SpawnCommandInNewTab({ cwd = cwd }), pane)
  end
end

local function show_worktree_action_menu(window, pane, wt_path, branch, is_main, base_ws, git_root, cwd_path, deps, pending, pr)
  local L = deps.opts.labels
  local choices = {}
  local agents = deps.agent.all()
  table.insert(choices, { id = "tab:__shell__", label = "\xF3\xB0\x86\x8D shell" })
  if agents[1] then table.insert(choices, { id = "tab:" .. agents[1].id, label = "\xEF\x91\x8A " .. agents[1].display_name }) end
  for i = 2, #agents do
    table.insert(choices, { id = "tab:" .. agents[i].id, label = "\xEF\x91\x8A " .. agents[i].display_name })
  end

  local ws_name = deps.worktree.workspace_name_for(base_ws, branch, is_main)
  local manage = {}
  if pending then
    table.insert(manage, { id = "workspace", label = L.register_ws })
  else
    local in_wt = cwd_path == wt_path or (cwd_path and cwd_path:find(wt_path .. "/", 1, true))
    if not deps.workspace.exists(ws_name) then table.insert(manage, { id = "workspace", label = L.register_ws }) end
    if not is_main and not in_wt then table.insert(manage, { id = "delete", label = L.delete_wt }) end
  end
  if pr then table.insert(manage, { id = "open_pr", label = L.open_pr }) end
  if pending and pending.issue_number then table.insert(manage, { id = "open_issue", label = L.open_issue }) end
  if #manage > 0 then
    table.insert(choices, { id = "_sep_other", label = "── Manage ──" })
    for _, c in ipairs(manage) do
      table.insert(choices, c)
    end
  end

  window:perform_action(
    act.InputSelector({
      title = branch,
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(iw, ip, id)
        if not id or id:match("^_sep_") then return end
        if id == "open_pr" then
          deps.worktree.open_pr_web(git_root, pr.number)
          return
        end
        if id == "open_issue" then
          deps.worktree.open_issue_web(git_root, pending.issue_number)
          return
        end
        if pending then
          if pending.pr_number then
            wt_path = create_pr_worktree(iw, git_root, pending.pr_number, deps)
          elseif pending.issue_number then
            wt_path = create_issue_worktree(iw, git_root, pending.issue_number, deps)
          else
            wt_path = create_worktree(iw, git_root, pending.branch, pending.is_new, pending.local_name, deps)
          end
          if not wt_path then return end
        end
        if id:match("^tab:") then
          local agent_id = id:match("^tab:(.+)$")
          local agent_impl = nil
          if agent_id ~= "__shell__" then agent_impl = deps.agent.get(agent_id) end
          open_agent_tab_in_cwd(iw, ip, wt_path, agent_impl, deps)
          return
        end
        if id == "workspace" then
          switch_to_worktree(iw, ip, wt_path, ws_name, deps)
          return
        end
        if id == "delete" then
          if deps.workspace.exists(ws_name) then
            toast(iw, string.format(L.ws_running_close_first, ws_name), 5000)
            return
          end
          local ok, _, stderr = deps.worktree.remove(git_root, wt_path, false)
          if ok then
            local fresh = deps.workspace.read(deps.opts.workspace)
            local _, idx = deps.workspace.find(fresh, ws_name)
            if idx then
              table.remove(fresh.workspaces, idx)
              deps.workspace.write(deps.opts.workspace, fresh)
            end
            toast(iw, string.format(L.ws_deleted, branch))
          else
            local err = stderr and stderr:gsub("%s+$", "") or ""
            local m = string.format(L.delete_failed, branch)
            if err ~= "" then m = m .. "\n" .. err end
            toast(iw, m, 5000)
          end
          return
        end
      end),
    }),
    pane
  )
end

-- ワークスペース切替を検知し、リポジトリごとに最大1回/30秒で fetch+gh を裏で先読みする。
M.prefetch_state = { ws = nil, last = {} }
function M.maybe_prefetch(window, pane, deps)
  local ws = window:active_workspace()
  if ws == M.prefetch_state.ws then return end
  M.prefetch_state.ws = ws
  local cwd = get_cwd_path(pane)
  if not cwd then return end
  local git_root = deps.worktree.get_git_root(cwd)
  if not git_root then return end
  local now = os.time()
  if (now - (M.prefetch_state.last[git_root] or 0)) < 30 then return end
  M.prefetch_state.last[git_root] = now
  deps.worktree.prefetch(git_root)
end

function M.worktree_selector(window, pane, deps)
  local L = deps.opts.labels
  local cwd_path = get_cwd_path(pane)
  if not cwd_path then
    toast(window, L.cannot_get_cwd)
    return
  end

  local git_root = deps.worktree.get_git_root(cwd_path)
  if not git_root then
    toast(window, L.not_git_repo)
    return
  end

  local base_ws = deps.worktree.base_workspace_name(window)
  local worktrees = deps.worktree.list(git_root)
  local prs = deps.worktree.pull_requests(git_root)
  local issue_map = deps.worktree.issues(git_root)
  local me = deps.worktree.current_user()

  local function pr_marker(branch)
    local pr = prs[branch]
    if not pr then return nil end
    local color = pr.state == "MERGED" and "Purple" or (pr.state == "CLOSED" and "Maroon" or "Green")
    return { { Foreground = { AnsiColor = color } }, { Text = " \xEF\x90\x87 #" .. tostring(pr.number) }, "ResetAttributes" }
  end

  -- linkedBranches 由来の Issue バッジ。命名規約に依存せず、他人が作ったリンクも表示する。
  local function issue_marker(branch)
    local n = issue_map[branch]
    if not n then return nil end
    return { { Foreground = { AnsiColor = "Fuchsia" } }, { Text = " \xEF\x90\x92 #" .. tostring(n) }, "ResetAttributes" }
  end

  -- fmt 配列に PR / Issue バッジを連結する。nil マーカーは飛ばす。
  local function append_markers(fmt, branch)
    for _, m in ipairs({ pr_marker(branch) or false, issue_marker(branch) or false }) do
      if m then
        for _, x in ipairs(m) do
          table.insert(fmt, x)
        end
      end
    end
  end

  local choices = {}
  local has_detached = false
  local has_tmp = false
  local current_branch = nil
  for _, wt in ipairs(worktrees) do
    if not wt.branch then has_detached = true end
    if deps.worktree.is_tmp_branch(wt.branch) then has_tmp = true end
    if wt.branch and (cwd_path == wt.path or (cwd_path and cwd_path:find(wt.path .. "/", 1, true))) then current_branch = wt.branch end
  end

  table.insert(choices, { id = "tmp_create", label = L.tmp_branch_create })
  if has_tmp then table.insert(choices, { id = "cleanup_tmp", label = L.cleanup_tmp }) end
  if has_detached then table.insert(choices, { id = "prune_detached", label = L.prune_detached }) end
  table.insert(choices, { id = "fetch_remote", label = L.fetch_remote })

  table.insert(choices, { id = "_sep_wt", label = "── Worktree ──" })
  for _, wt in ipairs(worktrees) do
    if wt.branch then
      local is_main = (wt.path == git_root)
      local fmt = {}
      table.insert(fmt, { Foreground = { AnsiColor = is_main and "Green" or "Aqua" } })
      table.insert(fmt, { Text = "\xEE\x9C\xA5 " })
      table.insert(fmt, "ResetAttributes")
      table.insert(fmt, { Text = wt.branch })
      append_markers(fmt, wt.branch)
      table.insert(choices, {
        id = "switch:" .. wt.path .. ":" .. wt.branch .. ":" .. tostring(is_main),
        label = wezterm.format(fmt),
      })
    end
  end

  local function branch_label(text, branch)
    if not pr_marker(branch) and not issue_marker(branch) then return "  " .. text end
    local fmt = { { Text = "  " .. text } }
    append_markers(fmt, branch)
    return wezterm.format(fmt)
  end

  local branch_info = deps.worktree.branches(git_root, worktrees)
  if #branch_info.local_branches > 0 then
    table.insert(choices, { id = "_sep_local", label = "── Local Branch ──" })
    for _, b in ipairs(branch_info.local_branches) do
      table.insert(choices, { id = "auto_create:" .. b .. ":" .. b, label = branch_label(b, b) })
    end
  end
  if #branch_info.remote_branches > 0 then
    table.insert(choices, { id = "_sep_remote", label = "── Remote Branch ──" })
    for _, b in ipairs(branch_info.remote_branches) do
      table.insert(choices, { id = "auto_create:" .. b.display .. ":" .. b.local_name, label = branch_label(b.display, b.local_name) })
    end
  end

  local reachable = {}
  for _, wt in ipairs(worktrees) do
    if wt.branch then reachable[wt.branch] = true end
  end
  for _, b in ipairs(branch_info.local_branches) do
    reachable[b] = true
  end
  for _, b in ipairs(branch_info.remote_branches) do
    reachable[b.local_name] = true
  end
  -- 自分が作成 or レビュー依頼された PR を「自分関係」とし、Issue と同じく黄色+先頭に寄せる。
  local pr_list = deps.worktree.relevant_prs(
    deps.worktree.uncovered_prs(deps.worktree.pull_request_list(git_root), reachable, deps.worktree.materialized_prs(git_root)),
    me
  )
  if #pr_list > 0 then
    table.insert(choices, { id = "_sep_pr", label = "── Pull Requests ──" })
    for _, pr in ipairs(pr_list) do
      local text = pr.headRefName
      if pr.owner then text = text .. " (@" .. pr.owner .. ")" end
      local fmt
      if pr.mine then
        fmt = {
          { Foreground = { AnsiColor = "Yellow" } },
          { Text = "\xEF\x90\x87 #" .. tostring(pr.number) .. " " .. text },
          "ResetAttributes",
        }
      else
        local color = pr.state == "MERGED" and "Purple" or (pr.state == "CLOSED" and "Maroon" or "Green")
        fmt = {
          { Foreground = { AnsiColor = color } },
          { Text = "\xEF\x90\x87 #" .. tostring(pr.number) .. " " },
          "ResetAttributes",
          { Text = text },
        }
      end
      table.insert(choices, { id = "pr:" .. tostring(pr.number), label = wezterm.format(fmt) })
    end
  end

  -- リンク済みブランチがローカルに到達可能な Issue は除外し、自分アサインを先頭に寄せる。
  local issues = deps.worktree.relevant_issues(deps.worktree.uncovered_issues(deps.worktree.issue_list(git_root), reachable), me)
  if #issues > 0 then
    table.insert(choices, { id = "_sep_issue", label = "── Issues ──" })
    for _, issue in ipairs(issues) do
      -- 自分アサインは黄色で色付け。非アサインは通常色のまま (先頭ソートと併せて十分見分けられる)。
      local fmt = {}
      if issue.mine then table.insert(fmt, { Foreground = { AnsiColor = "Yellow" } }) end
      table.insert(fmt, { Text = "\xEF\x90\x92 #" .. tostring(issue.number) .. " " .. issue.title })
      if issue.mine then table.insert(fmt, "ResetAttributes") end
      table.insert(choices, { id = "issue:" .. tostring(issue.number), label = wezterm.format(fmt) })
    end
  end

  window:perform_action(
    act.InputSelector({
      title = "Worktree",
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(iw, ip, id)
        if not id then return end

        if id:match("^switch:") then
          local _, wt_path, branch, is_main_str = id:match("^(switch):(.+):([^:]+):([^:]+)$")
          show_worktree_action_menu(iw, ip, wt_path, branch, is_main_str == "true", base_ws, git_root, cwd_path, deps, nil, prs[branch])
          return
        end

        if id:match("^_sep_") then return end

        local pr_num = id:match("^pr:(%d+)$")
        if pr_num then
          local n = tonumber(pr_num)
          local rec
          for _, p in ipairs(pr_list) do
            if p.number == n then
              rec = p
              break
            end
          end
          if rec then
            local pr_branch = "pr-" .. tostring(n)
            show_worktree_action_menu(
              iw,
              ip,
              nil,
              pr_branch,
              false,
              base_ws,
              git_root,
              cwd_path,
              deps,
              { branch = pr_branch, pr_number = n },
              rec
            )
          end
          return
        end

        local issue_num = id:match("^issue:(%d+)$")
        if issue_num then
          local n = tonumber(issue_num)
          local issue_branch = "issue-" .. tostring(n)
          show_worktree_action_menu(
            iw,
            ip,
            nil,
            issue_branch,
            false,
            base_ws,
            git_root,
            cwd_path,
            deps,
            { branch = issue_branch, issue_number = n }
          )
          return
        end

        if id == "fetch_remote" then
          local ok = deps.worktree.fetch(git_root)
          deps.worktree.refresh_pr_cache(git_root)
          deps.worktree.refresh_issue_cache(git_root)
          toast(iw, ok and L.fetch_done or L.fetch_failed)
          M.worktree_selector(iw, ip, deps)
          return
        end

        if id:match("^auto_create:") then
          local ref, local_name = id:match("^auto_create:(.+):([^:]+)$")
          if ref and local_name then
            show_worktree_action_menu(
              iw,
              ip,
              nil,
              local_name,
              false,
              base_ws,
              git_root,
              cwd_path,
              deps,
              { branch = ref, local_name = local_name, is_new = false },
              prs[local_name]
            )
          end
          return
        end

        if id == "tmp_create" then
          local tmp_branch = deps.worktree.generate_tmp_branch_name(current_branch)
          show_worktree_action_menu(
            iw,
            ip,
            nil,
            tmp_branch,
            false,
            base_ws,
            git_root,
            cwd_path,
            deps,
            { branch = tmp_branch, local_name = nil, is_new = true }
          )
          return
        end

        if id == "cleanup_tmp" then
          local removed, failed, skipped = 0, 0, 0
          for _, wt in ipairs(worktrees) do
            if wt.branch and deps.worktree.is_tmp_branch(wt.branch) then
              local ws_name = deps.worktree.workspace_name_for(base_ws, wt.branch, false)
              if deps.workspace.exists(ws_name) then
                skipped = skipped + 1
              else
                local ok = deps.worktree.remove(git_root, wt.path, false)
                if not ok then ok = deps.worktree.remove(git_root, wt.path, true) end
                if ok then
                  deps.worktree.delete_branch(git_root, wt.branch)
                  local fresh = deps.workspace.read(deps.opts.workspace)
                  local _, idx = deps.workspace.find(fresh, ws_name)
                  if idx then
                    table.remove(fresh.workspaces, idx)
                    deps.workspace.write(deps.opts.workspace, fresh)
                  end
                  removed = removed + 1
                else
                  failed = failed + 1
                end
              end
            end
          end
          deps.worktree.prune(git_root)
          local m = string.format(L.tmp_cleanup_result, removed)
          if failed > 0 then m = m .. string.format(L.tmp_cleanup_failed, failed) end
          if skipped > 0 then m = m .. string.format(L.tmp_cleanup_skipped, skipped) end
          toast(iw, m)
          return
        end

        if id == "prune_detached" then
          local removed, failed = 0, 0
          for _, wt in ipairs(worktrees) do
            if not wt.branch then
              local ok = deps.worktree.remove(git_root, wt.path, false)
              if ok then
                removed = removed + 1
              else
                failed = failed + 1
              end
            end
          end
          deps.worktree.prune(git_root)
          local m = string.format(L.prune_result, removed)
          if failed > 0 then m = m .. string.format(L.prune_failed, failed) end
          toast(iw, m)
          return
        end
      end),
    }),
    pane
  )
end

-- ============== Agent selector (Cmd+Shift+Opt+C) ==============

function M.agent_selector(window, pane, deps)
  local opts = deps.opts
  local agents = deps.agent.all()
  local choices = {}
  for _, impl in ipairs(agents) do
    table.insert(choices, { id = impl.id, label = "\xEF\x91\x8A " .. impl.display_name })
  end

  window:perform_action(
    act.InputSelector({
      title = "Agent",
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(iw, ip, id)
        if not id then return end
        local impl = deps.agent.get(id)
        if not impl then return end
        deps.layout.add_tab(iw, impl.id, deps.workspace, opts)
        local agent_opts = deps.agent.opts_for(impl, opts)
        local args = impl.spawn_args(agent_opts)
        local env = deps.agent.spawn_env(agent_opts)
        iw:perform_action(act.SpawnCommandInNewTab({ args = args, set_environment_variables = env }), ip)
      end),
    }),
    pane
  )
end

-- ============== Help (Cmd+Shift+H) ==============

-- Nerd Font: Apple 修飾キー専用グリフ。PUA の単一セルグリフなので桁ずれ・被りが起きない
local nf = wezterm.nerdfonts
local NERD_KEYS = {
  LeftArrow = nf.md_arrow_left_bold,
  RightArrow = nf.md_arrow_right_bold,
  UpArrow = nf.md_arrow_up_bold,
  DownArrow = nf.md_arrow_down_bold,
  Enter = nf.md_keyboard_return,
  Backspace = nf.md_keyboard_backspace,
}
local NERD_MODS = {
  { "CTRL", nf.md_apple_keyboard_control },
  { "OPT", nf.md_apple_keyboard_option },
  { "SHIFT", nf.md_apple_keyboard_shift },
  { "CMD", nf.md_apple_keyboard_command },
}
-- Unicode フォールバック (nerd_font = false 時)。⇧ と矢印は ambiguous width なのでスペースで分離する
local UNICODE_KEYS = {
  LeftArrow = "\xE2\x86\x90", -- ←
  RightArrow = "\xE2\x86\x92", -- →
  UpArrow = "\xE2\x86\x91", -- ↑
  DownArrow = "\xE2\x86\x93", -- ↓
  Enter = "\xE2\x8F\x8E", -- ⏎
  Backspace = "\xE2\x8C\xAB", -- ⌫
}
-- mac 慣習の表示順 (⌃⌥⇧⌘)
local UNICODE_MODS = {
  { "CTRL", "\xE2\x8C\x83" }, -- ⌃
  { "OPT", "\xE2\x8C\xA5" }, -- ⌥
  { "SHIFT", "\xE2\x87\xA7" }, -- ⇧
  { "CMD", "\xE2\x8C\x98" }, -- ⌘
}

local function format_keybind(key, mods, nerd)
  local mod_set = nerd and NERD_MODS or UNICODE_MODS
  local key_set = nerd and NERD_KEYS or UNICODE_KEYS
  local present = {}
  for m in mods:gmatch("[^|]+") do
    present[m] = true
  end
  local parts = {}
  for _, pair in ipairs(mod_set) do
    if present[pair[1]] then
      table.insert(parts, pair[2])
      present[pair[1]] = nil
    end
  end
  for m in mods:gmatch("[^|]+") do
    if present[m] then table.insert(parts, m) end -- 記号未定義の修飾キーはそのまま
  end
  table.insert(parts, key_set[key] or key)
  -- 記号/グリフが詰まって見えないよう間にスペースを挟む
  return table.concat(parts, " ")
end

function M.help_selector(window, pane, deps, items)
  local L = deps.opts.labels
  local choices = {}
  local last_group = nil
  for i, it in ipairs(items) do
    if it.group ~= last_group then
      last_group = it.group
      table.insert(choices, { id = "_sep_" .. i, label = "── " .. (L[it.group] or it.group) .. " ──" })
    end
    local fmt = {
      { Attribute = { Intensity = "Bold" } },
      { Foreground = { AnsiColor = "Aqua" } },
      { Text = format_keybind(it.key, it.mods, deps.opts.nerd_font) },
      "ResetAttributes",
      { Text = "  " .. (L[it.desc] or it.desc) },
    }
    table.insert(choices, { id = "item:" .. i, label = wezterm.format(fmt) })
  end

  window:perform_action(
    act.InputSelector({
      title = "Help",
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(iw, ip, id)
        if not id or id:match("^_sep_") then return end
        local i = tonumber(id:match("^item:(%d+)$"))
        local it = i and items[i]
        if it and it.runnable and it.action then iw:perform_action(it.action, ip) end
      end),
    }),
    pane
  )
end

-- ============== Keybinds factory ==============

local function is_last_window_in_workspace(window)
  local ws = window:mux_window():get_workspace()
  local n = 0
  for _, w in ipairs(mux.all_windows()) do
    if w:get_workspace() == ws then n = n + 1 end
  end
  return n <= 1
end
local function is_last_tab(window) return #window:mux_window():tabs() <= 1 end
local function is_last_pane(window) return #window:mux_window():active_tab():panes() <= 1 end

function M.build_keybinds(deps)
  local opts = deps.opts
  local keys = {}
  local help_items = {}
  local disabled = {}
  for _, k in ipairs(opts.disabled_keybinds or {}) do
    disabled[k] = true
  end

  local overrides = opts.keybinds or {}
  local prefix = opts.modifier_prefix or "CMD"
  local overridden = {}

  local function add(id, entry, help)
    if disabled[id] then return end
    if prefix ~= "CMD" then entry.mods = entry.mods:gsub("CMD", prefix) end
    local ov = overrides[id]
    if ov then
      if overridden[id] then return end
      overridden[id] = true
      entry.key = ov.key or entry.key
      entry.mods = ov.mods or entry.mods
    end
    table.insert(keys, entry)
    if help then
      table.insert(help_items, {
        group = help.group,
        desc = help.desc,
        runnable = help.runnable or false,
        key = entry.key,
        mods = entry.mods,
        action = entry.action,
      })
    end
  end

  -- 注意: help_items は help 付き add の呼び出し順で並ぶ。ヘルプの表示順 = ここでの記述順
  -- Workspace & Agent
  add("workspace_selector", {
    key = "S",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(w, p) M.workspace_selector(w, p, deps) end),
  }, { group = "help_group_main", desc = "help_workspace", runnable = true })

  local default_agent = opts.default_agent and deps.agent.get(opts.default_agent) or deps.agent.all()[1]
  if default_agent then
    add("agent_spawn", {
      key = "C",
      mods = "CMD|SHIFT",
      action = wezterm.action_callback(function(window, pane)
        deps.layout.add_tab(window, default_agent.id, deps.workspace, opts)
        local agent_opts = deps.agent.opts_for(default_agent, opts)
        local args = default_agent.spawn_args(agent_opts)
        local env = deps.agent.spawn_env(agent_opts)
        window:perform_action(act.SpawnCommandInNewTab({ args = args, set_environment_variables = env }), pane)
      end),
    }, { group = "help_group_main", desc = "help_agent_spawn", runnable = true })
  end

  add("agent_selector", {
    key = "A",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane) M.agent_selector(window, pane, deps) end),
  }, { group = "help_group_main", desc = "help_agent_selector", runnable = true })

  add("open_editor", {
    key = "E",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      local editor = detect_gui_editor(opts.default_editor)
      if not editor then
        toast(window, opts.labels.no_editor_found)
        return
      end
      local cwd = get_cwd_path(pane)
      if not cwd then
        toast(window, opts.labels.cannot_get_cwd)
        return
      end
      wezterm.background_child_process({ editor, cwd })
    end),
  }, { group = "help_group_main", desc = "help_open_editor", runnable = true })

  add("worktree_selector", {
    key = "X",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(w, p) M.worktree_selector(w, p, deps) end),
  }, { group = "help_group_main", desc = "help_worktree", runnable = true })

  -- Tab & Pane (with workspace sync)
  add("new_tab", {
    key = "t",
    mods = "CMD",
    action = wezterm.action_callback(function(window, pane)
      deps.layout.add_tab(window, nil, deps.workspace, opts)
      window:perform_action(act.SpawnTab("CurrentPaneDomain"), pane)
    end),
  }, { group = "help_group_tab", desc = "help_new_tab" })

  add("close_tab", {
    key = "w",
    mods = "CMD",
    action = wezterm.action_callback(function(window, pane)
      if is_last_window_in_workspace(window) and is_last_tab(window) then return end
      deps.layout.remove_tab(window, deps.workspace, opts)
      window:perform_action(act.CloseCurrentTab({ confirm = false }), pane)
    end),
  }, { group = "help_group_tab", desc = "help_close_tab" })

  add(
    "next_tab",
    { key = "RightArrow", mods = "CMD|SHIFT", action = act.ActivateTabRelative(1) },
    { group = "help_group_tab", desc = "help_next_tab" }
  )
  add(
    "prev_tab",
    { key = "LeftArrow", mods = "CMD|SHIFT", action = act.ActivateTabRelative(-1) },
    { group = "help_group_tab", desc = "help_prev_tab" }
  )

  local function move_tab(direction)
    return wezterm.action_callback(function(window, pane)
      deps.layout.move_tab(window, direction, deps.workspace, opts)
      window:perform_action(act.MoveTabRelative(direction), pane)
    end)
  end
  add("move_tab_left", { key = "[", mods = "CMD|SHIFT", action = move_tab(-1) }, { group = "help_group_tab", desc = "help_move_tab_left" })
  add("move_tab_left", { key = "{", mods = "CMD|SHIFT", action = move_tab(-1) })
  add("move_tab_right", { key = "]", mods = "CMD|SHIFT", action = move_tab(1) }, { group = "help_group_tab", desc = "help_move_tab_right" })
  add("move_tab_right", { key = "}", mods = "CMD|SHIFT", action = move_tab(1) })

  add("split_right", {
    key = "/",
    mods = "CMD|OPT",
    action = wezterm.action_callback(function(window, pane)
      deps.layout.add_split(window, pane, "right", deps.workspace, opts)
      window:perform_action(act.SplitHorizontal({ domain = "CurrentPaneDomain" }), pane)
    end),
  }, { group = "help_group_tab", desc = "help_split_right" })
  add("split_bottom", {
    key = "-",
    mods = "CMD|OPT",
    action = wezterm.action_callback(function(window, pane)
      deps.layout.add_split(window, pane, "bottom", deps.workspace, opts)
      window:perform_action(act.SplitVertical({ domain = "CurrentPaneDomain" }), pane)
    end),
  }, { group = "help_group_tab", desc = "help_split_bottom" })

  add("close_pane", {
    key = "w",
    mods = "CMD|OPT",
    action = wezterm.action_callback(function(window, pane)
      if is_last_window_in_workspace(window) and is_last_tab(window) and is_last_pane(window) then return end
      if is_last_pane(window) then deps.layout.remove_tab(window, deps.workspace, opts) end
      window:perform_action(act.CloseCurrentPane({ confirm = false }), pane)
      if not is_last_pane(window) then
        wezterm.time.call_after(0.1, function() pcall(deps.layout.refresh_after_pane_close, window, deps.workspace, opts) end)
      end
    end),
  }, { group = "help_group_tab", desc = "help_close_pane" })

  -- Window
  add("pin_toggle", {
    key = "P",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      local L = opts.labels
      local id = tostring(window:window_id())
      if M.pinned_windows[id] then
        M.pinned_windows[id] = nil
        window:perform_action(act.SetWindowLevel("Normal"), pane)
        toast(window, L.pin_off, 2000)
      else
        M.pinned_windows[id] = true
        window:perform_action(act.SetWindowLevel("AlwaysOnTop"), pane)
        toast(window, L.pin_on, 2000)
      end
    end),
  }, { group = "help_group_window", desc = "help_pin_toggle", runnable = true })

  -- Help (keybind cheatsheet, generated from the bindings above)
  add("help", {
    key = "H",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane) M.help_selector(window, pane, deps, help_items) end),
  }, { group = "help_group_window", desc = "help_help" })

  -- ヘルプに表示しないキー (パススルー / ナビゲーション / 行編集)
  add("disable_quit", { key = "q", mods = "CMD", action = act.Nop }) -- CMD+Q 誤操作防止
  add("opt_enter", { key = "Enter", mods = "OPT", action = act.SendKey({ key = "Enter", mods = "OPT" }) })

  add("activate_pane_left", { key = "LeftArrow", mods = "CMD|OPT", action = act.ActivatePaneDirection("Left") })
  add("activate_pane_right", { key = "RightArrow", mods = "CMD|OPT", action = act.ActivatePaneDirection("Right") })
  add("activate_pane_up", { key = "UpArrow", mods = "CMD|OPT", action = act.ActivatePaneDirection("Up") })
  add("activate_pane_down", { key = "DownArrow", mods = "CMD|OPT", action = act.ActivatePaneDirection("Down") })

  add("scroll_to_top", { key = "UpArrow", mods = "CMD", action = act.ScrollToTop })
  add("scroll_to_bottom", { key = "DownArrow", mods = "CMD", action = act.ScrollToBottom })
  add("scroll_page_up", { key = "UpArrow", mods = "OPT", action = act.ScrollByPage(-1) })
  add("scroll_page_down", { key = "DownArrow", mods = "OPT", action = act.ScrollByPage(1) })

  add("line_start", { key = "LeftArrow", mods = "CMD", action = act.SendKey({ key = "a", mods = "CTRL" }) })
  add("line_end", { key = "RightArrow", mods = "CMD", action = act.SendKey({ key = "e", mods = "CTRL" }) })
  add("line_delete", { key = "Backspace", mods = "CMD", action = act.SendKey({ key = "u", mods = "CTRL" }) })

  return keys
end

return M
