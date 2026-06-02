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

-- PRキャッシュの保存先 base。状態ファイルと同一の XDG_STATE_HOME 配下 (名前空間なし) に集約する。
-- init.lua の default_status_dir / hooks のフォールバックと同一規則 (素朴連結) で揃える。
local function cache_base()
  local base = os.getenv("XDG_STATE_HOME")
  if not base or base == "" then base = wezterm.home_dir .. "/.local/state" end
  return base .. "/wezterm-ai-agents"
end

local function pr_cache_file(git_root) return cache_base() .. "/wezterm-pr-" .. git_root:gsub("[^%w]", "_") .. ".json" end

local function issue_cache_file(git_root) return cache_base() .. "/wezterm-issue-" .. git_root:gsub("[^%w]", "_") .. ".json" end

-- 自分の login キャッシュ。Issue の assignee 強調用 (リポジトリ非依存なので 1 ファイルに集約)。
local function gh_user_cache_file() return cache_base() .. "/wezterm-gh-user" end

local GH_PR_LIST = "gh pr list --json number,headRefName,state,isCrossRepository,headRepositoryOwner --limit 200"

-- Issue は linkedBranches (GitHub 公式の Issue↔ブランチリンク) ごと GraphQL で引く。
-- これを反転して「ブランチ→Issue番号」マップを作れば、命名規約に依存せずリネーム済みや
-- 他人が作ったリンクも認識できる (PR の branch.<name>.merge 刻印に相当する真実のソース)。
local GH_ISSUE_QUERY = "query($owner:String!,$name:String!){repository(owner:$owner,name:$name){"
  .. "issues(first:100,states:OPEN,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{"
  .. "number title assignees(first:10){nodes{login}} linkedBranches(first:10){nodes{ref{name}}}}}}}"
local GH_ISSUE_LIST = 'gh api graphql -F owner="$(gh repo view --json owner --jq .owner.login)" '
  .. '-F name="$(gh repo view --json name --jq .name)" -f query=\''
  .. GH_ISSUE_QUERY
  .. "'"

-- gh の一覧取得をキャッシュファイルへアトミックに書き出すシェルコマンドを組み立てる。
-- 書き込み先 base を mkdir -p で保証する。io.open 経路と違いシェルの `> リダイレクト` 生成なので、
-- base 不在だとリダイレクトの時点で失敗する。前置しないと初回ワークスペース切替でキャッシュが作られない。
local function bg_cache_cmd(git_root, list_cmd, cache)
  local tmp = shq(cache .. ".tmp")
  return ("mkdir -p %s && cd %s && %s > %s 2>/dev/null && mv %s %s"):format(
    shq(cache_base()),
    shq(git_root),
    list_cmd,
    tmp,
    tmp,
    shq(cache)
  )
end

-- ワークスペース切替時に呼ぶ。git fetch と gh pr/issue list を裏で並列実行 (UI 非ブロッキング)。
-- gh の結果はキャッシュファイルへ書き出し、worktree 画面はそれを読むだけにする。
function M.prefetch(git_root)
  wezterm.background_child_process({ "git", "-C", git_root, "fetch", "--prune" })
  wezterm.background_child_process({ "/bin/sh", "-lc", bg_cache_cmd(git_root, GH_PR_LIST, pr_cache_file(git_root)) })
  wezterm.background_child_process({ "/bin/sh", "-lc", bg_cache_cmd(git_root, GH_ISSUE_LIST, issue_cache_file(git_root)) })
  -- 自分の login (assignee 強調用、無ければ取得)。
  local login = shq(gh_user_cache_file())
  local user_cmd = ("mkdir -p %s && { test -s %s || gh api user --jq .login > %s 2>/dev/null; }"):format(shq(cache_base()), login, login)
  wezterm.background_child_process({ "/bin/sh", "-lc", user_cmd })
end

-- 手動 fetch 用にキャッシュを即時更新する共通処理。gh を同期実行して書き出す。
local function refresh_cache(git_root, list_cmd, cache)
  local ok, stdout = wezterm.run_child_process({ "/bin/sh", "-lc", "cd " .. shq(git_root) .. " && " .. list_cmd .. " 2>/dev/null" })
  if ok and stdout and stdout ~= "" then
    pcall(wezterm.run_child_process, { "mkdir", "-p", cache_base() })
    local f = io.open(cache, "w")
    if f then
      f:write(stdout)
      f:close()
    end
  end
end

