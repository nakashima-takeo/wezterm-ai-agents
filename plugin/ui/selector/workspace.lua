-- Workspace selector / register / delete UIs.
-- Shared formatting helpers come from selector/ui.lua (injected via setup()).

local wezterm = require("wezterm")
local mux = wezterm.mux
local act = wezterm.action

local M = {}

local ui

-- selector/init.lua から共有 UI ヘルパー (selector/ui.lua) を注入する。
function M.setup(ui_mod) ui = ui_mod end

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
    ui.build_ws_header(fmt, ws.name, is_running)
    ui.append_ws_status(fmt, ws, is_running, deps)
    table.insert(choices, { id = "ws:" .. ws.name, label = wezterm.format(fmt) })
  end

  -- Unregistered running workspaces (default at top, others at bottom)
  local unregistered = {}
  for name, _ in pairs(existing) do
    if not deps.workspace.find(data, name) then table.insert(unregistered, name) end
  end
  for _, name in ipairs(unregistered) do
    local fmt = {}
    ui.build_ws_header(fmt, name, true)
    ui.append_agents_colored(fmt, deps, name)
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
      { Text = string.format(L.dir_select_here, ui.shorten_path(dir)) },
      "ResetAttributes",
    }),
  })
  if dir ~= "/" then table.insert(choices, { id = "_up", label = L.dir_go_up }) end
  table.insert(choices, { id = "_mkdir", label = L.dir_make_new })
  for _, name in ipairs(ui.list_subdirs(dir)) do
    table.insert(choices, { id = "dir:" .. name, label = folder_icon .. " " .. name })
  end

  window:perform_action(
    act.InputSelector({
      title = string.format(L.dir_picker_title, ui.shorten_path(dir)),
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(iw, ip, id)
        if not id then return end
        if id == "_select" then
          on_select(dir)
        elseif id == "_up" then
          pick_directory(iw, ip, ui.parent_dir(dir), L, folder_icon, on_select)
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
                  ui.toast(w2, string.format(L.mkdir_failed, newname))
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
  local cwd_path = deps.workspace.get_cwd_path(pane)
  if not cwd_path then
    ui.toast(window, L.cannot_get_cwd)
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
          ui.toast(iw, string.format(L.ws_registered, name, cwd))
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
    ui.toast(window, L.no_ws_to_delete)
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
      ui.build_ws_header(fmt, ws.name, is_running)
      ui.append_ws_status(fmt, ws, is_running, deps)
      table.insert(fmt, { Foreground = { AnsiColor = "Grey" } })
      table.insert(fmt, { Text = "  " .. ui.shorten_path(ws.cwd or "") })
      table.insert(choices, { id = ws.name, label = wezterm.format(fmt) })
    end
  end

  if #choices == 0 then
    ui.toast(window, L.no_deletable_ws)
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
                ui.toast(cw, string.format(L.wt_remove_failed, id), 5000)
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
              ui.toast(cw, m)
            end),
          }),
          ip
        )
      end),
    }),
    pane
  )
end

return M
