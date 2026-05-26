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

function H.load_agent(rel)
  local agent = H.load_mod("agent")
  local impl = H.load_mod(rel)
  agent.register(impl)
  return impl
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

-- ===== Mock factories =====

function H.mock_pane(id)
  return { pane_id = function() return id end }
end

return H
