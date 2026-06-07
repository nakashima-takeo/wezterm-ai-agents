-- Supervision registry (state/managed): read / write / toggle round-trips.

package.path = package.path .. ";test/?.lua"
local H = require("helper")
local managed = H.load_mod("state/managed")

H.section("managed registry")

H.test("read missing file returns empty set", function()
  local set = managed.read("/nonexistent/dir/managed.json")
  H.assert_eq(next(set), nil, "empty set")
end)

H.test("write then read round-trips pane ids", function()
  local file = H.tmp_dir() .. "/managed.json"
  H.assert_true(managed.write(file, { [3] = true, [6] = true }), "write ok")
  local set = managed.read(file)
  H.assert_true(set[3], "3 present")
  H.assert_true(set[6], "6 present")
  H.assert_nil(set[9], "9 absent")
end)

H.test("toggle adds when absent and returns true", function()
  local file = H.tmp_dir() .. "/managed.json"
  H.assert_true(managed.toggle(file, 5), "now managed")
  H.assert_true(managed.is_managed(file, 5), "persisted")
end)

H.test("toggle removes when present and returns false", function()
  local file = H.tmp_dir() .. "/managed.json"
  managed.write(file, { [7] = true })
  H.assert_false(managed.toggle(file, 7), "now unmanaged")
  H.assert_false(managed.is_managed(file, 7), "removed from file")
end)

H.test("invalid json reads as empty set", function()
  local file = H.tmp_dir() .. "/managed.json"
  H.write_file(file, "{ not json")
  H.assert_eq(next(managed.read(file)), nil, "empty on parse failure")
end)

H.test("prune drops ids whose pane is no longer live", function()
  local file = H.tmp_dir() .. "/managed.json"
  managed.write(file, { [3] = true, [6] = true, [9] = true })
  managed.prune(file, { ["3"] = true, ["9"] = true }) -- pane 6 is gone
  local set = managed.read(file)
  H.assert_true(set[3], "3 kept")
  H.assert_nil(set[6], "6 pruned")
  H.assert_true(set[9], "9 kept")
end)

H.test("prune with nil live set leaves the file untouched", function()
  local file = H.tmp_dir() .. "/managed.json"
  managed.write(file, { [3] = true })
  managed.prune(file, nil) -- liveness unknown -> do not prune
  H.assert_true(managed.read(file)[3], "3 still present")
end)

H.test("orchestrator pane id round-trips and clears", function()
  local file = H.tmp_dir() .. "/orchestrator"
  H.assert_nil(managed.read_orchestrator(file), "absent initially")
  managed.write_orchestrator(file, 12)
  H.assert_eq(managed.read_orchestrator(file), 12, "stored")
  managed.write_orchestrator(file, nil)
  H.assert_nil(managed.read_orchestrator(file), "cleared")
end)

H.finish()
