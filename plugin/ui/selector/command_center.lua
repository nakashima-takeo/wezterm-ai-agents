-- Swarm console overlay: lists every agent pane and lets the human toggle which ones are
-- supervised by the orchestrator. Supervised (✓) and unsupervised (○) are shown in separate
-- sections; selecting a pane flips its membership and re-opens the console so multiple panes
-- can be toggled in place. The always-on tab/right-status carry the ambient cue and stay unchanged.
--
-- Data join: managed set (state/managed) X live state (service/agent.resolve) X mux panes.
-- Only panes still alive in the mux are shown, so closed panes self-hide.

local wezterm = require("wezterm")
local act = wezterm.action

local M = {}

local ui

-- selector/init.lua injects the shared UI helpers (selector/ui.lua).
function M.setup(ui_mod) ui = ui_mod end

-- Every alive pane that is either a detected agent or already in the managed set.
local function collect_rows(deps)
  local opts = deps.opts
  local set = deps.managed.read(opts.managed_file)
  local rows = {}
  for _, win in ipairs(wezterm.mux.all_windows()) do
    for _, tab in ipairs(win:tabs()) do
      for _, p in ipairs(tab:panes()) do
        local pid = p:pane_id()
        local impl, st = deps.agent.resolve(pid, opts)
        local is_managed = set[pid] == true
        if impl or is_managed then
          st = st or "idle"
          rows[#rows + 1] = {
            pane_id = pid,
            managed = is_managed,
            name = (impl and (impl.display_name or impl.id)) or "?",
            icon = (impl and impl.icons and impl.icons[st]) or "",
            color = (impl and impl.colors and impl.colors[st]) or nil,
            title = p:get_title() or "",
          }
        end
      end
    end
  end
  return rows
end

local function row_choice(r)
  local fmt = {
    { Foreground = { AnsiColor = r.managed and "Green" or "Grey" } },
    { Text = r.managed and "\xE2\x9C\x93 " or "\xE2\x97\x8B " }, -- ✓ / ○
    "ResetAttributes",
  }
  if r.color then table.insert(fmt, { Foreground = { Color = r.color } }) end
  if r.icon ~= "" then table.insert(fmt, { Text = r.icon .. " " }) end
  if r.color then table.insert(fmt, "ResetAttributes") end
  table.insert(fmt, { Text = r.name .. "  " .. r.title })
  return { id = "pane:" .. r.pane_id, label = wezterm.format(fmt) }
end

function M.swarm_overview(window, pane, deps)
  local L = deps.opts.labels
  local rows = collect_rows(deps)
  if #rows == 0 then
    ui.toast(window, L.swarm_empty)
    return
  end

  local supervised, unsupervised = {}, {}
  for _, r in ipairs(rows) do
    table.insert(r.managed and supervised or unsupervised, r)
  end

  local choices = {}
  local function add_section(title, list)
    if #list == 0 then return end
    table.insert(choices, { id = "_sep_" .. title, label = "── " .. title .. " ──" })
    for _, r in ipairs(list) do
      table.insert(choices, row_choice(r))
    end
  end
  add_section(L.swarm_supervised, supervised)
  add_section(L.swarm_unsupervised, unsupervised)

  window:perform_action(
    act.InputSelector({
      title = "Swarm",
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(iw, ip, id)
        if not id or id:match("^_sep_") then return end
        local pid = tonumber(id:match("^pane:(%d+)$"))
        if not pid then return end
        deps.managed.toggle(deps.opts.managed_file, pid)
        -- Re-open so the toggle's effect is visible and more panes can be managed in place.
        M.swarm_overview(iw, ip, deps)
      end),
    }),
    pane
  )
end

return M
