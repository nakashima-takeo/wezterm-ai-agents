# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

WezTerm plugin for orchestrating parallel AI coding agent sessions. Lua (LuaJIT) codebase running inside WezTerm's Lua sandbox. The plugin manages persistent workspaces, git worktree integration, and AI agent state tracking via tab/pane UI.

## Commands

```bash
# Lint
luacheck .

# Format check
stylua --check .

# Format fix
stylua .

# Run all tests (requires luajit)
bash test/run.sh

# Run single test
luajit test/test_agent.lua
```

## Architecture

The plugin loads via `plugin/init.lua` which `dofile`s all other modules. WezTerm's Lua sandbox provides `wezterm` and `mux` globals but lacks the `debug` library.

**Module dependency flow:**
```
init.lua (entry point, apply() wires everything)
├── workspace.lua  — JSON persistence, CRUD, snapshot/sync of tab state
├── worktree.lua   — git worktree operations (list/add/remove/prune)
├── layout.lua     — pane split layout snapshot/restore
├── selector.lua   — InputSelector-based UI + keybind registration
├── agent.lua      — agent registry, detection, state aggregation, shared JSON reader
│   ├── agents/claude.lua — Claude Code implementation
│   ├── agents/codex.lua  — OpenAI Codex CLI implementation
│   ├── agents/cursor.lua — Cursor Agent CLI implementation
│   └── agents/gemini.lua — Google Gemini CLI implementation
└── ui.lua         — tab title formatting, right-status bar rendering
```

**Key patterns:**
- Modules are loaded via `dofile()` (no `require()` for plugin modules) — WezTerm sandbox constraint
- Agent state is push-driven via hooks writing a unified JSON file per pane: `/tmp/wezterm-agent-<pane_id>`
- `hooks/agent_status.sh` is the writer side (shared by all agents); Lua reads JSON with `wezterm.json_parse()`
- JSON format: `{"agent":"<id>","state":"<state>","ts":<unix>,"session_id":"<sid>"}`
- Workspace data persists to `~/.wezterm-workspaces.json` with atomic write (tmp + rename)
- Cyclic module dependencies are broken by passing modules as function arguments (`agent_mod`, `layout_mod`)

## Testing

Tests use LuaJIT with a mock wezterm module (`test/mock_wezterm.lua`). Test files follow `test/test_*.lua` pattern. Each test file requires `test/helper.lua` which sets up the mock and provides assertions.

To add a test: create `test/test_<name>.lua`, require helper, use `H.test(name, fn)` / `H.finish()`.

## Code Style

- LuaJIT target (`std = "luajit"` in luacheckrc)
- StyLua: 2-space indent, 140 column width, double quotes preferred
- Max line length: 140 chars
- Globals allowed: `wezterm` (luacheck); `mux` used directly in runtime but not declared (WezTerm provides it)

## Adding a New Agent

1. Create `plugin/agents/<id>.lua` implementing the interface defined in `plugin/agent.lua` (detect, state, session_id, spawn_args, etc.). Detection uses the unified JSON state file — check `data.agent == "<id>"`.
2. Register in `init.lua` via `agent.register(load("agents/<id>"))`.
3. Configure the agent's hooks to call `hooks/agent_status.sh <id> <state>` (or write the same JSON format directly).
