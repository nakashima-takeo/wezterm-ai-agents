# CLAUDE.md

## 概要

WezTerm プラグイン。並列 AI コーディングエージェントセッションを管理する。WezTerm の Lua 5.4 サンドボックス上で動作する (テスト/lint は LuaJIT で実行)。永続ワークスペース、git worktree 連携、タブ/ペイン UI によるエージェント状態追跡を提供。

## コマンド

```bash
# Lint
luacheck .

# フォーマットチェック
stylua --check .

# フォーマット修正
stylua .

# 全テスト実行 (luajit 必須)
bash test/run.sh

# 単体テスト実行
luajit test/test_agent.lua

# MCP サーバービルド
cd agent-plugin/mcp && go build -o wezterm-mcp .

# MCP サーバーテスト
cd agent-plugin/mcp && go test ./...
```

## アーキテクチャ

`plugin/init.lua` がエントリポイント。`dofile()` で全モジュールをロードする。WezTerm サンドボックスは `wezterm` / `mux` グローバルを提供するが、`debug` ライブラリは使用不可。

**ディレクトリ構成（レイヤ別。`init.lua` がロード順=依存階層で全体を接続）:**
```
plugin/
├── init.lua            — エントリポイント、apply() で層順にロード+結線
├── ui/                 — 上位層: 描画・操作
│   ├── ui.lua          — タブタイトル、右ステータスバーの描画
│   └── selector/       — InputSelector ベースの UI + キーバインド
│       ├── init.lua    — coordinator (build_keybinds / agent選択 / pin)
│       ├── workspace.lua — ワークスペース選択/登録/削除 UI
│       ├── worktree.lua  — worktree/PR/Issue 選択 UI + prefetch
│       └── ui.lua      — フォーマット共通ヘルパー (setup で両UIに注入)
├── state/              — 中位層: 永続化・配置 (循環は agent_mod/layout_mod 注入で回避)
│   ├── workspace/
│   │   ├── init.lua    — JSON永続化 + CRUD
│   │   └── session.lua — タブ状態のスナップショット/同期/ワークスペース生成
│   └── layout.lua      — ペイン分割レイアウトのスナップショット/復元
├── service/            — 下位層: 外部I/O・検出 (UI に依存しない)
│   ├── agent.lua       — エージェントレジストリ、検出、状態集約、JSON リーダー
│   ├── agents/         — 各エージェント実装 (claude/codex/cursor/gemini)
│   ├── diagnostics.lua — 知らせるべき失敗を登録し update-status でペインへ通知 (window 非依存)
│   ├── worktree/
│   │   ├── init.lua    — ローカル git worktree 操作 (list/add/remove/prune) + 命名/パス展開
│   │   └── github.lua  — PR/Issue 連携 (gh 取得・キャッシュ・パース・フィルタ・worktree生成)
│   ├── editor.lua      — エディタ検出・起動引数
│   └── links.lua       — ターミナル出力パスの editor:// リンク化
└── resource/           — 下位層: 静的データ
    ├── labels.lua      — i18n ラベル (en/ja)
    └── icons.lua       — アイコンセット (unicode / nerd)、opts.nerd_font で切替
```