-- 手動 fetch 用。gh を同期実行してキャッシュを即時更新する。
function M.refresh_pr_cache(git_root) refresh_cache(git_root, GH_PR_LIST, pr_cache_file(git_root)) end

function M.refresh_issue_cache(git_root) refresh_cache(git_root, GH_ISSUE_LIST, issue_cache_file(git_root)) end

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

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local raw = f:read("*a")
  f:close()
  return raw or ""
end

-- キャッシュから open PR の配列を返す。
function M.pull_request_list(git_root) return M.parse_pr_list(read_file(pr_cache_file(git_root))) end

-- GraphQL 生 JSON を [{ number, title, assignees={login,...}, linked_branches={name,...} }] に変換する純関数。
function M.parse_issue_list(raw)
  if not raw or raw == "" then return {} end
  local ok, data = pcall(wezterm.json_parse, raw)
  if not ok or type(data) ~= "table" then return {} end
  local repo = data.data and data.data.repository
  local nodes = repo and repo.issues and repo.issues.nodes
  if type(nodes) ~= "table" then return {} end
  local list = {}
  for _, issue in ipairs(nodes) do
    if issue.number and issue.title then
      local assignees = {}
      local an = type(issue.assignees) == "table" and issue.assignees.nodes
      if type(an) == "table" then
        for _, a in ipairs(an) do
          if type(a) == "table" and a.login then table.insert(assignees, a.login) end
        end
      end
      local branches = {}
      local ln = type(issue.linkedBranches) == "table" and issue.linkedBranches.nodes
      if type(ln) == "table" then
        for _, b in ipairs(ln) do
          if type(b) == "table" and type(b.ref) == "table" and b.ref.name then table.insert(branches, b.ref.name) end
        end
      end
      table.insert(list, { number = issue.number, title = issue.title, assignees = assignees, linked_branches = branches })
    end
  end
  return list
end

-- キャッシュから open Issue の配列を返す。
function M.issue_list(git_root) return M.parse_issue_list(read_file(issue_cache_file(git_root))) end

-- linkedBranches を反転した { [branch] = number } マップを返す。worktree/branch のバッジ表示用。
function M.issues(git_root)
  local map = {}
  for _, issue in ipairs(M.issue_list(git_root)) do
    for _, name in ipairs(issue.linked_branches or {}) do
      map[name] = issue.number
    end
  end
  return map
end

-- リンク済みブランチがローカルに到達可能な Issue を除外する純関数。
-- reachable: 画面に出ているブランチ名集合 (worktree/local/remote)。
-- 主軸は GitHub の linkedBranches (リネーム・他人作成に追従)。issue-<N> 命名は
-- gh issue develop 直後でキャッシュ未更新でも消えるようにするフォールバック。
function M.uncovered_issues(issue_list, reachable)
  reachable = reachable or {}
  local out = {}
  for _, issue in ipairs(issue_list) do
    local covered = reachable["issue-" .. tostring(issue.number)] and true or false
    if not covered then
      for _, name in ipairs(issue.linked_branches or {}) do
        if reachable[name] then
          covered = true
          break
        end
      end
    end
    if not covered then table.insert(out, issue) end
  end
  return out
end

-- 自分の login を返す (assignee 強調用)。未取得なら nil。
function M.current_user()
  local login = read_file(gh_user_cache_file()):gsub("%s+$", "")
  if login == "" then return nil end
  return login
end

-- git config の branch.<name>.merge=refs/pull/<N>/head 刻印を { [branch] = number } で返す。
-- gh pr checkout / add_pr_worktree が刻んだ印を読み、ブランチ名に依存せず PR を逆引きする。
function M.pr_branch_config(git_root)
  local out = {}
  local ok, stdout = wezterm.run_child_process({ "git", "-C", git_root, "config", "--get-regexp", "^branch\\..*\\.merge$" })
  if not ok or not stdout then return out end
  for line in stdout:gmatch("[^\n]+") do
    local key, val = line:match("^(%S+)%s+(.+)$")
    local number = val and val:match("^refs/pull/(%d+)/head$")
    local branch = key and key:match("^branch%.(.+)%.merge$")
    if number and branch then out[branch] = tonumber(number) end
  end
  return out
end

-- 刻印から「ローカルに取り込み済みの PR 番号」の集合 { [number] = true } を返す。
function M.materialized_prs(git_root)
  local out = {}
  for _, number in pairs(M.pr_branch_config(git_root)) do
    out[number] = true
  end
  return out
