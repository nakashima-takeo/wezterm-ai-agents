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
- [Nerd Font](https://www.nerdfonts.com/)（ステータスアイコン表示に必要。未導入の場合は `nerd_font = false` で Unicode フォールバックに切替可能）
- git 2.7+（`git worktree list --porcelain` に必要）
- [GitHub CLI (`gh`)](https://cli.github.com/)（任意。worktree 画面の PR バッジ・Pull Requests セクション・PR をブラウザで開く機能に必要。未導入なら該当機能が出ない）
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

### Nerd Font のインストール

ステータスアイコンの表示に Nerd Font が必要です。Homebrew の場合:

```bash
brew install --cask font-hackgen-nerd
```

WezTerm の設定でフォントを指定:

```lua
config.font = wezterm.font("HackGen Console NF")
```

> 他の Nerd Font でも動作します。お好みのフォントを https://www.nerdfonts.com/ から選んでください。

### プラグインの設定

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

エージェント状態の検知には、プラグイン同梱の `hooks/agent_status.sh` をエージェント側のhooksに設定する必要があります。
スクリプトは状態をJSONとして `$XDG_STATE_HOME/wezterm-ai-agents/<gui_pid>/wezterm-agent-<pane_id>`（`$XDG_STATE_HOME` 未設定時は `~/.local/state/wezterm-ai-agents`）に書き込み、プラグインが定期的に読み取ります。`<gui_pid>` は GUI プロセスごとの名前空間で、複数の WezTerm を同時起動しても状態が混ざらないようにするものです。

> 状態検知は GUI プロセスが mux を内蔵する既定構成を前提とします。mux サーバを別プロセスで常駐させ `wezterm connect` で接続する分離構成・リモート多重化はサポート対象外です。

### hooks パスの確認

`ai.apply()` 実行時に hooks ディレクトリのパスがログに出力されます。
WezTerm の Debug Overlay（デフォルト: `Ctrl+Shift+L`、macOS でも Cmd ではなく Ctrl）で確認してください。

また、`ai.apply()` 後に `ai.hooks_dir` でパスを取得できます。

プラグインの `agent_status.sh` を直接参照することで、プラグイン更新時にスクリプトも自動的に更新されます。

> **注意**: スクリプトをコピーして使用すると、プラグイン更新時に修正が反映されません。`ai.hooks_dir` のパスを直接参照することを推奨します。

### Claude Code

`~/.claude/settings.json`（既存の hooks がある場合は配列に追加）:

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh claude idle" }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh claude clear" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh claude working" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh claude done" }] }],
    "PreToolUse":  [{ "matcher": "AskUserQuestion", "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh claude waiting" }] }],
    "PostToolUse": [{ "matcher": "AskUserQuestion", "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh claude working" }] }]
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
    "sessionStart": [{ "command": "<hooks_dir>/agent_status.sh cursor unknown" }],
    "sessionEnd": [{ "command": "<hooks_dir>/agent_status.sh cursor clear" }]
  }
}
```

### Codex

`~/.codex/hooks.json`:

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh codex idle" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh codex working" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh codex done" }] }]
  }
}
```

### Gemini

`~/.gemini/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh gemini idle" }] }],
    "SessionEnd":   [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh gemini clear" }] }],
    "BeforeAgent":  [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh gemini working" }] }],
    "AfterAgent":   [{ "hooks": [{ "type": "command", "command": "<hooks_dir>/agent_status.sh gemini done" }] }]
  }
}
```

## キーバインド

修飾キーはプラットフォームに応じて自動設定されます（macOS: `Cmd`, Linux: `Ctrl`）。`opts.modifier_prefix` で上書き可能。

| キー | ID | アクション |
|------|-----|-----------|
| `Mod+Shift+S` | `workspace_selector` | ワークスペース選択・切替 |
| `Mod+Shift+X` | `worktree_selector` | Worktree管理（作成/切替/削除） |
| `Mod+Shift+C` | `agent_spawn` | デフォルトエージェントを新しいタブで起動 |
| `Mod+Shift+A` | `agent_selector` | エージェント選択UI |
| `Mod+Shift+E` | `open_editor` | GUIエディターで現在のディレクトリを開く |
| `Mod+T` | `new_tab` | 新しいタブ（ワークスペース同期） |
| `Mod+W` | `close_tab` | タブを閉じる（最後のタブは保護） |
| `Mod+Opt+W` | `close_pane` | ペインを閉じる（最後のペインは保護） |
| `Mod+Shift+[` / `]` | `move_tab_left` / `right` | タブを左右に移動（同期） |
| `Mod+Opt+/` | `split_right` | 右にペインを分割 |
| `Mod+Opt+-` | `split_bottom` | 下にペインを分割 |
| `Mod+Q` | `disable_quit` | 誤終了防止（Nop） |
| `Opt+Enter` | `opt_enter` | OPT+Enterパススルー |
| `Mod+Opt+←→↑↓` | `activate_pane_*` | ペイン移動 |
| `Mod+↑` / `Mod+↓` | `scroll_to_top` / `bottom` | 先頭/末尾にスクロール |
| `Opt+↑` / `Opt+↓` | `scroll_page_up` / `down` | ページ単位スクロール |
| `Mod+←` / `Mod+→` | `line_start` / `end` | 行頭/行末に移動 |
| `Mod+Shift+←→` | `prev_tab` / `next_tab` | タブ切り替え |
| `Mod+Shift+P` | `pin_toggle` | ウィンドウを常に前面に固定/解除 |

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
  nerd_font = true,                 -- Nerd Font アイコンを使用。false で Unicode フォールバック
  enabled_agents = nil,             -- nil = all; or { "claude", "codex" }
  default_agent = nil,              -- nil = first registered; or "claude"
  default_editor = nil,             -- nil = auto-detect (code/cursor/windsurf/zed/subl); or "/usr/local/bin/cursor" etc.
  locale = "ja",                    -- auto-detected from LANG env; "en" | "ja"
  modifier_prefix = "CMD",          -- auto-detected: macOS="CMD", Linux="CTRL"
  workspace = {
    file = wezterm.home_dir .. "/.wezterm-workspaces.json",
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

### 見た目のデフォルト

見た目とタブバー設定 (Catppuccin Mocha / 透過 / ブラー / fancy タブバー等) は**常時・非破壊で適用**される。利用者が `config.X` を設定していればそちらが優先されるので、好みは `apply()` の前後どちらに書いても上書きできる (フォントは対象外)。

```lua
config.color_scheme = "Tokyo Night"        -- 別の配色に置換
config.window_background_opacity = 1.0     -- 透過を無効化
config.use_fancy_tab_bar = false           -- 標準のタブバーに戻す
```

## エージェントの追加

`plugin/agents/<id>.lua` に以下のインターフェースを実装:

```lua
return {
  id = "myagent",
  display_name = "...",
  colors = { working = "...", waiting = "...", done = "...", idle = "..." },
  detect(pane, opts)    -> bool,
  state(pane, opts)     -> "working" | "waiting" | "done" | "idle" | "error",
  session_id(pane, opts) -> string|nil,
  spawn_args(opts, session_id, cwd) -> table,
  default_opts = { ... },
}
```

`init.lua` で登録: `agent.register(load_module("agents/myagent"))`

エージェント側のhooksから `hooks/agent_status.sh <id> <state>` を呼ぶように設定してください。

## ライセンス

MIT
