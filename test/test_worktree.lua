package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test = H.test

H.section("worktreeパス解決")

test("siblingプリセット：親ディレクトリに__worktreesで配置される", function()
  local worktree = H.load_worktree()

  H.assert_eq(worktree.resolve_path("sibling", "/home/user/myproject", "feature-x"), "/home/user/myproject__worktrees/feature-x")
end)

test("subdirectoryプリセット：リポジトリ内.worktreesに配置される", function()
  local worktree = H.load_worktree()

  H.assert_eq(worktree.resolve_path("subdirectory", "/home/user/myproject", "feature-x"), "/home/user/myproject/.worktrees/feature-x")
end)

test("カスタムテンプレート：全変数が展開される", function()
  local worktree = H.load_worktree()

  H.assert_eq(worktree.resolve_path("{parent}/{repo}.{branch}", "/home/user/myproject", "feature-x"), "/home/user/myproject.feature-x")
end)

test("カスタムテンプレート：集中管理ディレクトリ", function()
  local worktree = H.load_worktree()

  H.assert_eq(worktree.resolve_path("/tmp/worktrees/{repo}/{branch}", "/home/user/myproject", "hotfix"), "/tmp/worktrees/myproject/hotfix")
end)

test("ブランチ名のスラッシュはハイフンに変換される", function()
  local worktree = H.load_worktree()

  H.assert_eq(worktree.resolve_path("sibling", "/home/user/repo", "feature/auth/login"), "/home/user/repo__worktrees/feature-auth-login")
end)

test("git_root変数がテンプレートで使える", function()
  local worktree = H.load_worktree()

  H.assert_eq(worktree.resolve_path("{git_root}/.wt/{branch}", "/home/user/repo", "dev"), "/home/user/repo/.wt/dev")
end)

test("ブランチ名の%がエスケープされて消えない", function()
  local worktree = H.load_worktree()

  H.assert_eq(worktree.resolve_path("sibling", "/home/user/repo", "fix%20bug"), "/home/user/repo__worktrees/fix%20bug")
end)

test("git_rootの%でクラッシュせず正しく展開される", function()
  local worktree = H.load_worktree()

  H.assert_eq(worktree.resolve_path("sibling", "/home/user/100%done", "dev"), "/home/user/100%done__worktrees/dev")
end)

H.section("worktree add のパス生成")

