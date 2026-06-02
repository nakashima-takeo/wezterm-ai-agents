package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test, load_mod = H.test, H.load_mod

local links = load_mod("links")
local editor = load_mod("editor")

H.section("links.parse_target — 行/列の切り出し")

test("path:line:col を分解する", function()
  local f, l, c = links.parse_target("src/main.rs:10:3")
  H.assert_eq(f, "src/main.rs")
  H.assert_eq(l, 10)
  H.assert_eq(c, 3)
end)

test("path:line を分解する (列なし)", function()
  local f, l, c = links.parse_target("src/main.rs:10")
  H.assert_eq(f, "src/main.rs")
  H.assert_eq(l, 10)
  H.assert_nil(c)
end)

test("path#line を分解する", function()
  local f, l, c = links.parse_target("docs/readme.md#42")
  H.assert_eq(f, "docs/readme.md")
  H.assert_eq(l, 42)
  H.assert_nil(c)
end)

test("行指定なしはパスのみ返す", function()
  local f, l, c = links.parse_target("src/main.rs")
  H.assert_eq(f, "src/main.rs")
  H.assert_nil(l)
  H.assert_nil(c)
end)

test("絶対パス + 行:列", function()
  local f, l, c = links.parse_target("/abs/path/file.rs:5:2")
  H.assert_eq(f, "/abs/path/file.rs")
  H.assert_eq(l, 5)
  H.assert_eq(c, 2)
end)

H.section("links.diff_candidates — git diff の a/ b/ 剥がし")

test("a/ 接頭辞を剥がした候補を追加する", function()
  local c = links.diff_candidates("a/src/main.rs")
  H.assert_eq(#c, 2)
  H.assert_eq(c[1], "a/src/main.rs")
  H.assert_eq(c[2], "src/main.rs")
end)

test("b/ 接頭辞を剥がした候補を追加する", function()
  local c = links.diff_candidates("b/lib/util.go")
  H.assert_eq(c[2], "lib/util.go")
end)

test("接頭辞がなければ元のパスのみ", function()
  local c = links.diff_candidates("src/main.rs")
  H.assert_eq(#c, 1)
  H.assert_eq(c[1], "src/main.rs")
end)

test("絶対パスは a/ b/ 剥がしの対象外", function()
  local c = links.diff_candidates("/abs/file.rs")
  H.assert_eq(#c, 1)
  H.assert_eq(c[1], "/abs/file.rs")
end)

H.section("editor.open_args — エディタ別の起動引数")

test("VS Code 系は --goto file:line:col", function()
  local a = editor.open_args("/usr/local/bin/cursor", "/a/b.rs", 10, 3)
  H.assert_eq(a[1], "/usr/local/bin/cursor")
  H.assert_eq(a[2], "--goto")
  H.assert_eq(a[3], "/a/b.rs:10:3")
end)

test("VS Code 系 (code) で列なしは file:line", function()
  local a = editor.open_args("code", "f.rs", 10, nil)
  H.assert_eq(a[2], "--goto")
  H.assert_eq(a[3], "f.rs:10")
end)

test("zed は --goto を使わず file:line:col を直接渡す", function()
  local a = editor.open_args("zed", "f.rs", 10, 3)
  H.assert_eq(a[1], "zed")
  H.assert_eq(a[2], "f.rs:10:3")
  H.assert_nil(a[3])
end)

test("subl も file:line:col を直接渡す", function()
  local a = editor.open_args("subl", "f.rs", 7, nil)
  H.assert_eq(a[1], "subl")
  H.assert_eq(a[2], "f.rs:7")
end)

test("行番号がなければパスをそのまま渡す (フォルダ等)", function()
  local a = editor.open_args("code", "/some/dir", nil, nil)
  H.assert_eq(a[1], "code")
  H.assert_eq(a[2], "/some/dir")
  H.assert_nil(a[3])
end)

H.section("links.is_editor_uri — 自スキーム判定")

test("editor:// と editor-rel:// は自スキーム", function()
  H.assert_true(links.is_editor_uri("editor:///abs/file.rs"))
  H.assert_true(links.is_editor_uri("editor-rel://src/main.rs"))
end)

test("他スキームは自スキームでない", function()
  H.assert_false(links.is_editor_uri("https://example.com"))
  H.assert_false(links.is_editor_uri("mailto:a@b.com"))
end)

H.section("links.resolve — uri 解決ロジック (存在判定を注入)")

-- 指定パス集合だけ実在扱いする存在判定関数を作る
local function exists_in(set)
  return function(p) return set[p] == true end
end

test("editor:// 絶対パスが実在すれば行/列付きで返す", function()
  local abs, l, c = links.resolve("editor:///abs/file.rs:10:3", nil, exists_in({ ["/abs/file.rs"] = true }))
  H.assert_eq(abs, "/abs/file.rs")
  H.assert_eq(l, 10)
  H.assert_eq(c, 3)
end)

test("editor:// 絶対パスが実在しなければ nil", function()
  local abs = links.resolve("editor:///abs/missing.rs", nil, exists_in({}))
  H.assert_nil(abs)
end)

test("editor-rel:// は cwd 基準で解決する", function()
  local abs, l = links.resolve("editor-rel://src/main.rs:5", "/home/proj", exists_in({ ["/home/proj/src/main.rs"] = true }))
  H.assert_eq(abs, "/home/proj/src/main.rs")
  H.assert_eq(l, 5)
end)

test("editor-rel:// で cwd が無ければ nil", function()
  local abs = links.resolve("editor-rel://src/main.rs", nil, exists_in({ ["src/main.rs"] = true }))
  H.assert_nil(abs)
end)

test("git diff の a/ 接頭辞付きが実在しなくても素のパスが実在すれば開く", function()
  local abs = links.resolve(
    "editor-rel://a/src/main.rs",
    "/home/proj",
    exists_in({ ["/home/proj/src/main.rs"] = true }) -- a/ 付きは無い
  )
  H.assert_eq(abs, "/home/proj/src/main.rs")
end)

test("a/ 付きが実在すればそちらを優先する (剥がし前が先)", function()
  local abs = links.resolve(
    "editor-rel://a/src/main.rs",
    "/home/proj",
    exists_in({ ["/home/proj/a/src/main.rs"] = true, ["/home/proj/src/main.rs"] = true })
  )
  H.assert_eq(abs, "/home/proj/a/src/main.rs")
end)

test("他スキームは nil (既定動作に委ねる)", function()
  local abs = links.resolve("https://example.com/a/b.rs", "/home/proj", exists_in({ ["/home/proj/https:/example.com/a/b.rs"] = true }))
  H.assert_nil(abs)
end)

H.section("links.setup — hyperlink_rules 追加と open-uri 登録")

test("rules が3本追加され open-uri が登録される", function()
  wezterm._events = {}
  local config = {}
  links.setup(config, { editor = editor, opts = {} })
  H.assert_eq(#config.hyperlink_rules, 3) -- mock の default_hyperlink_rules は空
  H.assert_not_nil(wezterm._events["open-uri"])
end)

H.section("editor.is_gui_editor — basename 判定")

test("フルパスでも basename で判定する", function()
  H.assert_true(editor.is_gui_editor("/usr/local/bin/cursor"))
  H.assert_true(editor.is_gui_editor("code"))
  H.assert_false(editor.is_gui_editor("vim"))
  H.assert_false(editor.is_gui_editor(nil))
end)

H.finish()