**主要パターン:**
- エージェント状態は hooks が pane ごとに JSON ファイルを書き込む push 方式: `$XDG_STATE_HOME/wezterm-ai-agents/<gui_pid>/wezterm-agent-<pane_id>` (GUI プロセス PID 名前空間配下。フォールバック `~/.local/state`)
- `agent-plugin/hooks/agent_status.sh` が書き込み側 (全エージェント共通・各社プラグインに同梱)。Lua 側は `wezterm.json_parse()` で読み取り
- 登録するエージェントは `enabled_agents` 既定 nil のとき `agent.detect_installed` が各 command 先頭バイナリを `command -v` で検出し、PATH 上に在るものだけに絞る (未インストールツールをプラグイン自動導入や選択 UI の対象にしない)。検出不能(シェル失敗)は全登録へフォールバック、0件は登録せず diagnostics で通知。`enabled_agents` 明示時は検出せずそのまま尊重 (エスケープハッチ)
- 起動時に `hooks/install_plugins.sh` が検出済み各エージェントへ agent-plugin (状態追跡フック+MCP+skill) を各社プラグイン CLI で導入する (既定 ON `opts.install_hooks`、背景実行・install-if-absent で冪等。他社の設定ファイルを直接書き換えない。codex はフック信頼を一度 `/hooks` で要承認)
- ユーザーに知らせるべき失敗は `service/diagnostics.lua` に report し、update-status でアクティブペインへ端末出力で通知する (`wezterm.log_*` はデバッグオーバーレイ止まりで届かないため)
- PID 名前空間は書き込み側 `WEZTERM_UNIX_SOCKET` の `gui-sock-<pid>` と読み取り側 `wezterm.procinfo.pid()` が同一 GUI プロセス PID に合意する前提 (mux 内蔵の既定構成のみ。分離 mux 構成は非対応)
- JSON 形式: `{"agent":"<id>","state":"<state>","ts":<unix>,"session_id":"<sid>"}`
- ワークスペースデータは `$XDG_STATE_HOME/wezterm-ai-agents/workspaces.json` (PID 名前空間なし) にアトミック書き込み (tmp + rename)
- 循環依存は関数引数でモジュールを渡して回避 (`agent_mod`, `layout_mod`)
- 非同期/外部コマンド実行の方針は [docs/async.md](docs/async.md) を参照 (UI ブロック回避、背景取得 + キャッシュ等)

## テスト

LuaJIT + モック wezterm モジュール (`test/mock_wezterm.lua`) で実行。テストファイルは `test/test_*.lua` パターン。各ファイルで `test/helper.lua` を require し、`H.test(name, fn)` / `H.finish()` を使用。

テスト追加: `test/test_<name>.lua` を作成し、helper を require して `H.test` / `H.finish` を呼ぶ。

## コードスタイル

- 実行環境は Lua 5.4、テスト/lint は LuaJIT (`.luacheckrc`: `std = "luajit"`)。両方で動く書き方にする
- StyLua: 2スペースインデント、140桁幅、ダブルクォート優先
- 最大行長: 140文字
- グローバル: `wezterm` (luacheck で許可)、`mux` は実行時に WezTerm が提供

## コミットメッセージ / PR タイトル

リリースノートは GitHub の `generate_release_notes: true` で自動生成される。main へのマージコミットや PR タイトルがそのままリリースノートに載るため、開発者以外の読み手（利用者）にも伝わる簡潔でわかりやすい表現にすること。

## MCP サーバー / AI エージェント側パッケージ

`agent-plugin/` が **AI エージェント側の配布物**（1 パッケージ・3 マニフェスト）。claude/codex/gemini が同じ MCP サーバー・supervise スキルを共有する。`agent-plugin/mcp/` の Go 製 MCP サーバーを同梱。WezTerm 側の Lua プラグイン (`plugin/`) とは別ランタイムで同一リポジトリに同居する。

```
agent-plugin/
├── .claude-plugin/plugin.json — claude マニフェスト (skills + .mcp.json)
├── .codex-plugin/plugin.json  — codex マニフェスト (skills + .mcp.json)
├── gemini-extension.json      — gemini マニフェスト (mcpServers をインライン)
├── .mcp.json                  — 共有 MCP 定義 (claude/codex が参照、sh -c で共有バイナリ起動)
├── skills/supervise/SKILL.md  — 3 社共有の supervise スキル本体 (単一ソース)
│   └── agents/openai.yaml      — codex 専用ガード (allow_implicit_invocation:false)
├── commands/supervise.toml    — gemini の /supervise 決定起動コマンド
└── mcp/                       — 共有 Go MCP サーバー
```
各社の supervise 決定起動: claude=`/wezterm-ai-agents:supervise`、codex=`$supervise`、gemini=`/supervise`。Lua の `build_command` (`orchestrator_agent` で選択) が各社流に組み立てる。`disable-model-invocation` は codex が拒否するため SKILL.md には付けず、description と codex の openai.yaml で自発起動を抑止する。

