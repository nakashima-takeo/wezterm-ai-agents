package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test, load_mod = H.test, H.load_mod

H.section("worktreeパス解決")

test("siblingプリセット：親ディレクトリに__worktreesで配置される", function()
  local worktree = load_mod("worktree")

  H.assert_eq(worktree.resolve_path("sibling", "/home/user/myproject", "feature-x"), "/home/user/myproject__worktrees/feature-x")
end)

test("subdirectoryプリセット：リポジトリ内.worktreesに配置される", function()
  local worktree = load_mod("worktree")

  H.assert_eq(worktree.resolve_path("subdirectory", "/home/user/myproject", "feature-x"), "/home/user/myproject/.worktrees/feature-x")
end)

test("カスタムテンプレート：全変数が展開される", function()
  local worktree = load_mod("worktree")

  H.assert_eq(worktree.resolve_path("{parent}/{repo}.{branch}", "/home/user/myproject", "feature-x"), "/home/user/myproject.feature-x")
end)

test("カスタムテンプレート：集中管理ディレクトリ", function()
  local worktree = load_mod("worktree")

  H.assert_eq(worktree.resolve_path("/tmp/worktrees/{repo}/{branch}", "/home/user/myproject", "hotfix"), "/tmp/worktrees/myproject/hotfix")
end)

test("ブランチ名のスラッシュはハイフンに変換される", function()
  local worktree = load_mod("worktree")

  H.assert_eq(worktree.resolve_path("sibling", "/home/user/repo", "feature/auth/login"), "/home/user/repo__worktrees/feature-auth-login")
end)

test("git_root変数がテンプレートで使える", function()
  local worktree = load_mod("worktree")

  H.assert_eq(worktree.resolve_path("{git_root}/.wt/{branch}", "/home/user/repo", "dev"), "/home/user/repo/.wt/dev")
end)

H.section("worktree add のパス生成")

test("addはデフォルト(sibling)でパスを生成する", function()
  local worktree = load_mod("worktree")
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
  local worktree = load_mod("worktree")
  local original = wezterm.run_child_process
  wezterm.run_child_process = function() return true, "", "" end

  local _, wt_path = worktree.add("/home/user/repo", "fix", "fix", false, { worktree = { path = "subdirectory" } })

  wezterm.run_child_process = original
  H.assert_eq(wt_path, "/home/user/repo/.worktrees/fix")
end)

test("addはカスタムテンプレートを受け入れる", function()
  local worktree = load_mod("worktree")
  local original = wezterm.run_child_process
  wezterm.run_child_process = function() return true, "", "" end

  local _, wt_path = worktree.add("/home/user/repo", "dev", "dev", false, { worktree = { path = "/tmp/wt/{repo}/{branch}" } })

  wezterm.run_child_process = original
  H.assert_eq(wt_path, "/tmp/wt/repo/dev")
end)

test("addはoptsなしでもsiblingにフォールバックする", function()
  local worktree = load_mod("worktree")
  local original = wezterm.run_child_process
  wezterm.run_child_process = function() return true, "", "" end

  local _, wt_path = worktree.add("/home/user/repo", "main", "main", false, nil)

  wezterm.run_child_process = original
  H.assert_eq(wt_path, "/home/user/repo__worktrees/main")
end)

H.section("ワークスペース名の導出")

test("正常系：非mainブランチは「ベース名/ブランチ名」形式になる", function()
  local worktree = load_mod("worktree")

  H.assert_eq(worktree.workspace_name_for("myproject", "feature-x", false), "myproject/feature-x")
end)

test("正常系：mainブランチはベース名そのものになる", function()
  local worktree = load_mod("worktree")

  H.assert_eq(worktree.workspace_name_for("myproject", "main", true), "myproject")
end)

test("正常系：スラッシュを含むブランチ名もそのまま保持される", function()
  local worktree = load_mod("worktree")

  H.assert_eq(worktree.workspace_name_for("proj", "feat/auth/login", false), "proj/feat/auth/login")
end)

H.section("ベースワークスペース名の抽出")

test("正常系：worktree形式のワークスペース名から最初のセグメントを抽出する", function()
  local worktree = load_mod("worktree")
  local win = { active_workspace = function() return "myproject/feature-x" end }

  H.assert_eq(worktree.base_workspace_name(win), "myproject")
end)

test("正常系：スラッシュなしのワークスペース名はそのまま返す", function()
  local worktree = load_mod("worktree")
  local win = { active_workspace = function() return "simple-project" end }

  H.assert_eq(worktree.base_workspace_name(win), "simple-project")
end)

H.section("worktree listのパース")

test("正常系：porcelain出力からworktreeのパスとブランチを取得できる", function()
  local worktree = load_mod("worktree")
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
  local worktree = load_mod("worktree")
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
  local worktree = load_mod("worktree")
  local original = wezterm.run_child_process
  wezterm.run_child_process = function() return false, nil end

  local trees = worktree.list("/dummy")

  wezterm.run_child_process = original
  H.assert_eq(#trees, 0)
end)

H.section("一時ブランチ名")

test("正常系：派生元ブランチ名を含むtmp/プレフィックスで日時形式の名前を生成する", function()
  local worktree = load_mod("worktree")

  local name = worktree.generate_tmp_branch_name("main")
  H.assert_match(name, "^tmp/main/%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d$")

  local name_no_base = worktree.generate_tmp_branch_name(nil)
  H.assert_match(name_no_base, "^tmp/%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d$")
end)

test("正常系：tmp/で始まるブランチ名を一時ブランチと判定する", function()
  local worktree = load_mod("worktree")

  H.assert_true(worktree.is_tmp_branch("tmp/20260525-143022"))
  H.assert_true(worktree.is_tmp_branch("tmp/anything"))
  H.assert_false(worktree.is_tmp_branch("feature/tmp"))
  H.assert_false(worktree.is_tmp_branch("main"))
  H.assert_false(worktree.is_tmp_branch(nil))
end)

H.finish()
