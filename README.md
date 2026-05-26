# wezterm-ai-agents

[![CI](https://github.com/nakashima-takeo/wezterm-ai-agents/actions/workflows/ci.yml/badge.svg)](https://github.com/nakashima-takeo/wezterm-ai-agents/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

[English](README_en.md)

並列AIコーディングエージェントセッションを管理するWezTermプラグイン。
永続ワークスペース、git worktree統合、エージェント状態の可視化に対応。

<!-- TODO: スクリーンショットまたはデモGIFをここに追加 -->
<!-- ![Demo](docs/demo.gif) -->

> 作者個人のワークフローに特化したプラグインを、マシン間で共有するために公開しています。
> 設計思想: タスクごとに1つのgit worktree、複数のAIエージェントセッションを並列実行、
> WezTerm再起動後も完全に復元可能。
>
> バグ報告歓迎。機能リクエストは作者のユースケースに合うか判断します。フォーク自由。

## 動作環境

macOS / Linux。Windows は非対応。

- WezTerm nightly（20230712 以降推奨、plugin API 使用のため）
- git 2.7+（`git worktree list --porcelain` に必要）
- bash（hooks スクリプト実行用）
- 使用するエージェントの CLI が PATH に存在すること

## 対応エージェント

| エージェント | コマンド | 状態検知 |
|-------------|---------|---------|
| [Claude Code](https://docs.claude.com/en/docs/claude-code) | `claude` | working / waiting / done / idle |
| [Cursor Agent](https://docs.cursor.com/agent) | `cursor-agent` | unknown（フック制約） |
| [OpenAI Codex](https://github.com/openai/codex) | `codex` | working / waiting / done / idle |
| [Google Gemini CLI](https://github.com/google-gemini/gemini-cli) | `gemini` | working / waiting / done / idle |

各エージェントはセッションIDを保持し、WezTerm再起動時に `--resume` で復元できます。

## インストール

```lua
local wezterm = require "wezterm"
local config = wezterm.config_builder()

local ai = wezterm.plugin.require("https://github.com/nakashima-takeo/wezterm-ai-agents")
ai.apply(config, {})

return config
```

ローカル開発時は `dofile` を使用:

```lua
local plugin_dir = wezterm.home_dir .. "/github/wezterm-ai-agents"
local ai = dofile(plugin_dir .. "/plugin/init.lua")
ai.apply(config, { plugin_dir = plugin_dir })
```

## Hooks設定

エージェント状態の検知には `hooks/agent_status.sh` をエージェント側のhooksに設定する必要があります。
スクリプトは状態をJSONとして `/tmp/wezterm-agent-<pane_id>` に書き込み、プラグインが定期的に読み取ります。

### Claude Code

`~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "<path>/hooks/agent_status.sh claude idle" }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "<path>/hooks/agent_status.sh claude clear" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "<path>/hooks/agent_status.sh claude working" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "<path>/hooks/agent_status.sh claude done" }] }],
    "PreToolUse":  [{ "matcher": "AskUserQuestion", "hooks": [{ "type": "command", "command": "<path>/hooks/agent_status.sh claude waiting" }] }],
    "PostToolUse": [{ "matcher": "AskUserQuestion", "hooks": [{ "type": "command", "command": "<path>/hooks/agent_status.sh claude working" }] }]
  }
}
```

### Cursor Agent

Cursorには細かいライフサイクルフックがないため、状態は常に `unknown` と表示されます。

`~/.cursor/hooks.json`:

```json
{
  "version": 1,
  "hooks": {
    "sessionStart": [{ "command": "<path>/hooks/agent_status.sh cursor unknown" }],
    "sessionEnd": [{ "command": "<path>/hooks/agent_status.sh cursor clear" }]
  }
}
```

### Codex

`~/.codex/hooks.json`:

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "<path>/hooks/agent_status.sh codex idle" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "<path>/hooks/agent_status.sh codex working" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "<path>/hooks/agent_status.sh codex done" }] }]
  }
}
```

### Gemini

`~/.gemini/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "<path>/hooks/agent_status.sh gemini idle" }] }],
    "SessionEnd":   [{ "hooks": [{ "type": "command", "command": "<path>/hooks/agent_status.sh gemini clear" }] }],
    "BeforeAgent":  [{ "hooks": [{ "type": "command", "command": "<path>/hooks/agent_status.sh gemini working" }] }],
    "AfterAgent":   [{ "hooks": [{ "type": "command", "command": "<path>/hooks/agent_status.sh gemini done" }] }]
  }
}
```

## キーバインド

修飾キーはプラットフォームに応じて自動設定されます（macOS: `Cmd`, Linux: `Ctrl`）。`opts.modifier_prefix` で上書き可能。

| キー | ID | アクション |
|------|-----|-----------|
| `Mod+Shift+S` | `workspace_selector` | ワークスペース選択・切替 |
| `Mod+Shift+N` | `workspace_register` | 現在のcwdをワークスペースとして登録 |
| `Mod+Shift+U` | `workspace_update` | 現在のレイアウトでワークスペースを更新 |
| `Mod+Shift+D` | `workspace_delete` | ワークスペースを削除 |
| `Mod+Shift+X` | `worktree_selector` | Worktree管理（作成/切替/削除） |
| `Mod+Shift+C` | `agent_spawn` | デフォルトエージェントを新しいタブで起動 |
| `Mod+Shift+A` | `agent_selector` | エージェント選択UI |
| `Mod+Shift+E` | `open_editor` | エディターを新しいタブで起動 |
| `Mod+T` | `new_tab` | 新しいタブ（ワークスペース同期） |
| `Mod+W` | `close_tab` | タブを閉じる（最後のタブは保護） |
| `Mod+Opt+W` | `close_pane` | ペインを閉じる（最後のペインは保護） |
| `Mod+Shift+[` / `]` | `move_tab_left` / `right` | タブを左右に移動（同期） |
| `Mod+Opt+/` | `split_right` | 右にペインを分割 |
| `Mod+Opt+-` | `split_bottom` | 下にペインを分割 |

`opts.disabled_keybinds = { "new_tab", "close_tab" }` で個別に無効化可能。

`opts.keybinds` でキーを変更可能（`key`/`mods` を個別に上書き、未指定項目はデフォルト維持）:

```lua
ai.apply(config, {
  keybinds = {
    workspace_selector = { key = "s", mods = "CTRL|SHIFT" },
    agent_spawn = { key = "Return", mods = "CTRL" },
    new_tab = { mods = "CTRL" },  -- key は "t" のまま
  },
})
```

## オプション

```lua
ai.apply(config, {
  enabled_agents = nil,             -- nil = all; or { "claude", "codex" }
  default_agent = nil,              -- nil = first registered; or "claude"
  default_editor = nil,             -- nil = $VISUAL or $EDITOR; or "nvim" etc.
  locale = "ja",                    -- auto-detected from LANG env; "en" | "ja"
  modifier_prefix = "CMD",          -- auto-detected: macOS="CMD", Linux="CTRL"
  workspace = {
    file = wezterm.home_dir .. "/.wezterm-workspaces.json",
    default_workspace = "default",
  },
  worktree = {
    path = "sibling",  -- "sibling" | "subdirectory" | "{parent}/.worktrees/{branch}" 等のテンプレート
  },
  agents = {
    -- claude = { command = "claude --dangerously-skip-permissions" },
    -- codex = { command = "codex --yolo" },
  },
  ui = {
    tab_title = {
      max_chars = 24,
      active_bg = "#1e1e2e",
      active_fg = "#cdd6f4",
    },
  },
  disabled_keybinds = {},
  keybinds = {},                    -- { id = { key = "...", mods = "..." } }
  status_update_interval = 1,       -- 右ステータス更新間隔（秒）
  session_sync_interval = 30,       -- セッションID同期間隔（秒）
  right_status_extra = nil,         -- function(window, pane, deps) -> segments
  install_ui_tab_title = true,
  install_ui_status = true,
  install_keybinds = true,
})
```

全オプションは `plugin/init.lua` の `default_opts` を参照。

## エージェントの追加

`plugin/agents/<id>.lua` に以下のインターフェースを実装:

```lua
return {
  id = "myagent",
  display_name = "...",
  icons  = { working = "...", waiting = "...", done = "...", idle = "..." },
  colors = { ... },
  detect(pane, opts)    -> bool,
  state(pane, opts)     -> "working" | "waiting" | "done" | "idle" | "error",
  session_id(pane, opts) -> string|nil,
  spawn_args(opts, session_id, cwd) -> table,
  cleanup_stale(opts)   -> nil,
  default_opts = { ... },
}
```

`init.lua` で登録: `agent.register(load_module("agents/myagent"))`

エージェント側のhooksから `hooks/agent_status.sh <id> <state>` を呼ぶように設定してください。

## ライセンス

MIT
