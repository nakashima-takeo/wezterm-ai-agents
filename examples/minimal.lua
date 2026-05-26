-- Minimal configuration: all defaults, all agents enabled.
-- Copy this into your ~/.wezterm.lua and adjust as needed.

local wezterm = require("wezterm")
local config = wezterm.config_builder()

local ai = wezterm.plugin.require("https://github.com/nakashima-takeo/wezterm-ai-agents")
ai.apply(config, {})

return config
