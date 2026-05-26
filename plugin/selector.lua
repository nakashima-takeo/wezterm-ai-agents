-- Selector UIs and keybinds for workspace + worktree management.
-- All public functions take `deps` (injected modules) to avoid cyclic loads.
--   deps = { workspace, layout, worktree, agent, opts }

local wezterm = require("wezterm")
local mux = wezterm.mux
local act = wezterm.action

local M = {}

-- ============== Helpers ==============

local function get_cwd_path(pane)
  local cwd = pane:get_current_working_dir()
  if not cwd then return nil end
  return cwd.file_path or tostring(cwd):gsub("^file://[^/]*", "")
end

local function toast(window, msg, ms) window:toast_notification("WezTerm", msg, nil, ms or 3000) end

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

local CHIP_STATE_ORDER = { "working", "waiting", "done", "idle" }

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

  -- Unregistered running workspaces (insert first)
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

  for _, ws in ipairs(sorted) do
    local is_running = existing[ws.name] or false
    local fmt = {}
    build_ws_header(fmt, ws.name, is_running)
    append_ws_status(fmt, ws, is_running, deps)
    table.insert(choices, { id = "ws:" .. ws.name, label = wezterm.format(fmt) })
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

function M.workspace_register(window, pane, deps)
  local opts = deps.opts
  local L = opts.labels
  local cwd_path = get_cwd_path(pane)
  if not cwd_path then
    toast(window, L.cannot_get_cwd)
    return
  end

  local default_name = cwd_path:gsub("/$", ""):match("([^/]+)$") or ""

  window:perform_action(
    act.PromptInputLine({
      description = string.format(L.enter_ws_name, default_name),
      action = wezterm.action_callback(function(iw, ip, name)
        if name == nil then return end
        if name == "" then name = default_name end
        iw:perform_action(
          act.PromptInputLine({
            description = L.enter_cwd,
            initial_value = cwd_path,
            action = wezterm.action_callback(function(cw, _cp, cwd)
              if not cwd or cwd == "" then return end
              cwd = cwd:gsub("/$", "")
              local data = deps.workspace.read(opts.workspace)
              local ws, idx = deps.workspace.find(data, name)
              if ws then
                data.workspaces[idx] = { name = name, cwd = cwd, tabs = ws.tabs }
              else
                table.insert(data.workspaces, { name = name, cwd = cwd, lastUsed = os.time() })
              end
              deps.workspace.write(opts.workspace, data)
              toast(cw, string.format(L.ws_registered, name, cwd))
            end),
          }),
          ip
        )
      end),
    }),
    pane
  )
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
                local git_root = deps.worktree.get_git_root(target_cwd)
                if git_root and git_root ~= target_cwd then
                  is_wt = true
                  local ok = deps.worktree.remove(git_root, target_cwd, false)
                  if not ok then ok = deps.worktree.remove(git_root, target_cwd, true) end
                  removed_wt = ok
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

