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
│   ├── worktree.lua    — git worktree 操作 (list/add/remove/prune) + PR/Issue
│   ├── editor.lua      — エディタ検出・起動引数
│   └── links.lua       — ターミナル出力パスの editor:// リンク化
└── resource/           — 下位層: 静的データ
    ├── labels.lua      — i18n ラベル (en/ja)
    └── icons.lua       — アイコンセット (unicode / nerd)、opts.nerd_font で切替
```

**主要パターン:**
- エージェント状態は hooks が pane ごとに JSON ファイルを書き込む push 方式: `$XDG_STATE_HOME/wezterm-ai-agents/<gui_pid>/wezterm-agent-<pane_id>` (GUI プロセス PID 名前空間配下。フォールバック `~/.local/state`)
- `hooks/agent_status.sh` が書き込み側 (全エージェント共通)。Lua 側は `wezterm.json_parse()` で読み取り
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

## エージェントの追加方法

1. `plugin/service/agents/<id>.lua` を作成。`plugin/service/agent.lua` で定義されたインターフェースを実装する (detect, state, session_id, spawn_args 等)。検出は JSON 状態ファイルの `data.agent == "<id>"` で判定。
2. `init.lua` で `agent.register(load("service/agents/<id>"))` により登録。
3. エージェントの hooks から `hooks/agent_status.sh <id> <state>` を呼ぶ (または同じ JSON 形式を直接書き込む)。
