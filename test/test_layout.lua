package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test, load_mod = H.test, H.load_mod

local function mock_tab(panes_info)
  return { panes_with_info = function() return panes_info end }
end

local function mock_splittable_pane(id)
  local p = { _id = id, _splits = {} }
  p.split = function(_, opts)
    local child = mock_splittable_pane(id .. "." .. (#p._splits + 1))
    table.insert(p._splits, { direction = opts.direction, child = child })
    return child
  end
  return p
end

H.section("レイアウトスナップショット")

test("正常系：水平分割のレイアウトをスナップショットできる", function()
  -- +------+------+
  -- |  p0  |  p1  |
  -- +------+------+
  local layout = load_mod("state/layout")
  local tab = mock_tab({
    { top = 0, left = 0, width = 40, height = 24 },
    { top = 0, left = 41, width = 40, height = 24 },
  })

  local snap = layout.snapshot(tab)

  H.assert_not_nil(snap)
  H.assert_eq(#snap, 1)
  H.assert_eq(snap[1].split, "right")
  H.assert_eq(snap[1].pane, 0)
end)

test("正常系：垂直分割のレイアウトをスナップショットできる", function()
  -- +-------------+
  -- |     p0      |
  -- +-------------+
  -- |     p1      |
  -- +-------------+
  local layout = load_mod("state/layout")
  local tab = mock_tab({
    { top = 0, left = 0, width = 80, height = 12 },
    { top = 13, left = 0, width = 80, height = 12 },
  })

  local snap = layout.snapshot(tab)

  H.assert_not_nil(snap)
  H.assert_eq(#snap, 1)
  H.assert_eq(snap[1].split, "bottom")
  H.assert_eq(snap[1].pane, 0)
end)

test("正常系：3ペインの複合レイアウトをスナップショットできる", function()
  -- +------+------+
  -- |      |  p1  |
  -- |  p0  +------+
  -- |      |  p2  |
  -- +------+------+
  local layout = load_mod("state/layout")
  local tab = mock_tab({
    { top = 0, left = 0, width = 40, height = 24 },
    { top = 0, left = 41, width = 40, height = 12 },
    { top = 13, left = 41, width = 40, height = 12 },
  })

  local snap = layout.snapshot(tab)

  H.assert_not_nil(snap)
  H.assert_eq(#snap, 2)
  H.assert_eq(snap[1].split, "right")
  H.assert_eq(snap[1].pane, 0)
  H.assert_eq(snap[2].split, "bottom")
  H.assert_eq(snap[2].pane, 1)
end)

test("正常系：単一ペインの場合はnilを返す", function()
  local layout = load_mod("state/layout")
  local tab = mock_tab({
    { top = 0, left = 0, width = 80, height = 24 },
  })

  H.assert_nil(layout.snapshot(tab))
end)

H.section("レイアウト復元")

test("正常系：スナップショットからペイン分割を再現できる", function()
  local layout = load_mod("state/layout")
  local root = mock_splittable_pane("root")
  local snap = {
    { split = "right", pane = 0 },
    { split = "bottom", pane = 1 },
  }

  layout.apply(root, snap, "/tmp")

  H.assert_eq(#root._splits, 1)
  H.assert_eq(root._splits[1].direction, "Right")
  local child1 = root._splits[1].child
  H.assert_eq(#child1._splits, 1)
  H.assert_eq(child1._splits[1].direction, "Bottom")
end)

test("正常系：nilや空のレイアウトでは分割しない", function()
  local layout = load_mod("state/layout")
  local root = mock_splittable_pane("root")

  layout.apply(root, nil, "/tmp")
  H.assert_eq(#root._splits, 0)

  layout.apply(root, {}, "/tmp")
  H.assert_eq(#root._splits, 0)
end)

H.section("レイアウト snapshot→apply 往復")

test("正常系：縦横混在3ペインを往復しても元の分割木が再現される", function()
  -- +------+------+   p0 左, p1 右上, p2 右下
  -- |      |  p1  |
  -- |  p0  +------+
  -- |      |  p2  |
  -- +------+------+
  local layout = load_mod("state/layout")
  local tab = mock_tab({
    { top = 0, left = 0, width = 40, height = 24 },
    { top = 0, left = 41, width = 40, height = 12 },
    { top = 13, left = 41, width = 40, height = 12 },
  })

  local snap = layout.snapshot(tab)
  local root = mock_splittable_pane("root")
  layout.apply(root, snap, "/tmp")

  -- snapshot の pane インデックスと apply の親参照体系が一致して初めてこの木になる:
  -- root を Right 分割→child1、child1 を Bottom 分割→child2。
  H.assert_eq(#root._splits, 1)
  H.assert_eq(root._splits[1].direction, "Right")
  local child1 = root._splits[1].child
  H.assert_eq(#child1._splits, 1)
  H.assert_eq(child1._splits[1].direction, "Bottom")
  -- 末端 (child2) はそれ以上分割されない
  H.assert_eq(#child1._splits[1].child._splits, 0)
end)

test("正常系：直列の右分割3ペインを往復しても親参照がずれない", function()
  -- +------+------+------+   p0 | p1 | p2 (すべて右隣)
  -- |  p0  |  p1  |  p2  |
  -- +------+------+------+
  local layout = load_mod("state/layout")
  local tab = mock_tab({
    { top = 0, left = 0, width = 40, height = 24 },
    { top = 0, left = 41, width = 40, height = 24 },
    { top = 0, left = 82, width = 40, height = 24 },
  })

  local snap = layout.snapshot(tab)
  local root = mock_splittable_pane("root")
  layout.apply(root, snap, "/tmp")

  -- root→Right→child1、child1→Right→child2 (p2 は p1 の右なので親は child1)
  H.assert_eq(#root._splits, 1)
  H.assert_eq(root._splits[1].direction, "Right")
  local child1 = root._splits[1].child
  H.assert_eq(#child1._splits, 1)
  H.assert_eq(child1._splits[1].direction, "Right")
end)

H.finish()
