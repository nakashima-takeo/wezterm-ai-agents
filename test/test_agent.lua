package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test, load_mod = H.test, H.load_mod

local function new_agent(overrides)
  local base = {
    id = "test",
    display_name = "Test Agent",
    default_opts = {},
    detect = function() return false end,
    state = function() return "idle" end,
    session_id = function() return nil end,
    spawn_args = function() return {} end,
  }
  if overrides then
    for k, v in pairs(overrides) do
      base[k] = v
    end
  end
  return base
end

H.section("エージェント登録と取得")

test("正常系：登録したエージェントをIDで取得できる", function()
  local agent = load_mod("service/agent")
  local impl = new_agent({ id = "claude" })

  agent.register(impl)

  H.assert_eq(agent.get("claude"), impl)
  H.assert_eq(#agent.all(), 1)
end)

test("正常系：同一IDの再登録は既存を置き換え、一覧が重複しない", function()
  local agent = load_mod("service/agent")
  local v1 = new_agent({ id = "claude", display_name = "v1" })
  local v2 = new_agent({ id = "claude", display_name = "v2" })

  agent.register(v1)
  agent.register(v2)

  H.assert_eq(agent.get("claude").display_name, "v2")
  H.assert_eq(#agent.all(), 1)
end)

test("異常系：idなしやnilの登録はエラーになる", function()
  local agent = load_mod("service/agent")

  H.assert_error(function() agent.register({ display_name = "NoId" }) end)
  H.assert_error(function() agent.register(nil) end)
end)

H.section("インストール検出 (detect_installed)")

test("正常系：command -v で見つかった id だけが集合に入る", function()
  local agent = load_mod("service/agent")
  local candidates = { { id = "claude", bin = "claude" }, { id = "cursor", bin = "cursor-agent" } }
  -- claude は見つかり cursor-agent は見つからない状況を模す。
  local captured
  local fake_run = function(args)
    captured = args
    return true, "claude\n", ""
  end

  local installed = agent.detect_installed(candidates, "/bin/sh", fake_run)

  H.assert_eq(installed.claude, true)
  H.assert_eq(installed.cursor, nil)
  -- bin/id がシェルに渡るスクリプトへ単一引用符付きで埋まっていること。
  H.assert_true(captured[3]:find("command %-v 'cursor%-agent'") ~= nil)
  H.assert_true(captured[3]:find("printf '%%s\\n' 'claude'") ~= nil)
end)

test("検出不能：シェル実行が失敗したら nil を返す (呼び出し側でフォールバック)", function()
  local agent = load_mod("service/agent")
  local candidates = { { id = "claude", bin = "claude" } }
  local fake_run = function() return false, "", "boom" end

  H.assert_eq(agent.detect_installed(candidates, "/bin/sh", fake_run), nil)
end)

test("正常系：candidates が空なら実行せず空集合を返す", function()
  local agent = load_mod("service/agent")
  local called = false
  local fake_run = function()
    called = true
    return true, "", ""
  end

  local installed = agent.detect_installed({}, "/bin/sh", fake_run)

  H.assert_eq(next(installed), nil)
  H.assert_eq(called, false)
end)

test("組み立て：各文を if/fi で完結させ exit code に検出結果を載せない", function()
  local agent = load_mod("service/agent")
  -- 末尾候補が未検出でもスクリプト全体が非ゼロ終了しない (= nil 誤判定を防ぐ) ことを構造で保証する。
  local candidates = { { id = "claude", bin = "claude" }, { id = "gemini", bin = "gemini" } }
  local captured
  local fake_run = function(args)
    captured = args
    return true, "claude\n", ""
  end

  local installed = agent.detect_installed(candidates, "/bin/sh", fake_run)

  H.assert_eq(installed.claude, true)
  -- 末尾候補を含め各文が if ...; then ...; fi で閉じ、&& 連結 (末尾未ヒットで非ゼロ終了) を使わないこと。
  H.assert_true(captured[3]:find("if command %-v 'gemini'.-; fi$") ~= nil)
  H.assert_eq(captured[3]:find("&& printf"), nil)
end)

H.section("設定マージ")

test("正常系：ユーザー設定がデフォルト設定を上書きし、未指定のデフォルトは保持される", function()
  local agent = load_mod("service/agent")
  local impl = new_agent({
    id = "claude",
    default_opts = { command = "claude", shell = "/bin/zsh" },
  })
  agent.register(impl)

  local opts = agent.opts_for(impl, {
    agents = { claude = { command = "claude --verbose", extra = true } },
  })

  H.assert_eq(opts.command, "claude --verbose")
  H.assert_eq(opts.shell, "/bin/zsh")
  H.assert_true(opts.extra)
end)

test("正常系：ユーザー設定がない場合はデフォルトがそのまま使われる", function()
  local agent = load_mod("service/agent")
  local impl = new_agent({
    id = "claude",
    default_opts = { command = "claude", shell = "/bin/zsh" },
  })
  agent.register(impl)

  local opts = agent.opts_for(impl, {})

  H.assert_eq(opts.command, "claude")
  H.assert_eq(opts.shell, "/bin/zsh")
end)

test("正常系：status_dir は PID 名前空間付き、status_base は base のまま、spawn_env は base を渡す", function()
  local agent = load_mod("service/agent")
  local impl = new_agent({ id = "claude", default_opts = { command = "claude" } })
  agent.register(impl)

  local tmp = H.tmp_dir()
  local opts = agent.opts_for(impl, { status_dir = tmp })

  -- フック(書き込み)へは名前空間なしの base、Lua(読み取り)は base/<pid> を見る非対称変換
  H.assert_eq(opts.status_base, tmp)
  H.assert_eq(opts.status_dir, H.ns_dir(tmp))
  H.assert_eq(agent.spawn_env(opts).WEZTERM_AGENT_STATUS_DIR, opts.status_base)

  os.execute("rm -rf " .. tmp)
end)

H.section("状態集計")

test("正常系：unknown状態のペインがカウントされる", function()
  local agent = load_mod("service/agent")
  local tmp = H.tmp_dir()
  local cursor = load_mod("service/agents/cursor")
  agent.register(cursor)

  local pane = H.mock_pane("agg1")
  H.write_state(tmp, "agg1", '{"agent":"cursor","state":"unknown","ts":1716000000,"session_id":""}')

  local mock_win = {
    get_workspace = function() return "test-ws" end,
    tabs = function()
      return {
        { panes = function() return { pane } end },
      }
    end,
  }
  local orig = wezterm.mux.all_windows
  wezterm.mux.all_windows = function() return { mock_win } end

  local counts = agent.count({ agents = { cursor = { status_dir = tmp } } })

  H.assert_eq(counts.unknown, 1)
  H.assert_eq(counts.working, 0)

  wezterm.mux.all_windows = orig
  os.execute("rm -rf " .. tmp)
end)

test("正常系：error状態のペインがカウントされる", function()
  local agent = load_mod("service/agent")
  local tmp = H.tmp_dir()
  agent.register(load_mod("service/agents/cursor"))

  local pane = H.mock_pane("aggerr")
  H.write_state(tmp, "aggerr", '{"agent":"cursor","state":"error","ts":1716000000,"session_id":""}')

  local mock_win = {
    get_workspace = function() return "test-ws" end,
    tabs = function()
      return { { panes = function() return { pane } end } }
    end,
  }
  local orig = wezterm.mux.all_windows
  wezterm.mux.all_windows = function() return { mock_win } end

  local counts = agent.count({ agents = { cursor = { status_dir = tmp } } })

  H.assert_eq(counts.error, 1)

  wezterm.mux.all_windows = orig
  os.execute("rm -rf " .. tmp)
end)

test("正常系：all_workspaces はWS別に集計し、エージェント未検出ペインは数えない", function()
  local agent = load_mod("service/agent")
  local tmp = H.tmp_dir()
  agent.register(load_mod("service/agents/cursor"))

  -- wsA: working のエージェントペイン + 状態ファイルを持たない (未検出) ペイン
  local pane_a1 = H.mock_pane("awsA1")
  local pane_a2 = H.mock_pane("awsA2") -- write_state しない = エージェント未検出
  H.write_state(tmp, "awsA1", '{"agent":"cursor","state":"working","ts":1716000000,"session_id":""}')
  -- wsB: waiting のエージェントペイン
  local pane_b1 = H.mock_pane("awsB1")
  H.write_state(tmp, "awsB1", '{"agent":"cursor","state":"waiting","ts":1716000000,"session_id":""}')

  local win_a = {
    get_workspace = function() return "wsA" end,
    tabs = function()
      return { { panes = function() return { pane_a1, pane_a2 } end } }
    end,
  }
  local win_b = {
    get_workspace = function() return "wsB" end,
    tabs = function()
      return { { panes = function() return { pane_b1 } end } }
    end,
  }
  local orig = wezterm.mux.all_windows
  wezterm.mux.all_windows = function() return { win_a, win_b } end

  local result = agent.all_workspaces({ agents = { cursor = { status_dir = tmp } } })

  H.assert_eq(result["wsA"].working, 1)
  H.assert_eq(result["wsA"].idle, 0) -- 未検出ペインは idle にも他にも数えない
  H.assert_eq(result["wsA"].unknown, 0)
  H.assert_eq(result["wsB"].waiting, 1)
  H.assert_eq(result["wsB"].working, 0)

  wezterm.mux.all_windows = orig
  os.execute("rm -rf " .. tmp)
end)

H.section("孤立状態ファイルの掃除 (sweep)")

-- 生存 pane id 群から mock mux を組み、sweep 実行中だけ all_windows を差し替える。
local function with_live_panes(live_ids, fn)
  local panes = {}
  for _, id in ipairs(live_ids) do
    panes[#panes + 1] = H.mock_pane(id)
  end
  local win = {
    get_workspace = function() return "ws" end,
    tabs = function()
      return { { panes = function() return panes end } }
    end,
  }
  local orig = wezterm.mux.all_windows
  wezterm.mux.all_windows = function() return { win } end
  local ok, err = pcall(fn)
  wezterm.mux.all_windows = orig
  if not ok then error(err, 2) end
end

-- sweep は自 PID 名前空間配下のみを見るので、テストも名前空間配下に書く。
local function nsd(dir) return dir .. "/" .. tostring(wezterm.procinfo.pid()) end
local function touch(dir, name)
  os.execute('mkdir -p "' .. nsd(dir) .. '"')
  H.write_file(nsd(dir) .. "/" .. name, '{"agent":"claude","state":"working","ts":1,"session_id":""}')
end

local function exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

test("正常系：生存集合に在るファイルは残し、無い id だけ消す", function()
  local agent = load_mod("service/agent")
  local tmp = H.tmp_dir()
  touch(tmp, "wezterm-agent-1") -- 生存
  touch(tmp, "wezterm-agent-2") -- 孤立

  with_live_panes({ 1 }, function() agent.sweep_orphan_files({ status_dir = tmp }) end)

  H.assert_true(exists(nsd(tmp) .. "/wezterm-agent-1"), "生存 id は残る")
  H.assert_false(exists(nsd(tmp) .. "/wezterm-agent-2"), "孤立 id は消える")
  os.execute("rm -rf " .. tmp)
end)

test("安全弁：生存集合が空のときは何も消さない", function()
  local agent = load_mod("service/agent")
  local tmp = H.tmp_dir()
  touch(tmp, "wezterm-agent-1")

  with_live_panes({}, function() agent.sweep_orphan_files({ status_dir = tmp }) end)

  H.assert_true(exists(nsd(tmp) .. "/wezterm-agent-1"), "空集合では削除しない")
  os.execute("rm -rf " .. tmp)
end)

test("正常系：数値 pane_id と文字列ファイル名 id が突き合う", function()
  local agent = load_mod("service/agent")
  local tmp = H.tmp_dir()
  touch(tmp, "wezterm-agent-10")

  -- mock_pane(10) は数値を返す。sweep は tostring で文字列化して突き合わせる。
  with_live_panes({ 10 }, function() agent.sweep_orphan_files({ status_dir = tmp }) end)

  H.assert_true(exists(nsd(tmp) .. "/wezterm-agent-10"), "数値 id と文字列ファイル名が一致し残る")
  os.execute("rm -rf " .. tmp)
end)

test("正常系：.tmp 中間ファイルと非数値名は対象外", function()
  local agent = load_mod("service/agent")
  local tmp = H.tmp_dir()
  touch(tmp, "wezterm-agent-2.tmp") -- 書き込み中の中間ファイル
  touch(tmp, "wezterm-agent-foo") -- 非数値名
  touch(tmp, "other-file")

  with_live_panes({ 1 }, function() agent.sweep_orphan_files({ status_dir = tmp }) end)

  H.assert_true(exists(nsd(tmp) .. "/wezterm-agent-2.tmp"), ".tmp は消さない")
  H.assert_true(exists(nsd(tmp) .. "/wezterm-agent-foo"), "非数値名は消さない")
  H.assert_true(exists(nsd(tmp) .. "/other-file"), "無関係ファイルは消さない")
  os.execute("rm -rf " .. tmp)
end)

test("正常系：複数 dir を横断して掃除する", function()
  local agent = load_mod("service/agent")
  local d1, d2 = H.tmp_dir(), H.tmp_dir()
  touch(d1, "wezterm-agent-2") -- 孤立 (共通 dir)
  touch(d2, "wezterm-agent-3") -- 孤立 (エージェント別 dir)
  touch(d2, "wezterm-agent-1") -- 生存 (エージェント別 dir)

  with_live_panes({ 1 }, function() agent.sweep_orphan_files({ status_dir = d1, agents = { claude = { status_dir = d2 } } }) end)

  H.assert_false(exists(nsd(d1) .. "/wezterm-agent-2"), "共通 dir の孤立は消える")
  H.assert_false(exists(nsd(d2) .. "/wezterm-agent-3"), "別 dir の孤立も消える")
  H.assert_true(exists(nsd(d2) .. "/wezterm-agent-1"), "別 dir の生存は残る")
  os.execute("rm -rf " .. d1 .. " " .. d2)
end)

H.section("死んだ PID 名前空間の掃除 (cleanup_dead_namespaces)")

local function seed_ns(base, pid, name)
  local d = base .. "/" .. pid
  os.execute('mkdir -p "' .. d .. '"')
  H.write_file(d .. "/" .. name, '{"agent":"claude","state":"working","ts":1,"session_id":""}')
end

test("正常系：死んだ PID dir は削除し、自分と生存 PID dir は残す", function()
  wezterm.procinfo._pid = 99999
  wezterm.procinfo._alive = { [55555] = true }
  local agent = load_mod("service/agent")
  local base = H.tmp_dir()
  seed_ns(base, "99999", "wezterm-agent-1") -- 自分
  seed_ns(base, "55555", "wezterm-agent-1") -- 生存中の他プロセス
  seed_ns(base, "12345", "wezterm-agent-1") -- 死んだプロセス
  H.write_file(base .. "/wezterm-agent-7", "{}") -- 旧バージョンのフラット残置

  agent.cleanup_dead_namespaces({ status_dir = base })

  H.assert_true(exists(base .. "/99999/wezterm-agent-1"), "自 PID dir は残る")
  H.assert_true(exists(base .. "/55555/wezterm-agent-1"), "生存 PID dir は残る")
  H.assert_false(exists(base .. "/12345/wezterm-agent-1"), "死 PID dir は消える")
  H.assert_false(exists(base .. "/12345"), "死 PID dir 自体も消える")
  H.assert_false(exists(base .. "/wezterm-agent-7"), "フラットなレガシー残置は消える")
  wezterm.procinfo._alive = {}
  os.execute("rm -rf " .. base)
end)

H.finish()
