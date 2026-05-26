# CLAUDE.md

## 概要

WezTerm プラグイン。並列 AI コーディングエージェントセッションを管理する。Lua (LuaJIT) で記述し、WezTerm の Lua サンドボックス上で動作する。永続ワークスペース、git worktree 連携、タブ/ペイン UI によるエージェント状態追跡を提供。

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

**モジュール依存関係:**
```
init.lua (エントリポイント、apply() で全体を接続)
├── workspace.lua  — JSON永続化、CRUD、タブ状態のスナップショット/同期
├── worktree.lua   — git worktree 操作 (list/add/remove/prune)
├── layout.lua     — ペイン分割レイアウトのスナップショット/復元
├── selector.lua   — InputSelector ベースの UI + キーバインド登録
├── labels.lua     — i18n ラベル (en/ja)
├── icons.lua      — アイコンセット (unicode / nerd)、opts.nerd_font で切替
├── agent.lua      — エージェントレジストリ、検出、状態集約、JSON リーダー
│   ├── agents/claude.lua  — Claude Code
│   ├── agents/codex.lua   — OpenAI Codex CLI
│   ├── agents/cursor.lua  — Cursor Agent CLI
│   └── agents/gemini.lua  — Google Gemini CLI
└── ui.lua         — タブタイトル、右ステータスバーの描画
```

**主要パターン:**
- エージェント状態は hooks が pane ごとに JSON ファイルを書き込む push 方式: `/tmp/wezterm-agent-<pane_id>`
- `hooks/agent_status.sh` が書き込み側 (全エージェント共通)。Lua 側は `wezterm.json_parse()` で読み取り
- JSON 形式: `{"agent":"<id>","state":"<state>","ts":<unix>,"session_id":"<sid>"}`
- ワークスペースデータは `~/.wezterm-workspaces.json` にアトミック書き込み (tmp + rename)
- 循環依存は関数引数でモジュールを渡して回避 (`agent_mod`, `layout_mod`)

## テスト

LuaJIT + モック wezterm モジュール (`test/mock_wezterm.lua`) で実行。テストファイルは `test/test_*.lua` パターン。各ファイルで `test/helper.lua` を require し、`H.test(name, fn)` / `H.finish()` を使用。

テスト追加: `test/test_<name>.lua` を作成し、helper を require して `H.test` / `H.finish` を呼ぶ。

## コードスタイル

- LuaJIT ターゲット (`.luacheckrc`: `std = "luajit"`)
- StyLua: 2スペースインデント、140桁幅、ダブルクォート優先
- 最大行長: 140文字
- グローバル: `wezterm` (luacheck で許可)、`mux` は実行時に WezTerm が提供

## コミットメッセージ / PR タイトル

リリースノートは GitHub の `generate_release_notes: true` で自動生成される。main へのマージコミットや PR タイトルがそのままリリースノートに載るため、開発者以外の読み手（利用者）にも伝わる簡潔でわかりやすい表現にすること。

## エージェントの追加方法

1. `plugin/agents/<id>.lua` を作成。`plugin/agent.lua` で定義されたインターフェースを実装する (detect, state, session_id, spawn_args 等)。検出は JSON 状態ファイルの `data.agent == "<id>"` で判定。
2. `init.lua` で `agent.register(load("agents/<id>"))` により登録。
3. エージェントの hooks から `hooks/agent_status.sh <id> <state>` を呼ぶ (または同じ JSON 形式を直接書き込む)。
