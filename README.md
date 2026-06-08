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

## エージェント状態の検知 (Hooks)

エージェントの状態 (idle/working/waiting/done) は、各エージェントに導入した **agent-plugin** の同梱フックが JSON 状態ファイルに書き込み、WezTerm プラグインが読み取って表示します。

**既定 (`install_hooks = true`) では、WezTerm 起動時に検出した各エージェントへ agent-plugin を自動導入します**（各社のプラグイン CLI 経由・冪等。**他社の設定ファイルを直接書き換えません**）。通常は何もする必要はありません。

- claude / codex / gemini: `claude plugin install` / `codex plugin add` / `gemini extensions install` をバックグラウンドで実行 (install-if-absent)。`jq` は不要。
- **codex のみ一手間**: codex はプラグイン同梱フックを「信頼」するまで発火しません。導入後に codex で **`/hooks` を一度実行してフックを信頼**してください (一度きり)。
- cursor: プラグイン CLI を持たない二級市民のため自動導入の対象外 (下記の手動設定)。
- `install_hooks = false` で自動導入を無効化できます。

スクリプトは状態をJSONとして `$XDG_STATE_HOME/wezterm-ai-agents/<gui_pid>/wezterm-agent-<pane_id>`（`$XDG_STATE_HOME` 未設定時は `~/.local/state/wezterm-ai-agents`）に書き込み、プラグインが定期的に読み取ります。`<gui_pid>` は GUI プロセスごとの名前空間で、複数の WezTerm を同時起動しても状態が混ざらないようにするものです。

> 状態検知は GUI プロセスが mux を内蔵する既定構成を前提とします。mux サーバを別プロセスで常駐させ `wezterm connect` で接続する分離構成・リモート多重化はサポート対象外です。

## 手動導入 / cursor

`install_hooks = false` にした、または手動で入れたい場合 (event→state マッピングの真実源は `agent-plugin/hooks/` の各 JSON):

- **claude**: `/plugin marketplace add nakashima-takeo/wezterm-ai-agents` → `/plugin install wezterm-ai-agents@wezterm-ai-agents`
- **codex**: `codex plugin marketplace add nakashima-takeo/wezterm-ai-agents` → `codex plugin add wezterm-ai-agents@wezterm-ai-agents` → codex で `/hooks` を実行して信頼
- **gemini**: `gemini extensions install https://github.com/nakashima-takeo/wezterm-ai-agents`

### Cursor Agent (二級市民・手動)

Cursor はプラグイン CLI もライフサイクルフックも乏しいため自動導入の対象外です。状態を追跡したい場合は `~/.cursor/hooks.json` に同梱スクリプトを手動登録します (`<agent-plugin>` は導入済み agent-plugin のパス):

```json
{
  "version": 1,
  "hooks": {
    "sessionStart": [{ "command": "<agent-plugin>/hooks/agent_status.sh cursor unknown" }],
    "sessionEnd": [{ "command": "<agent-plugin>/hooks/agent_status.sh cursor clear" }]
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
  enabled_agents = nil,             -- nil = PATH 上のバイナリを自動検出; or { "claude", "codex" } で明示固定
  default_agent = nil,              -- nil = first registered; or "claude"
  default_editor = nil,             -- nil = auto-detect (code/cursor/windsurf/zed/subl); or "/usr/local/bin/cursor" etc.
  editor_links = false,             -- true でターミナル出力のファイルパスをクリック→エディタの該当行で開く
  locale = "ja",                    -- auto-detected from LANG env; "en" | "ja"
  modifier_prefix = "CMD",          -- auto-detected: macOS="CMD", Linux="CTRL"
  workspace = {
    -- 既定: $XDG_STATE_HOME/wezterm-ai-agents/workspaces.json (未設定時は ~/.local/state/wezterm-ai-agents/workspaces.json)
    -- file = "/path/to/workspaces.json",
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

見た目とタブバー設定 (Catppuccin Mocha / 透過 / ブラー / fancy タブバー等) は**常時・非破壊で適用**される。利用者が `config.X` を設定していればそちらが優先されるので、好みは `apply()` の前後どちらに書いても上書きできる。フォントは family 本体を強制しないが、`config.font` 未設定時のみ JetBrains Mono に OS 標準の和文フォントをフォールバックとして自動付加する (`config.font` を自分で設定すれば触らない)。

```lua
config.color_scheme = "Tokyo Night"        -- 別の配色に置換
config.window_background_opacity = 1.0     -- 透過を無効化
config.use_fancy_tab_bar = false           -- 標準のタブバーに戻す
```

## エージェントの追加

`plugin/service/agents/<id>.lua` に以下のインターフェースを実装:

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

`init.lua` で登録: `agent.register(load("service/agents/myagent"))`

エージェント側のhooksから `hooks/agent_status.sh <id> <state>` を呼ぶように設定してください。

## ライセンス

MIT
