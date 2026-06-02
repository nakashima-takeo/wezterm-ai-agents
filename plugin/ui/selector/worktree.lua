-- Worktree selector + PR/Issue integration + background prefetch.
-- Shared formatting helpers come from selector/ui.lua (injected via setup()).

local wezterm = require("wezterm")
local act = wezterm.action

local M = {}

local ui

-- selector/init.lua から共有 UI ヘルパー (selector/ui.lua) を注入する。
function M.setup(ui_mod) ui = ui_mod end

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
    ui.toast(window, m, 5000)
    return nil
  end
  ui.toast(window, string.format(L.wt_created, local_name))
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
    ui.toast(window, m, 5000)
    return nil
  end
  ui.toast(window, string.format(L.wt_created, branch))
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
    ui.toast(window, m, 5000)
    return nil
  end
  ui.toast(window, string.format(L.wt_created, branch))
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
            ui.toast(iw, string.format(L.ws_running_close_first, ws_name), 5000)
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
            ui.toast(iw, string.format(L.ws_deleted, branch))
          else
            local err = stderr and stderr:gsub("%s+$", "") or ""
            local m = string.format(L.delete_failed, branch)
            if err ~= "" then m = m .. "\n" .. err end
            ui.toast(iw, m, 5000)
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
  local cwd = deps.workspace.get_cwd_path(pane)
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
  local cwd_path = deps.workspace.get_cwd_path(pane)
  if not cwd_path then
    ui.toast(window, L.cannot_get_cwd)
    return
  end

  local git_root = deps.worktree.get_git_root(cwd_path)
  if not git_root then
    ui.toast(window, L.not_git_repo)
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
          ui.toast(iw, ok and L.fetch_done or L.fetch_failed)
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
          ui.toast(iw, m)
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
          ui.toast(iw, m)
          return
        end
      end),
    }),
    pane
  )
end

return M
