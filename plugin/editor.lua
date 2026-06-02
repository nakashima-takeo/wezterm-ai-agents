-- GUI editor detection and launch-argument construction.
-- Shared by selector.lua (open a folder) and links.lua (open a file at line:col).

local wezterm = require("wezterm")

local M = {}

local GUI_EDITORS = { "code", "cursor", "windsurf", "zed", "subl" }
local gui_editor_set = {}
for _, e in ipairs(GUI_EDITORS) do
  gui_editor_set[e] = true
end

local function basename(cmd) return cmd:match("([^/]+)$") or cmd end

local function is_gui_editor(cmd)
  if not cmd then return false end
  return gui_editor_set[basename(cmd)] ~= nil
end
M.is_gui_editor = is_gui_editor

-- explicit (opts.default_editor) を最優先。なければ VISUAL/EDITOR が GUI エディタなら採用、
-- 最後に PATH 上の既知 GUI エディタを検出する。検出は重いので一度だけ行いキャッシュする。
local cached_editor = nil
function M.detect(explicit)
  if explicit then return explicit end
  if cached_editor ~= nil then return cached_editor or nil end
  for _, env in ipairs({ "VISUAL", "EDITOR" }) do
    local val = os.getenv(env)
    if is_gui_editor(val) then
      cached_editor = val
      return val
    end
  end
  local query = "command -v " .. table.concat(GUI_EDITORS, " ") .. " 2>/dev/null | head -1"
  local ok, stdout = wezterm.run_child_process({ "/bin/sh", "-lc", query })
  if ok and stdout then
    local path = stdout:match("(%S+)")
    if path then
      cached_editor = path
      return path
    end
  end
  cached_editor = false
  return nil
end

-- background_child_process に渡す引数を組み立てる。行番号があれば該当行で開く:
-- VS Code 系 (code/cursor/windsurf) は `--goto file:line:col`、それ以外 (zed/subl) は
-- `file:line:col` を引数で直接受ける。行番号が無ければパスをそのまま渡す (ファイル/フォルダ共通)。
local VSCODE_LIKE = { code = true, cursor = true, windsurf = true }
function M.open_args(editor, path, line, col)
  if not line then return { editor, path } end
  local target = col and (path .. ":" .. line .. ":" .. col) or (path .. ":" .. line)
  if VSCODE_LIKE[basename(editor)] then return { editor, "--goto", target } end
  return { editor, target }
end

return M
