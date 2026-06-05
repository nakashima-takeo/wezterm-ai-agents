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
  local out = d.take_pending()
  H.assert_eq(#out, 1, "1件のまま")
  H.assert_eq(out[1], "jq が必要 (再)", "後勝ちで上書き")
end)

test("take_pending は登録順で返し、1回取ると空になる", function()
  local d = load_diag()
  d.report("a", "msg-a")
  d.report("b", "msg-b")
  local first = d.take_pending()
  H.assert_eq(#first, 2)
  H.assert_eq(first[1], "msg-a")
  H.assert_eq(first[2], "msg-b")
  H.assert_eq(#d.take_pending(), 0, "2回目は空")
end)

test("take_pending 後に同じ key を再登録できる", function()
  local d = load_diag()
  d.report("x", "first")
  d.take_pending()
  d.report("x", "second")
  local out = d.take_pending()
  H.assert_eq(#out, 1)
  H.assert_eq(out[1], "second")
end)

H.finish()