配布は各社で別マニフェスト・別マーケットプレイスを使う (repo root の `.claude-plugin/marketplace.json`＝claude、`.agents/plugins/marketplace.json`＝codex)。

**配布/導入 (利用者):**
- claude: `.claude-plugin/marketplace.json` 経由。
  ```
  /plugin marketplace add nakashima-takeo/wezterm-ai-agents
  /plugin install wezterm-ai-agents@wezterm-ai-agents
  ```
- codex: `.agents/plugins/marketplace.json` 経由 (plugin の `source.path` は repo root からの相対 `./agent-plugin`)。
  ```
  codex plugin marketplace add nakashima-takeo/wezterm-ai-agents
  codex plugin add wezterm-ai-agents@wezterm-ai-agents
  ```
- gemini: `gemini extensions install https://github.com/nakashima-takeo/wezterm-ai-agents`。

`.mcp.json`/`gemini-extension.json` の command は共有バイナリ `$XDG_STATE_HOME/wezterm-ai-agents/bin/wezterm-mcp` を指す。これは WezTerm プラグインが起動時に `hooks/install_mcp.sh` で用意する (`v*` Release からプリビルドを DL、無ければ `go build` フォールバック ＝ dev のみ要 Go)。**3 社が同じ1つのバイナリを共有**するため利用環境に Go は不要。ローカル開発は `claude --plugin-dir ./agent-plugin` / `gemini extensions link ./agent-plugin` 等で確認できる。

**手動セットアップ (プラグインを使わない場合):**
```bash
cd agent-plugin/mcp && go build -o wezterm-mcp .
claude mcp add -s user wezterm ./agent-plugin/mcp/wezterm-mcp
```

**環境変数でエージェントコマンドを上書き:**
```bash
claude mcp add -s user -e WEZTERM_MCP_AGENT_CLAUDE="claude --dangerously-skip-permissions" -- wezterm ./agent-plugin/mcp/wezterm-mcp
```

**ツール:** list_workspaces, list_panes, get_agent_status, get_agents, wait_for_event, list_worktrees, add_worktree, remove_worktree, spawn_agent, get_pane_text, send_text, send_key

`get_agents` は監督集合 (司令塔コンソール CMD+SHIFT+M で人間がトグル) とライブ状態を結合して返す。`wait_for_event` は監督ペインの状態変化／監督集合の変化までブロックし差分を返す (オーケストレーターの監視ループ用)。状態ファイルは `WEZTERM_UNIX_SOCKET` 由来の gui_pid 名前空間配下を読む (フック・Lua と同一規則)。

## エージェントの追加方法

1. `plugin/service/agents/<id>.lua` を作成。`plugin/service/agent.lua` で定義されたインターフェースを実装する (detect, state, session_id, spawn_args 等)。検出は JSON 状態ファイルの `data.agent == "<id>"` で判定。ファイルを置けば `init.lua` が `service/agents/*.lua` を走査して候補・検証・登録に自動で乗せる (手動の登録リストは無い)。
2. エージェントの hooks から `agent-plugin/hooks/agent_status.sh <id> <state>` を呼ぶ (または同じ JSON 形式を直接書き込む)。
3. `agent-plugin/hooks/<id>-hooks.json` に event→state を定義し各マニフェストの `hooks` フィールドで参照する (gemini は固定 `hooks/hooks.json` を自動探索)。`hooks/install_plugins.sh` の `case "$id"` に各社の install コマンドを追記する (起動時自動導入の対象に含めるため)。
