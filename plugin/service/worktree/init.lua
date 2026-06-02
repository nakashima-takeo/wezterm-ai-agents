-- Local git worktree management: discovery, branch listing, add/remove/prune,
-- path templating, tmp/workspace naming. GitHub integration (PR/Issue) lives in
-- worktree/github.lua and is injected + re-exported via setup() so callers keep
-- using a single `worktree` facade (deps.worktree.X).

local wezterm = require("wezterm")

local M = {}

local PRESETS = {
  sibling = "{parent}/{repo}__worktrees/{branch}",
  subdirectory = "{git_root}/.worktrees/{branch}",
}

local TMP_BRANCH_PREFIX = "tmp/"

function M.tmp_branch_prefix() return TMP_BRANCH_PREFIX end

function M.generate_tmp_branch_name(base_branch)
  local base = base_branch and (base_branch .. "/") or ""
  return TMP_BRANCH_PREFIX .. base .. os.date("%Y%m%d-%H%M%S")
end

function M.is_tmp_branch(branch) return branch ~= nil and branch:sub(1, #TMP_BRANCH_PREFIX) == TMP_BRANCH_PREFIX end

-- gsub の置換文字列では % が特殊扱いされるため、置換値の % を %% にエスケープする
local function esc(s) return (s:gsub("%%", "%%%%")) end

function M.resolve_path(template, git_root, branch)
  local repo = git_root:match("([^/]+)$") or "repo"
  local parent = git_root:match("^(.+)/[^/]+$") or git_root
  local safe_branch = branch:gsub("/", "-")
  local pattern = PRESETS[template] or template
  return (
    pattern:gsub("{git_root}", esc(git_root)):gsub("{parent}", esc(parent)):gsub("{repo}", esc(repo)):gsub("{branch}", esc(safe_branch))
  )
end

function M.get_git_root(cwd)
  local ok, stdout = wezterm.run_child_process({
    "git",
    "-C",
    cwd,
    "rev-parse",
    "--path-format=absolute",
    "--git-common-dir",
  })
  if ok and stdout then
    local common_dir = stdout:gsub("%s+$", "")
    if common_dir:match("/.git$") then return common_dir:gsub("/.git$", "") end
  end

  local ok2, stdout2 = wezterm.run_child_process({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
  if ok2 and stdout2 and stdout2 ~= "" then return stdout2:gsub("%s+$", "") end
  return nil
end

function M.list(git_root)
  local ok, stdout = wezterm.run_child_process({ "git", "-C", git_root, "worktree", "list", "--porcelain" })
  if not ok or not stdout then return {} end

  local trees = {}
  local cur = {}
  for line in stdout:gmatch("[^\n]*") do
    if line:match("^worktree ") then
      if cur.path then table.insert(trees, cur) end
      cur = { path = line:match("^worktree (.+)") }
    elseif line:match("^branch ") then
      cur.branch = line:match("^branch refs/heads/(.+)")
    end
  end
  if cur.path then table.insert(trees, cur) end
  return trees
end

function M.branches(git_root, worktrees)
  local used = {}
  for _, wt in ipairs(worktrees) do
    if wt.branch then used[wt.branch] = true end
  end

  local local_branches = {}
  local local_set = {}
  local ok_l, out_l = wezterm.run_child_process({
    "git",
    "-C",
    git_root,
    "branch",
    "--format=%(refname:short)",
  })
  if ok_l and out_l then
    for line in out_l:gmatch("[^\n]+") do
      local b = line:gsub("^%s+", ""):gsub("%s+$", "")
      if b ~= "" then
        local_set[b] = true
        if not used[b] then table.insert(local_branches, b) end
      end
    end
  end

  local remote_branches = {}
  local ok_r, out_r = wezterm.run_child_process({
    "git",
    "-C",
    git_root,
    "branch",
    "-r",
    "--format=%(refname:short)",
  })
  if ok_r and out_r then
    for line in out_r:gmatch("[^\n]+") do
      local b = line:gsub("^%s+", ""):gsub("%s+$", "")
      if b ~= "" and not b:match("/HEAD$") then
        local local_name = b:match("^[^/]+/(.+)$")
        if local_name and not used[local_name] and not local_set[local_name] then
          table.insert(remote_branches, { display = b, local_name = local_name })
        end
      end
    end
  end

  return { local_branches = local_branches, remote_branches = remote_branches }
end

function M.base_workspace_name(window)
  local ws = window:active_workspace()
  return ws:match("^([^/]+)/") or ws
end

function M.workspace_name_for(base_ws, branch, is_main)
  if is_main then return base_ws end
  return base_ws .. "/" .. branch
end

function M.add(git_root, branch, local_name, is_new_branch, opts)
  local template = (opts and opts.worktree and opts.worktree.path) or "sibling"
  local wt_path = M.resolve_path(template, git_root, local_name or branch)
  local ok, _, stderr
  if is_new_branch then
    ok, _, stderr = wezterm.run_child_process({ "git", "-C", git_root, "worktree", "add", "-b", branch, wt_path })
  elseif local_name and local_name ~= branch then
    ok, _, stderr = wezterm.run_child_process({ "git", "-C", git_root, "worktree", "add", "-b", local_name, wt_path, branch })
  else
    ok, _, stderr = wezterm.run_child_process({ "git", "-C", git_root, "worktree", "add", wt_path, branch })
  end
  return ok, wt_path, stderr
end

function M.remove(git_root, wt_path, force)
  local args = { "git", "-C", git_root, "worktree", "remove" }
  if force then table.insert(args, "--force") end
  table.insert(args, wt_path)
  return wezterm.run_child_process(args)
end

function M.delete_branch(git_root, branch) wezterm.run_child_process({ "git", "-C", git_root, "branch", "-D", branch }) end

function M.prune(git_root) wezterm.run_child_process({ "git", "-C", git_root, "worktree", "prune" }) end

function M.fetch(git_root) return wezterm.run_child_process({ "git", "-C", git_root, "fetch", "--prune" }) end

-- github(PR/Issue 連携) を結線する。init.lua から呼ばれる。
-- github に自身(core: resolve_path 等)を渡し、github の公開関数(M.*)を総なめで再エクスポートして単一ファサードを保つ。
-- 手動列挙だと github への関数追加時に追記漏れで実行時 nil 参照になるため、ドリフトを構造的に排除する。
function M.setup(github)
  github.setup(M)
  for k, v in pairs(github) do
    if type(v) == "function" and k ~= "setup" then M[k] = v end
  end
end

return M
