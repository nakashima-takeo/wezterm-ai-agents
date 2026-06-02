-- Pane/tab layout tracking and restoration.
-- Layout is an array of { split = "right"|"bottom", pane = <0-indexed parent> } steps.

local M = {}

local BORDER_TOLERANCE = 2 -- pixel slack for pane border detection

function M.get_tab_index(window)
  local mux_win = window:mux_window()
  local active = mux_win:active_tab()
  for i, tab in ipairs(mux_win:tabs()) do
    if tab:tab_id() == active:tab_id() then return i end
  end
  return 1
end

-- Apply layout steps to spawn child panes off `pane`.
function M.apply(pane, layout, cwd)
  if type(layout) ~= "table" then return end
  local panes = { pane }
  for _, step in ipairs(layout) do
    local target_idx = (step.pane or 0) + 1
    local target = panes[target_idx]
    if target then
      local direction = step.split == "bottom" and "Bottom" or "Right"
      local new_pane = target:split({ direction = direction, cwd = cwd })
      table.insert(panes, new_pane)
    end
  end
end

-- Rebuild the layout array from current pane geometry.
function M.snapshot(tab)
  local panes_info = tab:panes_with_info()
  if #panes_info <= 1 then return nil end

  table.sort(panes_info, function(a, b)
    if a.top == b.top then return a.left < b.left end
    return a.top < b.top
  end)

  local layout = {}
  local processed = { [1] = true }
  local order = { 1 }

  while #order < #panes_info do
    local found = false
    for i = 1, #panes_info do
      if not processed[i] then
        local info = panes_info[i]
        for _, parent_idx in ipairs(order) do
          local parent = panes_info[parent_idx]
          if
            math.abs((parent.left + parent.width) - info.left) < BORDER_TOLERANCE
            and math.abs(parent.top - info.top) < BORDER_TOLERANCE
          then
            table.insert(layout, { split = "right", pane = parent_idx - 1 })
            processed[i] = true
            table.insert(order, i)
            found = true
            break
          end
          if
            math.abs((parent.top + parent.height) - info.top) < BORDER_TOLERANCE
            and math.abs(parent.left - info.left) < BORDER_TOLERANCE
          then
            table.insert(layout, { split = "bottom", pane = parent_idx - 1 })
            processed[i] = true
            table.insert(order, i)
            found = true
            break
          end
        end
        if found then break end
      end
    end
    if not found then break end
  end

  return #layout > 0 and layout or nil
end

-- ============== Workspace JSON mutations (require workspace module) ==============

local function default_tab() return {} end

local function ensure_tabs(ws, default_tabs)
  if type(ws.tabs) ~= "table" then
    ws.tabs = {}
    for _, t in ipairs(default_tabs or {}) do
      table.insert(ws.tabs, { agent = t.agent })
    end
  end
end

function M.add_split(window, pane, split_type, workspace_mod, plugin_opts)
  local data = workspace_mod.read(plugin_opts.workspace)
  local ws = workspace_mod.find(data, window:active_workspace())
  if not ws then return end

  ensure_tabs(ws, plugin_opts.default_tabs)
  local tab_idx = M.get_tab_index(window)
  if not ws.tabs[tab_idx] then ws.tabs[tab_idx] = default_tab() end
  if type(ws.tabs[tab_idx].layout) ~= "table" then ws.tabs[tab_idx].layout = {} end

  local mux_tab = window:mux_window():active_tab()
  local pane_idx = 0
  for j, p in ipairs(mux_tab:panes()) do
    if p:pane_id() == pane:pane_id() then
      pane_idx = j - 1
      break
    end
  end

  table.insert(ws.tabs[tab_idx].layout, { split = split_type, pane = pane_idx })
  workspace_mod.write(plugin_opts.workspace, data)
end

function M.add_tab(window, agent_id, workspace_mod, plugin_opts)
  local data = workspace_mod.read(plugin_opts.workspace)
  local ws = workspace_mod.find(data, window:active_workspace())
  if not ws then return end

  ensure_tabs(ws, plugin_opts.default_tabs)
  local entry = {}
  if agent_id then entry.agent = agent_id end
  table.insert(ws.tabs, entry)
  workspace_mod.write(plugin_opts.workspace, data)
end

function M.move_tab(window, direction, workspace_mod, plugin_opts)
  local data = workspace_mod.read(plugin_opts.workspace)
  local ws = workspace_mod.find(data, window:active_workspace())
  if not ws or type(ws.tabs) ~= "table" then return end

  local tab_idx = M.get_tab_index(window)
  local new_idx = tab_idx + direction
  if new_idx >= 1 and new_idx <= #ws.tabs then
    ws.tabs[tab_idx], ws.tabs[new_idx] = ws.tabs[new_idx], ws.tabs[tab_idx]
    workspace_mod.write(plugin_opts.workspace, data)
  end
end

function M.remove_tab(window, workspace_mod, plugin_opts)
  local data = workspace_mod.read(plugin_opts.workspace)
  local ws = workspace_mod.find(data, window:active_workspace())
  if not ws then return end

  ensure_tabs(ws, plugin_opts.default_tabs)
  if #ws.tabs > 1 then
    table.remove(ws.tabs, M.get_tab_index(window))
    workspace_mod.write(plugin_opts.workspace, data)
  end
end

function M.refresh_after_pane_close(window, workspace_mod, plugin_opts)
  local data = workspace_mod.read(plugin_opts.workspace)
  local ws = workspace_mod.find(data, window:active_workspace())
  if not ws then return end

  ensure_tabs(ws, plugin_opts.default_tabs)
  local tab_idx = M.get_tab_index(window)
  if ws.tabs[tab_idx] then
    ws.tabs[tab_idx].layout = M.snapshot(window:mux_window():active_tab())
    workspace_mod.write(plugin_opts.workspace, data)
  end
end

return M
