-- Git worktree integration.
-- Pure git operations; UI/keybinds live in selector.lua.

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

-- POSIX シングルクォートエスケープ (gh を cwd 指定で動かすため sh -lc に渡す)
local function shq(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function pr_cache_file(git_root)
  local dir = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "")
  return dir .. "/wezterm-pr-" .. git_root:gsub("[^%w]", "_") .. ".json"
end

local GH_PR_LIST = "gh pr list --json number,headRefName,state,isCrossRepository,headRepositoryOwner --limit 200"

-- ワークスペース切替時に呼ぶ。git fetch と gh pr list を裏で並列実行 (UI 非ブロッキング)。
-- gh の結果はキャッシュファイルへ書き出し、worktree 画面はそれを読むだけにする。
function M.prefetch(git_root)
  wezterm.background_child_process({ "git", "-C", git_root, "fetch", "--prune" })
  local cache = pr_cache_file(git_root)
  local tmp = shq(cache .. ".tmp")
  local cmd = ("cd %s && %s > %s 2>/dev/null && mv %s %s"):format(shq(git_root), GH_PR_LIST, tmp, tmp, shq(cache))
  wezterm.background_child_process({ "/bin/sh", "-lc", cmd })
end

-- 手動 fetch 用。gh を同期実行してキャッシュを即時更新する。
function M.refresh_pr_cache(git_root)
  local ok, stdout = wezterm.run_child_process({ "/bin/sh", "-lc", "cd " .. shq(git_root) .. " && " .. GH_PR_LIST .. " 2>/dev/null" })
  if ok and stdout and stdout ~= "" then
    local f = io.open(pr_cache_file(git_root), "w")
    if f then
      f:write(stdout)
      f:close()
    end
  end
end

-- 生 JSON を正規化した配列 [{ number, headRefName, state, fork, owner }] に変換する純関数。
function M.parse_pr_list(raw)
  if not raw or raw == "" then return {} end
  local ok, data = pcall(wezterm.json_parse, raw)
  if not ok or type(data) ~= "table" then return {} end
  local list = {}
  for _, pr in ipairs(data) do
    if pr.number and pr.headRefName then
      table.insert(list, {
        number = pr.number,
        headRefName = pr.headRefName,
        state = pr.state,
        fork = pr.isCrossRepository == true,
        owner = type(pr.headRepositoryOwner) == "table" and pr.headRepositoryOwner.login or nil,
      })
    end
  end
  return list
end

local function read_pr_cache(git_root)
  local f = io.open(pr_cache_file(git_root), "r")
  if not f then return "" end
  local raw = f:read("*a")
  f:close()
  return raw or ""
end

-- キャッシュから open PR の配列を返す。
function M.pull_request_list(git_root) return M.parse_pr_list(read_pr_cache(git_root)) end

-- キャッシュから { [branch] = { number, state } } のマップを返す。バッジ/番号引き用。
function M.pull_requests(git_root)
  local map = {}
  for _, pr in ipairs(M.pull_request_list(git_root)) do
    map[pr.headRefName] = { number = pr.number, state = pr.state }
  end
  return map
end

-- ブランチとして到達できない PR (主に fork) だけを返す純関数。
-- reachable: 既に画面に出ているブランチ名の集合 (worktree/local/remote)。
function M.uncovered_prs(pr_list, reachable)
  local out = {}
  for _, pr in ipairs(pr_list) do
    local materialized = reachable["pr-" .. tostring(pr.number)] -- pr-<N> 取り込み済み
    local shown_as_branch = not pr.fork and reachable[pr.headRefName] -- 同一リポPRで既出
    if not materialized and not shown_as_branch then table.insert(out, pr) end
  end
  return out
end

-- PR の head を pr-<N> ローカルブランチとして取り寄せ、worktree を作る。
function M.add_pr_worktree(git_root, number, opts)
  local branch = "pr-" .. tostring(number)
  local refspec = ("pull/%d/head:%s"):format(number, branch)
  local ok, _, stderr = wezterm.run_child_process({ "git", "-C", git_root, "fetch", "origin", refspec })
  if not ok then return false, nil, stderr end
  local template = (opts and opts.worktree and opts.worktree.path) or "sibling"
  local wt_path = M.resolve_path(template, git_root, branch)
  local ok2, _, stderr2 = wezterm.run_child_process({ "git", "-C", git_root, "worktree", "add", wt_path, branch })
  return ok2, wt_path, stderr2
end

-- PR をブラウザで開く (fire-and-forget)。
function M.open_pr_web(git_root, number)
  local cmd = ("cd %s && gh pr view --web %d"):format(shq(git_root), number)
  wezterm.background_child_process({ "/bin/sh", "-lc", cmd })
end

return M