local function show_worktree_action_menu(window, pane, wt_path, branch, is_main, base_ws, git_root, cwd_path, deps, pending)
  local L = deps.opts.labels
  local choices = {}
  local agents = deps.agent.all()
  table.insert(choices, { id = "_sep_tab", label = "── Tab ──" })
  table.insert(choices, { id = "tab:__shell__", label = "\xF3\xB0\x86\x8D shell" })
  if agents[1] then table.insert(choices, { id = "tab:" .. agents[1].id, label = "\xEF\x91\x8A " .. agents[1].display_name }) end
  for i = 2, #agents do
    table.insert(choices, { id = "tab:" .. agents[i].id, label = "\xEF\x91\x8A " .. agents[i].display_name })
  end

  local ws_name = deps.worktree.workspace_name_for(base_ws, branch, is_main)
  if pending then
    table.insert(choices, { id = "_sep_other", label = "── Manage ──" })
    table.insert(choices, { id = "workspace", label = L.register_ws })
  else
    local in_wt = cwd_path == wt_path or (cwd_path and cwd_path:find(wt_path .. "/", 1, true))
    local has_other = not deps.workspace.exists(ws_name) or (not is_main and not in_wt)
    if has_other then
      table.insert(choices, { id = "_sep_other", label = "── Manage ──" })
      if not deps.workspace.exists(ws_name) then table.insert(choices, { id = "workspace", label = L.register_ws }) end
      if not is_main and not in_wt then table.insert(choices, { id = "delete", label = L.delete_wt }) end
    end
  end

  window:perform_action(
    act.InputSelector({
      title = branch,
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(iw, ip, id)
        if not id or id:match("^_sep_") then return end
        if pending then
          wt_path = create_worktree(iw, git_root, pending.branch, pending.is_new, pending.local_name, deps)
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

  table.insert(choices, { id = "_sep_wt", label = "── Worktree ──" })
  for _, wt in ipairs(worktrees) do
    if wt.branch then
      local is_main = (wt.path == git_root)
      local fmt = {}
      table.insert(fmt, { Foreground = { AnsiColor = is_main and "Green" or "Aqua" } })
      table.insert(fmt, { Text = "\xEE\x9C\xA5 " })
      table.insert(fmt, "ResetAttributes")
      table.insert(fmt, { Text = wt.branch })
      table.insert(choices, {
        id = "switch:" .. wt.path .. ":" .. wt.branch .. ":" .. tostring(is_main),
        label = wezterm.format(fmt),
      })
    end
  end

  local branch_info = deps.worktree.branches(git_root, worktrees)
  if #branch_info.local_branches > 0 then
    table.insert(choices, { id = "_sep_local", label = "── Local Branch ──" })
    for _, b in ipairs(branch_info.local_branches) do
      table.insert(choices, { id = "auto_create:" .. b .. ":" .. b, label = "  " .. b })
    end
  end
  if #branch_info.remote_branches > 0 then
    table.insert(choices, { id = "_sep_remote", label = "── Remote Branch ──" })
    for _, b in ipairs(branch_info.remote_branches) do
      table.insert(choices, { id = "auto_create:" .. b.display .. ":" .. b.local_name, label = "  " .. b.display })
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
          show_worktree_action_menu(iw, ip, wt_path, branch, is_main_str == "true", base_ws, git_root, cwd_path, deps)
          return
        end

        if id:match("^_sep_") then return end

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
              { branch = ref, local_name = local_name, is_new = false }
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
  local disabled = {}
  for _, k in ipairs(opts.disabled_keybinds or {}) do
    disabled[k] = true
  end

  local overrides = opts.keybinds or {}
  local prefix = opts.modifier_prefix or "CMD"
  local overridden = {}

  local function add(id, entry)
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
  end

  add("workspace_selector", {
    key = "S",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(w, p) M.workspace_selector(w, p, deps) end),
  })
  add("worktree_selector", {
    key = "X",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(w, p) M.worktree_selector(w, p, deps) end),
  })

  -- Default agent spawn
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
    })
  end

  -- Agent selector
  add("agent_selector", {
    key = "A",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane) M.agent_selector(window, pane, deps) end),
  })

  -- Open editor
  add("open_editor", {
    key = "E",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      local L = opts.labels
      local editor = opts.default_editor or os.getenv("VISUAL") or os.getenv("EDITOR")
      if not editor then
        toast(window, L.no_editor_found)
        return
      end
      local cwd = get_cwd_path(pane)
      if not cwd then
        toast(window, L.cannot_get_cwd)
        return
      end
      wezterm.background_child_process({ editor, cwd })
    end),
  })

  -- Tab management with workspace sync
  add("new_tab", {
    key = "t",
    mods = "CMD",
    action = wezterm.action_callback(function(window, pane)
      deps.layout.add_tab(window, nil, deps.workspace, opts)
      window:perform_action(act.SpawnTab("CurrentPaneDomain"), pane)
    end),
  })
  local function move_tab(direction)
    return wezterm.action_callback(function(window, pane)
      deps.layout.move_tab(window, direction, deps.workspace, opts)
      window:perform_action(act.MoveTabRelative(direction), pane)
    end)
  end
  add("move_tab_left", { key = "[", mods = "CMD|SHIFT", action = move_tab(-1) })
  add("move_tab_left", { key = "{", mods = "CMD|SHIFT", action = move_tab(-1) })
  add("move_tab_right", { key = "]", mods = "CMD|SHIFT", action = move_tab(1) })
  add("move_tab_right", { key = "}", mods = "CMD|SHIFT", action = move_tab(1) })

  add("close_tab", {
    key = "w",
    mods = "CMD",
    action = wezterm.action_callback(function(window, pane)
      if is_last_window_in_workspace(window) and is_last_tab(window) then return end
      deps.layout.remove_tab(window, deps.workspace, opts)
      window:perform_action(act.CloseCurrentTab({ confirm = false }), pane)
    end),
  })
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
  })

  add("split_right", {
    key = "/",
    mods = "CMD|OPT",
    action = wezterm.action_callback(function(window, pane)
      deps.layout.add_split(window, pane, "right", deps.workspace, opts)
      window:perform_action(act.SplitHorizontal({ domain = "CurrentPaneDomain" }), pane)
    end),
  })
  add("split_bottom", {
    key = "-",
    mods = "CMD|OPT",
    action = wezterm.action_callback(function(window, pane)
      deps.layout.add_split(window, pane, "bottom", deps.workspace, opts)
      window:perform_action(act.SplitVertical({ domain = "CurrentPaneDomain" }), pane)
    end),
  })

  return keys
end

return M
