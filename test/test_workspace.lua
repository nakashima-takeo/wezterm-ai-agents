package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test = H.test

H.section("JSON永続化")

test("正常系：ワークスペース定義をJSONに保存し読み戻せる", function()
  local workspace = H.load_workspace()
  local tmp = H.tmp_dir()
  local opts = { file = tmp .. "/workspaces.json" }
  local data = {
    workspaces = {
      { name = "project-a", cwd = "/home/user/project-a", lastUsed = 1716000000 },
      { name = "project-b", cwd = "/home/user/project-b", tabs = { { agent = "claude", session_id = "sess-1" } } },
    },
  }

  workspace.write(opts, data)
  local loaded = workspace.read(opts)

  H.assert_eq(#loaded.workspaces, 2)
  H.assert_eq(loaded.workspaces[1].name, "project-a")
  H.assert_eq(loaded.workspaces[2].tabs[1].agent, "claude")
  H.assert_eq(loaded.workspaces[2].tabs[1].session_id, "sess-1")
  H.assert_nil(io.open(opts.file .. ".tmp", "r"), "一時ファイルが残っていない")

  os.execute("rm -rf " .. tmp)
end)

test("正常系：ファイルが存在しない場合は空のワークスペースリストを返す", function()
  local workspace = H.load_workspace()

  local data = workspace.read({ file = "/tmp/nonexistent-" .. os.time() .. ".json" })

  H.assert_not_nil(data.workspaces)
  H.assert_eq(#data.workspaces, 0)
end)

test("異常系：不正なJSONファイルの場合は空のワークスペースリストを返す", function()
  local workspace = H.load_workspace()
  local tmp = H.tmp_dir()
  local opts = { file = tmp .. "/workspaces.json" }
  H.write_file(opts.file, "not valid JSON {{{")

  local data = workspace.read(opts)

  H.assert_eq(#data.workspaces, 0)

  os.execute("rm -rf " .. tmp)
end)

H.section("レガシーデータ移行")

test("正常系：旧形式(claude/sessionId)を現行形式(agent/session_id)に自動移行する", function()
  local workspace = H.load_workspace()
  local tmp = H.tmp_dir()
  local opts = { file = tmp .. "/workspaces.json" }
  H.write_file(opts.file, '{"workspaces":[{"name":"old-project","cwd":"/tmp","tabs":[{"claude":true,"sessionId":"old-sess"}]}]}')

  local data = workspace.read(opts)
  local tab = data.workspaces[1].tabs[1]

  H.assert_eq(tab.agent, "claude")
  H.assert_eq(tab.session_id, "old-sess")
  H.assert_nil(tab.claude)
  H.assert_nil(tab.sessionId)

  os.execute("rm -rf " .. tmp)
end)

H.section("ワークスペース検索")

test("正常系：名前でワークスペースを検索しインデックスも取得できる", function()
  local workspace = H.load_workspace()
  local data = {
    workspaces = {
      { name = "frontend", cwd = "/app/frontend" },
      { name = "backend", cwd = "/app/backend" },
      { name = "infra", cwd = "/app/infra" },
    },
  }

  local ws, idx = workspace.find(data, "backend")

  H.assert_eq(ws.name, "backend")
  H.assert_eq(idx, 2)
end)

test("正常系：存在しないワークスペースはnilを返す", function()
  local workspace = H.load_workspace()

  local ws, idx = workspace.find({ workspaces = {} }, "missing")

  H.assert_nil(ws)
  H.assert_nil(idx)
end)

H.section("ワークスペースソート")

test("正常系：デフォルトワークスペースが最優先、残りは最終使用日時の降順", function()
  local workspace = H.load_workspace()
  local ws_list = {
    { name = "project-a", lastUsed = 1716000100 },
    { name = "default", lastUsed = 1716000050 },
    { name = "project-b", lastUsed = 1716000200 },
    { name = "project-c" },
  }

  local sorted = workspace.sort(ws_list, "default")

  H.assert_eq(sorted[1].name, "default")
  H.assert_eq(sorted[2].name, "project-b")
  H.assert_eq(sorted[3].name, "project-a")
  H.assert_eq(sorted[4].name, "project-c")
end)

test("正常系：空リストでもエラーにならない", function()
  local workspace = H.load_workspace()

  H.assert_eq(#workspace.sort({}, "default"), 0)
end)

H.section("再開可能セッション数")

test("正常系：agentとsession_idの両方を持つタブの数をカウントする", function()
  local workspace = H.load_workspace()
  local ws = { tabs = {
    { agent = "claude", session_id = "sess-1" },
    { agent = "claude", session_id = "sess-2" },
    {},
  } }

  H.assert_eq(workspace.count_saved_sessions(ws), 2)
end)

test("正常系：agentのみ・session_idのみ・空session_idはカウントしない", function()
  local workspace = H.load_workspace()

  H.assert_eq(
    workspace.count_saved_sessions({
      tabs = {
        { agent = "claude" },
        { session_id = "orphan" },
        { agent = "claude", session_id = "" },
      },
    }),
    0
  )
end)

test("正常系：tabsフィールドがない場合は0を返す", function()
  local workspace = H.load_workspace()

  H.assert_eq(workspace.count_saved_sessions({}), 0)
end)

-- ===== Mock factories for snapshot/sync tests =====

local function mock_pane(id, cwd)
  return {
    pane_id = function() return id end,
    get_current_working_dir = function()
      if not cwd then return nil end
      return { file_path = cwd }
    end,
  }
end

local function mock_tab(panes, active_idx)
  active_idx = active_idx or 1
  return {
    panes = function() return panes end,
    active_pane = function() return panes[active_idx] end,
    panes_with_info = function() return {} end,
  }
end

local function mock_window(tabs)
  return {
    tabs = function() return tabs end,
  }
end

local function mock_agent_mod(agent_pane_ids)
  local impl = {
    id = "claude",
    detect = function(p) return agent_pane_ids[p:pane_id()] ~= nil end,
    session_id = function(p)
      local info = agent_pane_ids[p:pane_id()]
      return info and info.session_id or nil
    end,
  }
  return {
    find_in_tab = function(tab)
      for _, p in ipairs(tab:panes()) do
        if agent_pane_ids[p:pane_id()] then return impl, {}, p end
      end
      return nil, nil, nil
    end,
    get = function(id) return id == "claude" and impl or nil end,
    opts_for = function() return {} end,
  }
end

local no_layout = { snapshot = function() return nil end }

H.section("タブスナップショット")

test("正常系：エージェントありとなしのタブが混在しても全タブのCWDが保存される", function()
  local workspace = H.load_workspace()

  local agent_pane = mock_pane(1, "/app/claude-project")
  local shell_pane = mock_pane(2, "/home/user/docs")
  local tab1 = mock_tab({ agent_pane })
  local tab2 = mock_tab({ shell_pane })
  local window = mock_window({ tab1, tab2 })
  local agent_mod = mock_agent_mod({ [1] = { session_id = "sess-1" } })

  local tabs = workspace.snapshot_tabs(window, agent_mod, no_layout, {})

  H.assert_eq(#tabs, 2)
  H.assert_eq(tabs[1].agent, "claude")
  H.assert_eq(tabs[1].session_id, "sess-1")
  H.assert_eq(tabs[1].cwd, "/app/claude-project")
  H.assert_nil(tabs[2].agent)
  H.assert_eq(tabs[2].cwd, "/home/user/docs")
end)

H.section("定期フルスナップショット同期")

test("正常系：タブのCWD・セッションID変更がsync_allでJSONに反映される", function()
  local workspace = H.load_workspace()
  local tmp = H.tmp_dir()
  local ws_opts = { file = tmp .. "/workspaces.json" }

  workspace.write(ws_opts, {
    workspaces = {
      {
        name = "my-project",
        cwd = "/app",
        tabs = {
          { agent = "claude", session_id = "sess-1", cwd = "/app" },
          { cwd = "/app/old-dir" },
        },
      },
    },
  })

  local agent_pane = mock_pane(10, "/app/new-agent-dir")
  local shell_pane = mock_pane(20, "/app/new-shell-dir")
  local tab1 = mock_tab({ agent_pane })
  local tab2 = mock_tab({ shell_pane })

  local mock_win = {
    get_workspace = function() return "my-project" end,
    tabs = function() return { tab1, tab2 } end,
  }

  local original = wezterm.mux.all_windows
  wezterm.mux.all_windows = function() return { mock_win } end

  local agent_mod = mock_agent_mod({ [10] = { session_id = "sess-updated" } })
  workspace.sync_all(ws_opts, agent_mod, no_layout, {})

  wezterm.mux.all_windows = original

  local data = workspace.read(ws_opts)
  local ws = data.workspaces[1]
  H.assert_eq(ws.tabs[1].session_id, "sess-updated")
  H.assert_eq(ws.tabs[1].cwd, "/app/new-agent-dir")
  H.assert_eq(ws.tabs[2].cwd, "/app/new-shell-dir")

  os.execute("rm -rf " .. tmp)
end)

test("正常系：タブの追加がsync_allでJSONに反映される", function()
  local workspace = H.load_workspace()
  local tmp = H.tmp_dir()
  local ws_opts = { file = tmp .. "/workspaces.json" }

  workspace.write(ws_opts, {
    workspaces = {
      { name = "my-project", cwd = "/app", tabs = { { cwd = "/app" } } },
    },
  })

  local pane1 = mock_pane(1, "/app")
  local pane2 = mock_pane(2, "/app/new-tab")
  local tab1 = mock_tab({ pane1 })
  local tab2 = mock_tab({ pane2 })

  local mock_win = {
    get_workspace = function() return "my-project" end,
    tabs = function() return { tab1, tab2 } end,
  }

  local original = wezterm.mux.all_windows
  wezterm.mux.all_windows = function() return { mock_win } end

  local agent_mod = mock_agent_mod({})
  workspace.sync_all(ws_opts, agent_mod, no_layout, {})

  wezterm.mux.all_windows = original

  local data = workspace.read(ws_opts)
  local ws = data.workspaces[1]
  H.assert_eq(#ws.tabs, 2, "should have 2 tabs after sync")
  H.assert_eq(ws.tabs[2].cwd, "/app/new-tab")

  os.execute("rm -rf " .. tmp)
end)

test("正常系：変更がなければJSONファイルを書き込まない", function()
  local workspace = H.load_workspace()
  local tmp = H.tmp_dir()
  local ws_opts = { file = tmp .. "/workspaces.json" }

  local pane1 = mock_pane(1, "/app")
  local tab1 = mock_tab({ pane1 })

  workspace.write(ws_opts, {
    workspaces = {
      { name = "my-project", cwd = "/app", tabs = { { cwd = "/app" } } },
    },
  })

  local stat_before = io.popen("stat -f %m " .. ws_opts.file):read("*l")

  local mock_win = {
    get_workspace = function() return "my-project" end,
    tabs = function() return { tab1 } end,
  }

  local original = wezterm.mux.all_windows
  wezterm.mux.all_windows = function() return { mock_win } end

  local agent_mod = mock_agent_mod({})
  workspace.sync_all(ws_opts, agent_mod, no_layout, {})

  wezterm.mux.all_windows = original

  local stat_after = io.popen("stat -f %m " .. ws_opts.file):read("*l")
  H.assert_eq(stat_before, stat_after, "file should not be rewritten when nothing changed")

  os.execute("rm -rf " .. tmp)
end)

H.finish()
