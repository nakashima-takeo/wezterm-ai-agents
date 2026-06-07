-- Common test infrastructure: mock setup, test runner, assertions, utilities.

local H = {}

package.path = package.path .. ";test/?.lua"
local mock = require("mock_wezterm")
package.preload["wezterm"] = function() return mock end
_G.wezterm = mock

H.pass = 0
H.fail = 0
H.plugin_dir = io.popen("pwd"):read("*l")

function H.load_mod(rel) return dofile(H.plugin_dir .. "/plugin/" .. rel .. ".lua") end

-- plugin/ 配下の全モジュールを相対パス(.lua なし)で返す。init.lua (エントリ) は除外。
-- find ベースの自動発見。手動リスト保守と「新モジュール追記漏れ→静かに未ロードテスト」を構造的に排除する。
function H.all_modules()
  local mods = {}
  local p = io.popen('cd "' .. H.plugin_dir .. '/plugin" && find . -name "*.lua" -type f')
  if not p then return mods end
  for line in p:lines() do
    local rel = line:gsub("^%./", ""):gsub("%.lua$", "")
    if rel ~= "init" then mods[#mods + 1] = rel end
  end
  p:close()
  table.sort(mods)
  return mods
end

function H.load_agent(rel)
  local agent = H.load_mod("service/agent")
  local impl = H.load_mod(rel)
  agent.register(impl)
  return impl
end

-- workspace は init(storage+CRUD) と session(snapshot/sync/create) に分割されており、
-- 本体 init.lua と同じく setup() で結線して単一ファサードにする。
function H.load_workspace()
  local workspace = H.load_mod("state/workspace/init")
  workspace.setup(H.load_mod("state/workspace/session"))
  return workspace
end

-- selector は init(coordinator) + workspace/worktree/ui に分割されており、
-- 本体 init.lua と同じく setup() でサブモジュールを結線して単一ファサードにする。
function H.load_selector()
  local selector = H.load_mod("ui/selector/init")
  selector.setup(
    H.load_mod("ui/selector/workspace"),
    H.load_mod("ui/selector/worktree"),
    H.load_mod("ui/selector/ui"),
    H.load_mod("ui/selector/swarm")
  )
  return selector
end

-- worktree は init(ローカル git worktree) + github(PR/Issue 連携) に分割されており、
-- 本体 init.lua と同じく setup() で結線して単一ファサードにする。
function H.load_worktree()
  local worktree = H.load_mod("service/worktree/init")
  worktree.setup(H.load_mod("service/worktree/github"))
  return worktree
end

-- Each test runs in its own pcall so failures don't cascade.
function H.test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("  OK " .. name)
    H.pass = H.pass + 1
  else
    print(("  X  %s\n       %s"):format(name, tostring(err)))
    H.fail = H.fail + 1
  end
end

function H.section(name)
  print()
  print("--- " .. name .. " ---")
end

function H.finish()
  print()
  print(("Result: pass=%d fail=%d"):format(H.pass, H.fail))
  os.exit(H.fail == 0 and 0 or 1)
end

-- ===== Assertions =====

function H.assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s: expected [%s], got [%s]", msg or "assert_eq", tostring(expected), tostring(actual)), 2)
  end
end

function H.assert_true(val, msg)
  if not val then error(msg or "expected true, got " .. tostring(val), 2) end
end

function H.assert_false(val, msg)
  if val then error(msg or "expected false, got " .. tostring(val), 2) end
end

function H.assert_nil(val, msg)
  if val ~= nil then error(string.format("%s: expected nil, got [%s]", msg or "assert_nil", tostring(val)), 2) end
end

function H.assert_not_nil(val, msg)
  if val == nil then error(msg or "expected non-nil value", 2) end
end

function H.assert_error(fn, msg)
  local ok = pcall(fn)
  if ok then error(msg or "expected error but succeeded", 2) end
end

function H.assert_match(str, pattern, msg)
  if not str or not str:match(pattern) then
    error(string.format("%s: [%s] did not match pattern [%s]", msg or "assert_match", tostring(str), pattern), 2)
  end
end

-- ===== File utilities =====

function H.write_file(path, content)
  local f = io.open(path, "w")
  f:write(content)
  f:close()
end

function H.read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

function H.tmp_dir()
  local path = os.tmpname()
  os.remove(path)
  os.execute("mkdir -p " .. path)
  return path
end

-- base + 自 PID 名前空間 dir。本体の読み取り経路が見る場所と一致させる。
function H.ns_dir(base) return base .. "/" .. tostring(_G.wezterm.procinfo.pid()) end

-- 状態ファイルを名前空間配下に書く (本体の読み取りと突き合うように)。
function H.write_state(base, pane_id, content)
  local d = H.ns_dir(base)
  os.execute('mkdir -p "' .. d .. '"')
  H.write_file(d .. "/wezterm-agent-" .. pane_id, content)
end

-- ===== Mock factories =====

function H.mock_pane(id)
  return { pane_id = function() return id end }
end

return H