end

-- { [branch] = { number, state } } のマップを返す。バッジ/番号引き用。
-- 主軸は git config 刻印 (branch.<name>.merge) による PR 番号逆引き (ブランチ名非依存)。
-- 同一リポ PR はブランチが PR の head そのものなので headRefName でも引ける。
function M.pull_requests(git_root)
  local map = {}
  local by_number = {}
  for _, pr in ipairs(M.pull_request_list(git_root)) do
    local rec = { number = pr.number, state = pr.state }
    by_number[pr.number] = rec
    map[pr.headRefName] = rec
  end
  for branch, number in pairs(M.pr_branch_config(git_root)) do
    if by_number[number] then map[branch] = by_number[number] end
  end
  return map
end

-- ブランチとして到達できない PR (主に fork) だけを返す純関数。
-- reachable: 既に画面に出ているブランチ名の集合 (worktree/local/remote)。
-- materialized: 刻印で取り込み済みの PR 番号集合 { [number] = true } (ブランチ名非依存)。
function M.uncovered_prs(pr_list, reachable, materialized)
  materialized = materialized or {}
  local out = {}
  for _, pr in ipairs(pr_list) do
    local taken = materialized[pr.number] -- 刻印で取り込み済み
    local shown_as_branch = not pr.fork and reachable[pr.headRefName] -- 同一リポPRで既出
    if not taken and not shown_as_branch then table.insert(out, pr) end
  end
  return out
end

-- PR の head を pr-<N> ローカルブランチとして取り寄せ、worktree を作る。
-- gh pr checkout と同じく branch.<name>.merge=refs/pull/N/head を刻み、ブランチ名に依存せず PR を逆引きできるようにする。
function M.add_pr_worktree(git_root, number, opts)
  local branch = "pr-" .. tostring(number)
  local refspec = ("pull/%d/head:%s"):format(number, branch)
  local ok, _, stderr = wezterm.run_child_process({ "git", "-C", git_root, "fetch", "origin", refspec })
  if not ok then return false, nil, stderr end
  wezterm.run_child_process({ "git", "-C", git_root, "config", ("branch.%s.remote"):format(branch), "origin" })
  wezterm.run_child_process({ "git", "-C", git_root, "config", ("branch.%s.merge"):format(branch), ("refs/pull/%d/head"):format(number) })
  local template = (opts and opts.worktree and opts.worktree.path) or "sibling"
  local wt_path = M.resolve_path(template, git_root, branch)
  local ok2, _, stderr2 = wezterm.run_child_process({ "git", "-C", git_root, "worktree", "add", wt_path, branch })
  return ok2, wt_path, stderr2
end

-- Issue から issue-<N> ブランチを生やして worktree を作る。
-- gh issue develop で origin にブランチを作成し Issue に開発ブランチとしてリンクを刻む
-- (= その branch から出した PR が Issue に自動で紐づき、マージで Issue が自動クローズされる)。
-- リモートに作られるため fetch してから worktree add する 2 段構え。
function M.add_issue_worktree(git_root, number, opts)
  local branch = "issue-" .. tostring(number)
  local cmd = ("cd %s && gh issue develop %d --name %s"):format(shq(git_root), number, shq(branch))
  local ok, _, stderr = wezterm.run_child_process({ "/bin/sh", "-lc", cmd })
  if not ok then return false, nil, stderr end
  local ok_f, _, stderr_f = wezterm.run_child_process({ "git", "-C", git_root, "fetch", "origin", branch })
  if not ok_f then return false, nil, stderr_f end
  local template = (opts and opts.worktree and opts.worktree.path) or "sibling"
  local wt_path = M.resolve_path(template, git_root, branch)
  local ok2, _, stderr2 =
    wezterm.run_child_process({ "git", "-C", git_root, "worktree", "add", "--track", "-b", branch, wt_path, "origin/" .. branch })
  return ok2, wt_path, stderr2
end

-- PR をブラウザで開く (fire-and-forget)。
function M.open_pr_web(git_root, number)
  local cmd = ("cd %s && gh pr view --web %d"):format(shq(git_root), number)
  wezterm.background_child_process({ "/bin/sh", "-lc", cmd })
end

-- Issue をブラウザで開く (fire-and-forget)。
function M.open_issue_web(git_root, number)
  local cmd = ("cd %s && gh issue view --web %d"):format(shq(git_root), number)
  wezterm.background_child_process({ "/bin/sh", "-lc", cmd })
end

return M
