-- Default tab title and right-status renderers.
-- Either install via init.lua's apply() flags, or call helpers from your own handlers.

local wezterm = require("wezterm")

local M = {}

-- ============== Path shortening (~/dev/projects/myapp → ~/d/p/myapp) ==============

local function shorten_path(path)
  local prefix = path:match("^/") and "/" or ""
  local parts = {}
  for part in string.gmatch(path, "[^/]+") do
    table.insert(parts, part)
  end
  if #parts == 0 then return path end
  for i = 1, #parts - 1 do
    if parts[i] ~= "~" then parts[i] = parts[i]:sub(1, 1) end
  end
  return prefix .. table.concat(parts, "/")
end

local function pane_cwd_str(pane)
  local cwd = pane:get_current_working_dir()
  if not cwd then return "" end
  local raw = cwd.file_path or tostring(cwd):gsub("^file://[^/]*", "")
  local home = wezterm.home_dir
  if raw == home or raw:sub(1, #home + 1) == home .. "/" then raw = "~" .. raw:sub(#home + 1) end
  return shorten_path(raw)
end

M.shorten_path = shorten_path
M.pane_cwd_str = pane_cwd_str

local function display_cols(s)
  local n = 0
  for i = 1, #s do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then n = n + 1 end
  end
  return n
end

-- Keep the rightmost portion of the path and left-pad to a fixed column width.
local function fixed_width(s, w)
  s = wezterm.truncate_left(s, w)
  local cols = display_cols(s)
  if cols < w then s = string.rep(" ", w - cols) .. s end
  return s
end

-- ============== Tab title ==============

local function pane_agent_info(pane_id, deps)
  local pane = wezterm.mux.get_pane(pane_id)
  if not pane then return nil, nil end
  local impl, agent_opts = deps.agent.detect(pane, deps.opts)
  if not impl then return nil, nil end
  local st = impl.state(pane, agent_opts)
  local icon = impl.icons and impl.icons[st] or nil
  local color = impl.colors and impl.colors[st] or nil
  return icon, color, st
end

M.pane_agent_icon = function(pane_id, deps)
  local icon, _ = pane_agent_info(pane_id, deps)
  return icon
end

function M.format_tab_title(tab, deps, max_width, num_tabs)
  local theme = deps.opts.ui.tab_title
  local icon, icon_color, st = pane_agent_info(tab.active_pane.pane_id, deps)
  if st == "idle" then icon = nil end
  icon = icon or ""
  local full = tab.active_pane.title or ""

  local effective_max = max_width or theme.max_chars
  local reserve = theme.right_status_reserve or 48
  -- タブバーは右ステータスと同一行を共有するため、ウィンドウ全幅から reserve を引いてタブ幅を割り当てる。
  -- format-tab-title は max_width に右ステータス分を含めない値を渡してくるため、ここで自前算出する必要がある。
  local mux_win = tab.window_id and wezterm.mux.get_window(tab.window_id)
  local tab_bar_cols = mux_win and mux_win:active_tab():get_size().cols or 0
  if num_tabs and num_tabs > 0 and tab_bar_cols > 0 then
    local per_tab = math.floor((tab_bar_cols - reserve) / num_tabs)
    effective_max = math.min(effective_max, per_tab)
  end
  local avail = math.max(1, math.min(theme.max_chars, effective_max - 4))
  if icon ~= "" then avail = avail - 2 end
  local title = wezterm.truncate_right(full, avail)
  if title ~= full then title = title .. "…" end

  if tab.is_active then
    local r = {
      { Background = { Color = theme.active_bg } },
      { Foreground = { Color = theme.accent_fg } },
      { Text = " ▎" },
    }
    if icon ~= "" and icon_color then
      table.insert(r, { Foreground = { Color = icon_color } })
      table.insert(r, { Text = icon .. " " })
      table.insert(r, { Foreground = { Color = theme.active_fg } })
    else
      table.insert(r, { Foreground = { Color = theme.active_fg } })
      if icon ~= "" then table.insert(r, { Text = icon .. " " }) end
    end
    table.insert(r, { Text = title .. " " })
    return r
  end

  local r = {
    { Background = { Color = theme.inactive_bg } },
  }
  if icon ~= "" and icon_color then
    table.insert(r, { Foreground = { Color = theme.inactive_fg } })
    table.insert(r, { Text = "  " })
    table.insert(r, { Foreground = { Color = icon_color } })
    table.insert(r, { Text = icon .. " " })
    table.insert(r, { Foreground = { Color = theme.inactive_fg } })
  else
    table.insert(r, { Foreground = { Color = theme.inactive_fg } })
    table.insert(r, { Text = "  " .. (icon ~= "" and icon .. " " or "") })
  end
  table.insert(r, { Text = title .. " " })
  return r
end

-- ============== Right status ==============

local STATE_ORDER = { "working", "waiting", "done", "idle", "error", "unknown" }

local function agent_count_segments(plugin_opts, agent_mod, colors, icons)
  local c = agent_mod.count(plugin_opts)
  local segs = {}
  for _, key in ipairs(STATE_ORDER) do
    local n = c[key] or 0
    if n > 0 and colors[key] and icons[key] then
      table.insert(segs, { Foreground = { Color = colors[key] } })
      table.insert(segs, { Text = "  " .. icons[key] .. " " .. n })
    end
  end
  return segs
end

M.agent_count_segments = agent_count_segments

function M.right_status_segments(window, pane, deps)
  local opts = deps.opts
  local theme = opts.ui.right_status
  local rs = {}

  local win_id = tostring(window:window_id())
  if deps.selector and deps.selector.pinned_windows[win_id] then
    table.insert(rs, { Foreground = { Color = theme.pin_color or "#b4befe" } })
    table.insert(rs, { Text = "  " .. (theme.pin_icon or "") })
  end

  if opts.right_status_extra and type(opts.right_status_extra) == "function" then
    local extras = opts.right_status_extra(window, pane, deps)
    if type(extras) == "table" then
      for _, e in ipairs(extras) do
        table.insert(rs, e)
      end
    end
  end

  for _, seg in ipairs(agent_count_segments(opts, deps.agent, theme.colors, theme.icons)) do
    table.insert(rs, seg)
  end

  table.insert(rs, { Foreground = { Color = theme.fg } })
  table.insert(rs, {
    Text = "  " .. fixed_width(pane_cwd_str(pane), theme.cwd_width or 20) .. "  |  " .. window:active_workspace() .. "  ",
  })
  return rs
end

return M