test("addはデフォルト(sibling)でパスを生成する", function()
  local worktree = H.load_worktree()
  local captured_args
  local original = wezterm.run_child_process
  wezterm.run_child_process = function(args)
    captured_args = args
    return true, "", ""
  end

  local ok, wt_path = worktree.add("/home/user/repo", "feature-x", "feature-x", false, {})

  wezterm.run_child_process = original
  H.assert_true(ok)
  H.assert_eq(wt_path, "/home/user/repo__worktrees/feature-x")
  H.assert_eq(captured_args[#captured_args - 1], wt_path)
  H.assert_eq(captured_args[#captured_args], "feature-x")
end)

test("addはopts.worktree.pathでプリセットを切り替える", function()
  local worktree = H.load_worktree()
  local original = wezterm.run_child_process
  wezterm.run_child_process = function() return true, "", "" end

  local _, wt_path = worktree.add("/home/user/repo", "fix", "fix", false, { worktree = { path = "subdirectory" } })

  wezterm.run_child_process = original
  H.assert_eq(wt_path, "/home/user/repo/.worktrees/fix")
end)

test("addはカスタムテンプレートを受け入れる", function()
  local worktree = H.load_worktree()
  local original = wezterm.run_child_process
  wezterm.run_child_process = function() return true, "", "" end

  local _, wt_path = worktree.add("/home/user/repo", "dev", "dev", false, { worktree = { path = "/tmp/wt/{repo}/{branch}" } })

  wezterm.run_child_process = original
  H.assert_eq(wt_path, "/tmp/wt/repo/dev")
end)

test("addはoptsなしでもsiblingにフォールバックする", function()
  local worktree = H.load_worktree()
  local original = wezterm.run_child_process
  wezterm.run_child_process = function() return true, "", "" end

  local _, wt_path = worktree.add("/home/user/repo", "main", "main", false, nil)

  wezterm.run_child_process = original
  H.assert_eq(wt_path, "/home/user/repo__worktrees/main")
end)

test("addは先頭ハイフンのブランチ名を拒否しgitを呼ばない", function()
  local worktree = H.load_worktree()
  local called = false
  local original = wezterm.run_child_process
  wezterm.run_child_process = function()
    called = true
    return true, "", ""
  end

  local ok, wt_path, err = worktree.add("/home/user/repo", "-x", nil, true, {})

  wezterm.run_child_process = original
  H.assert_false(ok, "先頭ハイフンのブランチ名は拒否される")
  H.assert_nil(wt_path, "拒否時はパスを返さない")
  H.assert_match(err, "leading hyphen", "拒否理由を返す")
  H.assert_false(called, "拒否時は git を呼ばない")
end)

test("addはlocal_nameの先頭ハイフンも拒否する", function()
  local worktree = H.load_worktree()
  local original = wezterm.run_child_process
  wezterm.run_child_process = function() return true, "", "" end

  local ok = worktree.add("/home/user/repo", "feature", "-evil", false, {})

  wezterm.run_child_process = original
  H.assert_false(ok, "local_name の先頭ハイフンも拒否される")
end)

H.section("ワークスペース名の導出")

test("正常系：非mainブランチは「ベース名/ブランチ名」形式になる", function()
  local worktree = H.load_worktree()

  H.assert_eq(worktree.workspace_name_for("myproject", "feature-x", false), "myproject/feature-x")
end)

test("正常系：mainブランチはベース名そのものになる", function()
  local worktree = H.load_worktree()

  H.assert_eq(worktree.workspace_name_for("myproject", "main", true), "myproject")
end)

test("正常系：スラッシュを含むブランチ名もそのまま保持される", function()
  local worktree = H.load_worktree()

  H.assert_eq(worktree.workspace_name_for("proj", "feat/auth/login", false), "proj/feat/auth/login")
end)

H.section("ベースワークスペース名の抽出")

test("正常系：worktree形式のワークスペース名から最初のセグメントを抽出する", function()
  local worktree = H.load_worktree()
  local win = { active_workspace = function() return "myproject/feature-x" end }

  H.assert_eq(worktree.base_workspace_name(win), "myproject")
end)

test("正常系：スラッシュなしのワークスペース名はそのまま返す", function()
  local worktree = H.load_worktree()
  local win = { active_workspace = function() return "simple-project" end }

  H.assert_eq(worktree.base_workspace_name(win), "simple-project")
end)

H.section("worktree listのパース")

test("正常系：porcelain出力からworktreeのパスとブランチを取得できる", function()
  local worktree = H.load_worktree()
  local porcelain = table.concat({
    "worktree /home/user/repo",
    "HEAD abc1234def5678",
    "branch refs/heads/main",
    "",
    "worktree /home/user/repo/.worktrees/feature-auth",
    "HEAD 1234567890abcdef",
    "branch refs/heads/feature-auth",
    "",
  }, "\n")
  local original = wezterm.run_child_process
  wezterm.run_child_process = function() return true, porcelain end

  local trees = worktree.list("/home/user/repo")

  wezterm.run_child_process = original
  H.assert_eq(#trees, 2)
  H.assert_eq(trees[1].path, "/home/user/repo")
  H.assert_eq(trees[1].branch, "main")
  H.assert_eq(trees[2].path, "/home/user/repo/.worktrees/feature-auth")
  H.assert_eq(trees[2].branch, "feature-auth")
end)

test("正常系：detached HEADのworktreeはbranchがnilになる", function()
  local worktree = H.load_worktree()
  local porcelain = table.concat({
    "worktree /home/user/repo/.worktrees/detached",
    "HEAD abc1234def5678",
    "detached",
    "",
  }, "\n")
  local original = wezterm.run_child_process
  wezterm.run_child_process = function() return true, porcelain end

  local trees = worktree.list("/dummy")

  wezterm.run_child_process = original
  H.assert_eq(#trees, 1)
  H.assert_eq(trees[1].path, "/home/user/repo/.worktrees/detached")
  H.assert_nil(trees[1].branch)
end)

test("異常系：gitコマンド失敗時は空リストを返す", function()
  local worktree = H.load_worktree()
  local original = wezterm.run_child_process
  wezterm.run_child_process = function() return false, nil end

  local trees = worktree.list("/dummy")

  wezterm.run_child_process = original
  H.assert_eq(#trees, 0)
end)

H.section("get_git_rootの二段フォールバック")

test("正常系：git-common-dir が /repo/.git を返すと /.git を剥がして /repo を返す", function()
  local worktree = H.load_worktree()
  local original = wezterm.run_child_process
  wezterm.run_child_process = function(args)
    for _, a in ipairs(args) do
      if a == "--git-common-dir" then return true, "/home/user/repo/.git\n" end
    end
    return false, nil
  end

  local root = worktree.get_git_root("/home/user/repo/.worktrees/x")

  wezterm.run_child_process = original
  H.assert_eq(root, "/home/user/repo")
end)

test("正常系：git-common-dir 失敗時は show-toplevel にフォールバックする", function()
  local worktree = H.load_worktree()
  local original = wezterm.run_child_process
  wezterm.run_child_process = function(args)
    for _, a in ipairs(args) do
      if a == "--git-common-dir" then return false, nil end
      if a == "--show-toplevel" then return true, "/home/user/repo\n" end
    end
    return false, nil
  end

  local root = worktree.get_git_root("/dummy")

  wezterm.run_child_process = original
  H.assert_eq(root, "/home/user/repo")
end)

test("異常系：両方失敗時は nil を返す", function()
  local worktree = H.load_worktree()
  local original = wezterm.run_child_process
  wezterm.run_child_process = function() return false, nil end

  local root = worktree.get_git_root("/dummy")

  wezterm.run_child_process = original
  H.assert_nil(root)
end)

H.section("branchesの収集と重複排除")

test(
  "正常系：使用中ブランチ除外・リモート専用のみ抽出・origin/HEAD除外・ローカル同名重複排除",
  function()
    local worktree = H.load_worktree()
    local original = wezterm.run_child_process
    -- `-r` の有無でローカル/リモートの出力を出し分ける
    wezterm.run_child_process = function(args)
      for _, a in ipairs(args) do
        if a == "-r" then return true, "origin/HEAD\norigin/main\norigin/dev\norigin/release\n" end
      end
      return true, "main\nfeature-x\ndev\n"
    end

    -- feature-x は worktree 使用中
    local result = worktree.branches("/dummy", { { branch = "feature-x" } })

    wezterm.run_child_process = original

    -- ローカル: 使用中の feature-x を除外し main/dev のみ
    H.assert_eq(#result.local_branches, 2)
    H.assert_eq(result.local_branches[1], "main")
    H.assert_eq(result.local_branches[2], "dev")

    -- リモート: origin/HEAD は除外、origin/main・origin/dev はローカル同名で重複排除、
    -- リモート専用の origin/release だけ残る
    H.assert_eq(#result.remote_branches, 1)
    H.assert_eq(result.remote_branches[1].display, "origin/release")
    H.assert_eq(result.remote_branches[1].local_name, "release")
  end
)

H.section("一時ブランチ名")

test("正常系：派生元ブランチ名を含むtmp/プレフィックスで日時形式の名前を生成する", function()
  local worktree = H.load_worktree()

  local name = worktree.generate_tmp_branch_name("main")
  H.assert_match(name, "^tmp/main/%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d$")

  local name_no_base = worktree.generate_tmp_branch_name(nil)
  H.assert_match(name_no_base, "^tmp/%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d$")
end)

test("正常系：tmp/で始まるブランチ名を一時ブランチと判定する", function()
  local worktree = H.load_worktree()

  H.assert_true(worktree.is_tmp_branch("tmp/20260525-143022"))
  H.assert_true(worktree.is_tmp_branch("tmp/anything"))
  H.assert_false(worktree.is_tmp_branch("feature/tmp"))
  H.assert_false(worktree.is_tmp_branch("main"))
  H.assert_false(worktree.is_tmp_branch(nil))
end)

H.section("PRリストのパース")

test("parse_pr_listはforkとownerを正規化する", function()
  local worktree = H.load_worktree()
  local raw = [[
    [
      {"number":12,"headRefName":"feat/x","state":"OPEN","isCrossRepository":true,"headRepositoryOwner":{"login":"alice"}},
      {"number":10,"headRefName":"feat/y","state":"OPEN","isCrossRepository":false,"headRepositoryOwner":{"login":"bob"}}
    ]
  ]]
  local list = worktree.parse_pr_list(raw)

  H.assert_eq(#list, 2)
  H.assert_eq(list[1].number, 12)
  H.assert_eq(list[1].headRefName, "feat/x")
  H.assert_true(list[1].fork)
  H.assert_eq(list[1].owner, "alice")
  H.assert_false(list[2].fork)
  H.assert_eq(list[2].owner, "bob")
end)

test("parse_pr_listは空・不正入力で空配列を返す", function()
  local worktree = H.load_worktree()

  H.assert_eq(#worktree.parse_pr_list(""), 0)
  H.assert_eq(#worktree.parse_pr_list(nil), 0)
  H.assert_eq(#worktree.parse_pr_list("not json"), 0)
end)

test("parse_pr_listはauthorとreviewRequests(Userのみ)を正規化する", function()
  local worktree = H.load_worktree()
  local raw = [[
    [
      {"number":9,"headRefName":"feat/z","state":"OPEN","isCrossRepository":false,
       "author":{"login":"me"},
       "reviewRequests":[{"__typename":"User","login":"rev1"},{"__typename":"Team","name":"core","slug":"core"}]}
    ]
  ]]
  local list = worktree.parse_pr_list(raw)

  H.assert_eq(list[1].author, "me")
  H.assert_eq(#list[1].review_requests, 1) -- Team は login が無いので除外
  H.assert_eq(list[1].review_requests[1], "rev1")
end)

test("pull_requestsはキャッシュからheadRefName→{number,state}のmapを返す", function()
  local worktree = H.load_worktree()
  local git_root = "/tmp/__wt_pr_map_test"
  -- パス導出は production の公開関数を使う (キー規則の二重管理を避ける)。base 不在だと write が落ちるため mkdir -p。
  local cache = worktree.pr_cache_file(git_root)
  os.execute("mkdir -p '" .. cache:match("^(.*)/[^/]+$") .. "'")
  H.write_file(cache, '[{"number":7,"headRefName":"feat/a","state":"OPEN","isCrossRepository":false}]')

  local map = worktree.pull_requests(git_root)

  os.remove(cache)
  H.assert_eq(map["feat/a"].number, 7)
  H.assert_eq(map["feat/a"].state, "OPEN")
  H.assert_nil(map["feat/b"])
end)

test("pr_branch_configはbranch.<name>.merge刻印からPR番号を逆引きする", function()
  local worktree = H.load_worktree()
  local original = wezterm.run_child_process
  wezterm.run_child_process = function()
    return true, "branch.pr-12.merge refs/pull/12/head\nbranch.my-fix.merge refs/pull/9/head\nbranch.main.merge refs/heads/main\n"
  end

  local cfg = worktree.pr_branch_config("/tmp/x")

  wezterm.run_child_process = original
  H.assert_eq(cfg["pr-12"], 12)
  H.assert_eq(cfg["my-fix"], 9) -- リネーム済みでも刻印で逆引きできる
  H.assert_nil(cfg["main"]) -- refs/pull 以外は無視
end)

test("pull_requestsはconfig刻印でブランチ名非依存に紐づける", function()
  local worktree = H.load_worktree()
  local git_root = "/tmp/__wt_pr_cfg_test"
  local cache = worktree.pr_cache_file(git_root)
  os.execute("mkdir -p '" .. cache:match("^(.*)/[^/]+$") .. "'")
  H.write_file(cache, '[{"number":12,"headRefName":"feat/fork","state":"OPEN","isCrossRepository":true}]')
  local original = wezterm.run_child_process
  wezterm.run_child_process = function() return true, "branch.renamed.merge refs/pull/12/head\n" end

  local map = worktree.pull_requests(git_root)

  wezterm.run_child_process = original
  os.remove(cache)
  H.assert_eq(map["renamed"].number, 12) -- 刻印で別名ブランチでも紐づく
  H.assert_nil(map["feat/fork"]) -- fork の headRefName は登録しない (同名ローカルブランチへの誤爆防止)
  H.assert_nil(map["pr-12"]) -- pr-N 名照合は廃止
end)

test("materialized_prsは刻印から取り込み済みPR番号集合を返す", function()
  local worktree = H.load_worktree()
  local original = wezterm.run_child_process
  wezterm.run_child_process = function() return true, "branch.pr-12.merge refs/pull/12/head\nbranch.main.merge refs/heads/main\n" end

  local set = worktree.materialized_prs("/tmp/x")

  wezterm.run_child_process = original
  H.assert_true(set[12])
  H.assert_nil(set[99])
end)

H.section("到達不能PRの抽出")

test("uncovered_prs：fork PRはheadRefNameがローカル同名でも残す", function()
  local worktree = H.load_worktree()
  local list = {
    { number = 12, headRefName = "feat/x", fork = true },
    { number = 10, headRefName = "feat/y", fork = false },
    { number = 20, headRefName = "main", fork = true },
  }
  local reachable = { ["feat/y"] = true, ["main"] = true }

  local out = worktree.uncovered_prs(list, reachable)

  H.assert_eq(#out, 2)
  H.assert_eq(out[1].number, 12)
  H.assert_eq(out[2].number, 20)
end)

test("uncovered_prs：刻印で取り込み済みのPR番号は除外する", function()
  local worktree = H.load_worktree()
  local list = { { number = 12, headRefName = "feat/x", fork = true } }

  H.assert_eq(#worktree.uncovered_prs(list, {}, { [12] = true }), 0)
end)

test("uncovered_prs：リネームしてもブランチ名に依存せず番号で除外する", function()
  local worktree = H.load_worktree()
  local list = { { number = 12, headRefName = "feat/x", fork = true } }
  -- 取り込んだブランチを my-fix にリネーム済み (pr-12 名は存在しない)
  H.assert_eq(#worktree.uncovered_prs(list, { ["my-fix"] = true }, { [12] = true }), 0)
end)

test("uncovered_prs：同一リポでもブランチ未到達なら含める", function()
  local worktree = H.load_worktree()
  local list = { { number = 5, headRefName = "gone", fork = false } }

  H.assert_eq(#worktree.uncovered_prs(list, {}), 1)
end)

H.section("PR worktreeの作成")

test("add_pr_worktree：fetchしてpr-Nのworktreeを作る", function()
  local worktree = H.load_worktree()
  local calls = {}
  local original = wezterm.run_child_process
  wezterm.run_child_process = function(args)
    table.insert(calls, args)
    return true, "", ""
  end

  local ok, wt_path = worktree.add_pr_worktree("/home/user/repo", 12, {})

  wezterm.run_child_process = original
  H.assert_true(ok)
  H.assert_eq(wt_path, "/home/user/repo__worktrees/pr-12")
  H.assert_eq(#calls, 4)
  H.assert_eq(calls[1][#calls[1] - 2], "fetch")
  H.assert_eq(calls[1][#calls[1] - 1], "origin")
  H.assert_eq(calls[1][#calls[1]], "pull/12/head:pr-12")
  -- gh pr checkout 同等の刻印 (ブランチ名に依存しない PR 逆引き用)
  H.assert_eq(calls[2][#calls[2] - 1], "branch.pr-12.remote")
  H.assert_eq(calls[2][#calls[2]], "origin")
  H.assert_eq(calls[3][#calls[3] - 1], "branch.pr-12.merge")
  H.assert_eq(calls[3][#calls[3]], "refs/pull/12/head")
  H.assert_eq(calls[4][#calls[4] - 1], "/home/user/repo__worktrees/pr-12")
  H.assert_eq(calls[4][#calls[4]], "pr-12")
end)

test("add_pr_worktree：fetch失敗時はworktree addしない", function()
  local worktree = H.load_worktree()
  local calls = {}
  local original = wezterm.run_child_process
  wezterm.run_child_process = function(args)
    table.insert(calls, args)
    return false, "", "network error"
  end

  local ok = worktree.add_pr_worktree("/home/user/repo", 12, {})

  wezterm.run_child_process = original
  H.assert_false(ok)
  H.assert_eq(#calls, 1)
end)

test("open_pr_web：gh pr view --web をログインシェルで投げる", function()
  local worktree = H.load_worktree()
  local captured
  local original = wezterm.background_child_process
  wezterm.background_child_process = function(args) captured = args end

  worktree.open_pr_web("/home/user/repo", 12)

  wezterm.background_child_process = original
  H.assert_eq(captured[1], "/bin/sh")
  H.assert_eq(captured[2], "-lc")
  H.assert_match(captured[3], "gh pr view %-%-web 12")
  H.assert_match(captured[3], "/home/user/repo")
end)

test(
  "prefetch：PRキャッシュコマンドが mkdir -p 前置・アトミック書き出し・gh フィールド列を含む",
  function()
    local worktree = H.load_worktree()
    local cmds = {}
    local original = wezterm.background_child_process
    wezterm.background_child_process = function(args)
      if args[1] == "/bin/sh" then table.insert(cmds, args[3]) end
    end

    worktree.prefetch("/home/user/repo")

    wezterm.background_child_process = original

    -- PR キャッシュ書き出しコマンド (gh pr list を含むもの) を特定
    local pr_cmd
    for _, c in ipairs(cmds) do
      if c:match("gh pr list") then pr_cmd = c end
    end
    H.assert_true(pr_cmd ~= nil)
    -- base 不在でもリダイレクトが失敗しないための mkdir -p 前置 (回帰しやすい不変条件)
    H.assert_match(pr_cmd, "^mkdir %-p ")
    H.assert_match(pr_cmd, "wezterm%-pr%-")
    -- tmp へ書いてから mv するアトミック書き出し
    H.assert_match(pr_cmd, "%.tmp")
    H.assert_match(pr_cmd, "&& mv ")
    -- gh の --json フィールド列が落ちていないこと
    H.assert_match(pr_cmd, "headRefName")
    H.assert_match(pr_cmd, "reviewRequests")
  end
)

H.section("Issueリストのパース")

local function issue_graphql(nodes_json) return '{"data":{"repository":{"issues":{"nodes":' .. nodes_json .. "}}}}" end

test("parse_issue_listはGraphQLからnumber/title/assignees/linkedBranchesを正規化する", function()
  local worktree = H.load_worktree()
  local raw = issue_graphql([[
    [
      {"number":5,"title":"バグ修正","assignees":{"nodes":[{"login":"alice"},{"login":"bob"}]},
       "linkedBranches":{"nodes":[{"ref":{"name":"fix/login"}}]}},
      {"number":3,"title":"機能追加","assignees":{"nodes":[]},"linkedBranches":{"nodes":[]}}
    ]
  ]])
  local list = worktree.parse_issue_list(raw)

  H.assert_eq(#list, 2)
  H.assert_eq(list[1].number, 5)
  H.assert_eq(list[1].title, "バグ修正")
  H.assert_eq(list[1].assignees[1], "alice")
  H.assert_eq(list[1].assignees[2], "bob")
  H.assert_eq(list[1].linked_branches[1], "fix/login")
  H.assert_eq(#list[2].assignees, 0)
  H.assert_eq(#list[2].linked_branches, 0)
end)

test("parse_issue_listは空・不正入力で空配列を返す", function()
  local worktree = H.load_worktree()

  H.assert_eq(#worktree.parse_issue_list(""), 0)
  H.assert_eq(#worktree.parse_issue_list(nil), 0)
  H.assert_eq(#worktree.parse_issue_list("not json"), 0)
  H.assert_eq(#worktree.parse_issue_list("[]"), 0) -- GraphQL構造でない配列も空扱い
end)

H.section("ログインユーザーの取得")

test("current_user：キャッシュからloginを読み末尾空白を除去する", function()
  local worktree = H.load_worktree()
  local dir = (os.getenv("XDG_STATE_HOME") or (wezterm.home_dir .. "/.local/state")) .. "/wezterm-ai-agents"
  os.execute("mkdir -p '" .. dir .. "'")
  local cache = dir .. "/wezterm-gh-user"
  H.write_file(cache, "octocat\n")

  H.assert_eq(worktree.current_user(), "octocat")

  H.write_file(cache, "")
  H.assert_nil(worktree.current_user()) -- 空キャッシュは nil

  os.remove(cache)
end)

H.section("到達不能Issueの抽出")

test("uncovered_issues：linkedBranchが到達可能ならリネーム済みでも除外する", function()
  local worktree = H.load_worktree()
  local list = {
    { number = 5, title = "a", linked_branches = { "renamed-feature" } }, -- issue-5 でなくても刻印で除外
    { number = 3, title = "b", linked_branches = {} }, -- 未着手
  }
  local reachable = { ["renamed-feature"] = true }

  local out = worktree.uncovered_issues(list, reachable)

  H.assert_eq(#out, 1)
  H.assert_eq(out[1].number, 3)
end)

test("uncovered_issues：issue-N命名のフォールバックでも除外する", function()
  local worktree = H.load_worktree()
  local list = { { number = 7, title = "a", linked_branches = {} } }

  -- キャッシュ未更新で linkedBranches が空でも、ローカルの issue-7 で消える
  H.assert_eq(#worktree.uncovered_issues(list, { ["issue-7"] = true }), 0)
end)

test("uncovered_issues：到達不能なリンクは一覧に残す", function()
  local worktree = H.load_worktree()
  local list = { { number = 9, title = "a", linked_branches = { "someones-branch" } } }

  H.assert_eq(#worktree.uncovered_issues(list, {}), 1)
end)

test("issues：linkedBranchesを反転してbranch→番号マップを返す", function()
  local worktree = H.load_worktree()
  local git_root = "/tmp/__wt_issue_map_test"
  local cache = worktree.issue_cache_file(git_root)
  os.execute("mkdir -p '" .. cache:match("^(.*)/[^/]+$") .. "'")
  H.write_file(
    cache,
    issue_graphql('[{"number":12,"title":"x","assignees":{"nodes":[]},"linkedBranches":{"nodes":[{"ref":{"name":"my-fix"}}]}}]')
  )

  local map = worktree.issues(git_root)

  os.remove(cache)
  H.assert_eq(map["my-fix"], 12) -- 任意名ブランチでも Issue 番号を逆引きできる
  H.assert_nil(map["issue-12"])
end)

H.section("自分関係の判定と先頭ソート")

test("relevant_prs：作成 or レビュー依頼を自分関係とし先頭+番号降順に並べる", function()
  local worktree = H.load_worktree()
  local list = {
    { number = 10, author = "other", review_requests = {} },
    { number = 11, author = "me", review_requests = {} }, -- 作成者
    { number = 12, author = "other", review_requests = { "x", "me" } }, -- レビュー依頼
    { number = 13, author = "other", review_requests = {} },
  }
  local out = worktree.relevant_prs(list, "me")

  -- 自分関係(#12,#11)が先頭、各グループ内は番号降順
  H.assert_eq(out[1].number, 12)
  H.assert_true(out[1].mine)
  H.assert_eq(out[2].number, 11)
  H.assert_true(out[2].mine)
  H.assert_eq(out[3].number, 13)
  H.assert_false(out[3].mine)
  H.assert_eq(out[4].number, 10)
end)

test("relevant_prs：me が nil なら誰も自分関係にならない(author nil との誤一致なし)", function()
  local worktree = H.load_worktree()
  local list = { { number = 1, author = nil, review_requests = {} } }

  local out = worktree.relevant_prs(list, nil)

  H.assert_false(out[1].mine)
end)

test("relevant_issues：自分アサインを先頭+番号昇順に並べる", function()
  local worktree = H.load_worktree()
  local list = {
    { number = 5, assignees = { "other" } },
    { number = 8, assignees = { "me" } },
    { number = 3, assignees = {} },
    { number = 7, assignees = { "a", "me" } },
  }
  local out = worktree.relevant_issues(list, "me")

  -- 自分アサイン(#7,#8)が先頭、各グループ内は番号昇順
  H.assert_eq(out[1].number, 7)
  H.assert_true(out[1].mine)
  H.assert_eq(out[2].number, 8)
  H.assert_eq(out[3].number, 3)
  H.assert_false(out[3].mine)
  H.assert_eq(out[4].number, 5)
end)

H.section("Issue worktreeの作成")

test("add_issue_worktree：gh issue develop→fetch→worktree addの順で実行する", function()
  local worktree = H.load_worktree()
  local calls = {}
  local original = wezterm.run_child_process
  wezterm.run_child_process = function(args)
    table.insert(calls, args)
    return true, "", ""
  end

  local ok, wt_path = worktree.add_issue_worktree("/home/user/repo", 7, {})

  wezterm.run_child_process = original
  H.assert_true(ok)
  H.assert_eq(wt_path, "/home/user/repo__worktrees/issue-7")
  H.assert_eq(#calls, 3)
  -- 1: gh issue develop (sh -lc 経由)
  H.assert_eq(calls[1][1], "/bin/sh")
  H.assert_match(calls[1][3], "gh issue develop 7")
  H.assert_match(calls[1][3], "issue%-7")
  -- 2: fetch origin issue-7
  H.assert_eq(calls[2][#calls[2] - 2], "fetch")
  H.assert_eq(calls[2][#calls[2] - 1], "origin")
  H.assert_eq(calls[2][#calls[2]], "issue-7")
  -- 3: worktree add --track -b issue-7 <path> origin/issue-7
  H.assert_eq(calls[3][#calls[3] - 1], "/home/user/repo__worktrees/issue-7")
  H.assert_eq(calls[3][#calls[3]], "origin/issue-7")
end)

test("add_issue_worktree：gh issue develop失敗時はfetchもworktree addもしない", function()
  local worktree = H.load_worktree()
  local calls = {}
  local original = wezterm.run_child_process
  wezterm.run_child_process = function(args)
    table.insert(calls, args)
    return false, "", "no permission"
  end

  local ok = worktree.add_issue_worktree("/home/user/repo", 7, {})

  wezterm.run_child_process = original
  H.assert_false(ok)
  H.assert_eq(#calls, 1)
end)

test("open_issue_web：gh issue view --web をログインシェルで投げる", function()
  local worktree = H.load_worktree()
  local captured
  local original = wezterm.background_child_process
  wezterm.background_child_process = function(args) captured = args end

  worktree.open_issue_web("/home/user/repo", 7)

  wezterm.background_child_process = original
  H.assert_match(captured[3], "gh issue view %-%-web 7")
  H.assert_match(captured[3], "/home/user/repo")
end)

H.finish()
