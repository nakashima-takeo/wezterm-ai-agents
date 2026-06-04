package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test = H.test

-- 各テストで dofile し直すため、モジュールローカル状態は毎回まっさら。
local function load_diag() return H.load_mod("service/diagnostics") end

H.section("診断通知機構 (diagnostics)")

test("report は同一 key で件数が増えず、message は上書きされる", function()
  local d = load_diag()
  d.report("jq", "jq が必要")
  d.report("jq", "jq が必要 (再)")
  local active = d.active()
  H.assert_eq(#active, 1, "active は1件のまま")
  H.assert_eq(active[1], "jq が必要 (再)", "後勝ちで上書き")
end)

test("take_pending は1回取ると空になる", function()
  local d = load_diag()
  d.report("a", "msg-a")
  d.report("b", "msg-b")
  H.assert_eq(#d.take_pending(), 2, "未通知2件を取得")
  H.assert_eq(#d.take_pending(), 0, "2回目は空")
end)

test("report 順に active が並ぶ", function()
  local d = load_diag()
  d.report("first", "1")
  d.report("second", "2")
  local active = d.active()
  H.assert_eq(active[1], "1")
  H.assert_eq(active[2], "2")
end)

test("active は resolve で消える", function()
  local d = load_diag()
  d.report("x", "msg-x")
  H.assert_eq(#d.active(), 1)
  d.resolve("x")
  H.assert_eq(#d.active(), 0)
end)

test("resolve 済みの key は再登録できる", function()
  local d = load_diag()
  d.report("y", "first")
  d.resolve("y")
  d.report("y", "second")
  local active = d.active()
  H.assert_eq(#active, 1)
  H.assert_eq(active[1], "second")
end)

test("未登録 key の resolve は無害", function()
  local d = load_diag()
  d.resolve("nope")
  H.assert_eq(#d.active(), 0)
end)

H.finish()
