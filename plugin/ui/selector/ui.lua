-- Shared formatting/UI helpers for the selector sub-modules.
-- Pure presentation given `deps`; injected into selector/workspace.lua and
-- selector/worktree.lua via their setup() so both share one implementation.

local wezterm = require("wezterm")
local act = wezterm.action

local M = {}

function M.toast(window, msg, ms) window:toast_notification("WezTerm", msg, nil, ms or 3000) end

function M.build_ws_header(fmt, ws_name, is_running)
  if is_running then
    table.insert(fmt, { Foreground = { AnsiColor = "Green" } })
    table.insert(fmt, { Text = "● " })
  else
    table.insert(fmt, { Foreground = { AnsiColor = "Grey" } })
    table.insert(fmt, { Text = "▸ " })
  end
  table.insert(fmt, { Attribute = { Intensity = "Bold" } })
  table.insert(fmt, { Foreground = { AnsiColor = "Aqua" } })
  table.insert(fmt, { Text = ws_name })
  table.insert(fmt, "ResetAttributes")
end

local CHIP_STATE_ORDER = { "working", "waiting", "done", "idle", "error" }

function M.append_agents_colored(fmt, deps, ws_name)
  local c = deps.agent.count(deps.opts, ws_name)
  local colors = deps.opts.ui.right_status.colors
  local icons = deps.opts.ui.right_status.icons
  local any = false
  for _, key in ipairs(CHIP_STATE_ORDER) do
    local n = c[key] or 0
    if n > 0 and colors[key] and icons[key] then
      local suffix = n > 1 and ("\xC3\x97" .. n) or ""
      table.insert(fmt, { Foreground = { Color = colors[key] } })
      table.insert(fmt, { Text = (any and " " or "  ") .. icons[key] .. " " .. suffix })
      any = true
    end
  end
  return any
end

function M.append_ws_status(fmt, ws, is_running, deps)
  if is_running then
    M.append_agents_colored(fmt, deps, ws.name)
  else
    local saved = deps.workspace.count_saved_sessions(ws)
    if saved > 0 then
      local idle_icon = deps.opts.ui.right_status.icons.idle or ""
      table.insert(fmt, { Foreground = { AnsiColor = "Grey" } })
      table.insert(fmt, { Text = "  " .. idle_icon .. " \xC3\x97" .. saved })
    end
  end
end

function M.shorten_path(path)
  local home = wezterm.home_dir
  if path == home or path:sub(1, #home + 1) == home .. "/" then return "~" .. path:sub(#home + 1) end
  return path
end

-- List immediate subdirectories (incl. hidden) of `dir`, sorted, names only.
function M.list_subdirs(dir)
  local ok, stdout = wezterm.run_child_process({ "ls", "-1Ap", "--", dir })
  if not ok or not stdout then return {} end
  local dirs = {}
  for line in stdout:gmatch("[^\n]+") do
    if line:sub(-1) == "/" then table.insert(dirs, line:sub(1, -2)) end
  end
  return dirs
end

function M.parent_dir(dir)
  local parent = dir:gsub("/+$", ""):gsub("/[^/]*$", "")
  if parent == "" then return "/" end
  return parent
end

-- ============== Help ==============

-- Nerd Font: Apple 修飾キー専用グリフ。PUA の単一セルグリフなので桁ずれ・被りが起きない
local nf = wezterm.nerdfonts
local NERD_KEYS = {
  LeftArrow = nf.md_arrow_left_bold,
  RightArrow = nf.md_arrow_right_bold,
  UpArrow = nf.md_arrow_up_bold,
  DownArrow = nf.md_arrow_down_bold,
  Enter = nf.md_keyboard_return,
  Backspace = nf.md_keyboard_backspace,
}
local NERD_MODS = {
  { "CTRL", nf.md_apple_keyboard_control },
  { "OPT", nf.md_apple_keyboard_option },
  { "SHIFT", nf.md_apple_keyboard_shift },
  { "CMD", nf.md_apple_keyboard_command },
}
-- Unicode フォールバック (nerd_font = false 時)。⇧ と矢印は ambiguous width なのでスペースで分離する
local UNICODE_KEYS = {
  LeftArrow = "\xE2\x86\x90", -- ←
  RightArrow = "\xE2\x86\x92", -- →
  UpArrow = "\xE2\x86\x91", -- ↑
  DownArrow = "\xE2\x86\x93", -- ↓
  Enter = "\xE2\x8F\x8E", -- ⏎
  Backspace = "\xE2\x8C\xAB", -- ⌫
}
-- mac 慣習の表示順 (⌃⌥⇧⌘)
local UNICODE_MODS = {
  { "CTRL", "\xE2\x8C\x83" }, -- ⌃
  { "OPT", "\xE2\x8C\xA5" }, -- ⌥
  { "SHIFT", "\xE2\x87\xA7" }, -- ⇧
  { "CMD", "\xE2\x8C\x98" }, -- ⌘
}

function M.format_keybind(key, mods, nerd)
  -- NERD_MODS は Apple キーボード印字専用グリフなので darwin 限定。non-darwin では nerd でも
  -- 汎用 Unicode 記号 (⌃⌥⇧⌘) に倒す (Apple グリフを持たない Nerd Font で豆腐化するのを防ぐ)。
  local apple_mods = nerd and wezterm.target_triple:find("darwin") ~= nil
  local mod_set = apple_mods and NERD_MODS or UNICODE_MODS
  local key_set = nerd and NERD_KEYS or UNICODE_KEYS
  local present = {}
  for m in mods:gmatch("[^|]+") do
    present[m] = true
  end
  local parts = {}
  for _, pair in ipairs(mod_set) do
    if present[pair[1]] then
      table.insert(parts, pair[2])
      present[pair[1]] = nil
    end
  end
  for m in mods:gmatch("[^|]+") do
    if present[m] then table.insert(parts, m) end -- 記号未定義の修飾キーはそのまま
  end
  table.insert(parts, key_set[key] or key)
  -- 記号/グリフが詰まって見えないよう間にスペースを挟む
  return table.concat(parts, " ")
end

function M.help_selector(window, pane, deps, items)
  local L = deps.opts.labels
  local choices = {}
  local last_group = nil
  for i, it in ipairs(items) do
    if it.group ~= last_group then
      last_group = it.group
      table.insert(choices, { id = "_sep_" .. i, label = "── " .. (L[it.group] or it.group) .. " ──" })
    end
    local fmt = {
      { Attribute = { Intensity = "Bold" } },
      { Foreground = { AnsiColor = "Aqua" } },
      { Text = M.format_keybind(it.key, it.mods, deps.opts.nerd_font) },
      "ResetAttributes",
      { Text = "  " .. (L[it.desc] or it.desc) },
    }
    table.insert(choices, { id = "item:" .. i, label = wezterm.format(fmt) })
  end

  window:perform_action(
    act.InputSelector({
      title = "Help",
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(iw, ip, id)
        if not id or id:match("^_sep_") then return end
        local i = tonumber(id:match("^item:(%d+)$"))
        local it = i and items[i]
        if it and it.runnable and it.action then iw:perform_action(it.action, ip) end
      end),
    }),
    pane
  )
end

return M
