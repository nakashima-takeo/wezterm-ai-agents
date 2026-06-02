-- Clickable file paths in terminal output (opt-in via opts.editor_links).
--
-- WezTerm has no built-in way to make file paths clickable (default_hyperlink_rules
-- match only URLs/emails) and cannot validate file existence at underline time. So we
-- register hyperlink_rules that map paths to custom editor:// / editor-rel:// schemes,
-- then resolve+validate them on click in the open-uri handler. Non-existent paths are
-- silently ignored (the scheme is still consumed so it never falls through to the browser).
--
-- This is disabled by default: matched-but-unopenable paths still show a hover underline,
-- which can erode trust in links. Enable it where the tradeoff is worth it.

local wezterm = require("wezterm")

local M = {}

-- 厳格な regex 3本。誤爆 (実在しないパスへの過剰な下線) を抑えるため、
-- 絶対パスは2階層以上、相対は ./ ../ 始まり、それ以外は拡張子必須に絞る。
function M.rules()
  return {
    { regex = [[(?<!\w)(?:/[\w.@+-]+){2,}(?::\d+(?::\d+)?)?]], format = "editor://$0" },
    { regex = [[\.\.?/[\w.@+-]+(?:/[\w.@+-]+)*(?::\d+(?::\d+)?)?]], format = "editor-rel://$0" },
    -- 末尾に拡張子を必須化し、feat/foo・docs.rs/regex 等の非パスへの過剰マッチを防ぐ
    { regex = [[\b[\w.@+-]+/(?:[\w.@+-]+/)*[\w.@+-]+\.[\w]+(?::\d+(?::\d+)?)?]], format = "editor-rel://$0" },
  }
end

-- 末尾の行/列指定を切り出す。戻り値: path, line(number|nil), col(number|nil)。
-- 対応形式: path:line:col / path:line (rules() の正規表現が捕捉する形式に対応)
function M.parse_target(s)
  local f, l, c = s:match("^(.+):(%d+):(%d+)$")
  if f then return f, tonumber(l), tonumber(c) end
  f, l = s:match("^(.+):(%d+)$")
  if f then return f, tonumber(l), nil end
  return s, nil, nil
end

-- git diff の a/ b/ 接頭辞を剥がした候補を、元のパスと共に優先順で返す。
-- 例: "a/src/main.rs" -> { "a/src/main.rs", "src/main.rs" }。剥がし結果が同一なら1つだけ。
function M.diff_candidates(path)
  local stripped = path:gsub("^[ab]/", "")
  if stripped == path then return { path } end
  return { path, stripped }
end

-- uri が自スキーム (editor:// / editor-rel://) かどうか。
function M.is_editor_uri(uri) return uri:match("^editor://") ~= nil or uri:match("^editor%-rel://") ~= nil end

-- uri を解決して、開くべき絶対パスと行/列を返す。editor-rel:// は cwd 基準で解決する。
-- exists(path)->bool は存在判定 (テスト用に注入可能)。実在候補が無い/自スキームでない場合は nil。
-- git diff の a/ b/ 接頭辞付きと素のパスの両方を候補にし、実在する最初のものを採る。
function M.resolve(uri, cwd, exists)
  local raw, is_rel
  if uri:match("^editor://") then
    raw = uri:gsub("^editor://", "")
  elseif uri:match("^editor%-rel://") then
    raw = uri:gsub("^editor%-rel://", "")
    is_rel = true
  else
    return nil
  end
  if is_rel and not cwd then return nil end

  local file, line, col = M.parse_target(raw)
  for _, cand in ipairs(M.diff_candidates(file)) do
    local abs = is_rel and (cwd .. "/" .. cand) or cand
    if exists(abs) then return abs, line, col end
  end
  return nil
end

local function file_exists(p)
  local fh = io.open(p, "r")
  if not fh then return false end
  fh:close()
  return true
end

-- 実在する候補をエディタで開く。自スキームは実在しなくても常に握る (return false) ため、
-- 開けない時もブラウザには渡さない。他スキームは WezTerm の既定動作に委ねる (return nil)。
local function handle(_window, pane, uri, deps)
  if not M.is_editor_uri(uri) then return end
  local abs, line, col = M.resolve(uri, deps.workspace.get_cwd_path(pane), file_exists)
  if abs then
    local editor = deps.editor.detect(deps.opts.default_editor)
    if editor then wezterm.background_child_process(deps.editor.open_args(editor, abs, line, col)) end
  end
  return false
end

-- hyperlink_rules を (既定ルールを土台に) 追加し、open-uri ハンドラを登録する。
function M.setup(config, deps)
  config.hyperlink_rules = config.hyperlink_rules or wezterm.default_hyperlink_rules()
  for _, rule in ipairs(M.rules()) do
    table.insert(config.hyperlink_rules, rule)
  end
  wezterm.on("open-uri", function(window, pane, uri) return handle(window, pane, uri, deps) end)
end

return M
