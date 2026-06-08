-- Supervision registry (state/managed): per-workspace read / write / toggle round-trips.

package.path = package.path .. ";test/?.lua"
local H = require("helper")
local managed = H.load_mod("state/managed")

H.section("managed registry")

H.test("read missing file returns empty set", function()
  local set = managed.read("/nonexistent/dir/managed.json", "ws")
  H.assert_eq(next(set), nil, "empty set")
end)

H.test("write then read round-trips pane ids within a workspace", function()
  local file = H.tmp_dir() .. "/managed.json"
  H.assert_true(managed.write(file, "ws", { [3] = true, [6] = true }), "write ok")
  local set = managed.read(file, "ws")
  H.assert_true(set[3], "3 present")
  H.assert_true(set[6], "6 present")
  H.assert_nil(set[9], "9 absent")
end)

H.test("workspaces are isolated from each other", function()
  local file = H.tmp_dir() .. "/managed.json"
  managed.write(file, "a", { [3] = true })
  managed.write(file, "b", { [9] = true })
  H.assert_true(managed.read(file, "a")[3], "a sees 3")
  H.assert_nil(managed.read(file, "a")[9], "a does not see b's pane")
  H.assert_true(managed.read(file, "b")[9], "b sees 9")
  H.assert_nil(managed.read(file, "b")[3], "b does not see a's pane")
end)

H.test("toggle adds when absent and returns true", function()
  local file = H.tmp_dir() .. "/managed.json"
  H.assert_true(managed.toggle(file, "ws", 5), "now managed")
  H.assert_true(managed.is_managed(file, "ws", 5), "persisted")
end)

H.test("toggle removes when present and returns false", function()
  local file = H.tmp_dir() .. "/managed.json"
  managed.write(file, "ws", { [7] = true })
  H.assert_false(managed.toggle(file, "ws", 7), "now unmanaged")
  H.assert_false(managed.is_managed(file, "ws", 7), "removed from file")
end)

H.test("invalid json reads as empty set", function()
  local file = H.tmp_dir() .. "/managed.json"
  H.write_file(file, "{ not json")
  H.assert_eq(next(managed.read(file, "ws")), nil, "empty on parse failure")
end)

H.test("prune drops dead ids across every workspace", function()
  local file = H.tmp_dir() .. "/managed.json"
  managed.write(file, "a", { [3] = true, [6] = true })
  managed.write(file, "b", { [9] = true })
  managed.prune(file, { ["3"] = true, ["9"] = true }) -- pane 6 is gone
  H.assert_true(managed.read(file, "a")[3], "3 kept")
  H.assert_nil(managed.read(file, "a")[6], "6 pruned")
  H.assert_true(managed.read(file, "b")[9], "9 kept")
end)

H.test("prune with nil live set leaves the file untouched", function()
  local file = H.tmp_dir() .. "/managed.json"
  managed.write(file, "ws", { [3] = true })
  managed.prune(file, nil) -- liveness unknown -> do not prune
  H.assert_true(managed.read(file, "ws")[3], "3 still present")
end)

H.test("orchestrator pane id round-trips per workspace and clears", function()
  local file = H.tmp_dir() .. "/orchestrator.json"
  H.assert_nil(managed.read_orchestrator(file, "ws"), "absent initially")
  managed.write_orchestrator(file, "ws", 12)
  H.assert_eq(managed.read_orchestrator(file, "ws"), 12, "stored")
  H.assert_true(managed.is_orchestrator(file, 12), "recognized as orchestrator")
  H.assert_false(managed.is_orchestrator(file, 99), "other pane is not the orchestrator")
  H.assert_nil(managed.read_orchestrator(file, "other"), "other ws has no orchestrator")
  managed.write_orchestrator(file, "ws", nil)
  H.assert_nil(managed.read_orchestrator(file, "ws"), "cleared")
end)

H.finish()
