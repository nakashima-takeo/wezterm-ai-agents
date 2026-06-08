#!/usr/bin/env bash
# wezterm-ai-agents: 検出済み各エージェントへ agent-plugin を導入する。
#
# 他社の設定ファイルを直接書き換えず (jq 手術をやめ)、各社のプラグイン CLI に委譲して
# 境界を尊重する。agent-plugin は状態追跡フック + MCP サーバー + supervise skill を束ねた配布物で、
# これを install-if-absent で冪等に導入する。背景実行され出力は使われないため fail-safe に書く。
#
# Usage:
#   install_plugins.sh <plugin_dir> <agent_id>...
#     plugin_dir : リポジトリルート (.claude-plugin/marketplace.json と agent-plugin/ を含む)
#
# 各 id について stdout に1行返す (同期実行時のログ用):
#   installed <id> | unchanged <id> | skip-no-cli <id> | error <id>
#
# 冪等性 (実機確認済み):
#   claude: marketplace add は "already added"、install は "already installed" で no-op
#   codex : marketplace add は "already added"、plugin add は再 add でスナップショット更新 (内容不変なら
#           フック hash も不変＝信頼は維持。フック変更時のみ codex 側で再信頼が要る)
#   gemini: install は2回目エラー (uninstall first) のため list で存在確認し update / install を分岐
#
# 注意 (codex の一度きり信頼): codex はプラグイン同梱フックを「信頼」するまで発火しない。
# 導入後にユーザーが codex で /hooks を実行して一度信頼する必要がある (現状の ~/.codex/hooks.json でも同様)。

set -u
DIR="${1:?plugin_dir required}"
shift
NAME="wezterm-ai-agents"
PKG="$DIR/agent-plugin"

for id in "$@"; do
  case "$id" in
    claude)
      command -v claude >/dev/null 2>&1 || { echo "skip-no-cli claude"; continue; }
      claude plugin marketplace add "$DIR" >/dev/null 2>&1
      if claude plugin list 2>/dev/null | grep -q "${NAME}@${NAME}"; then
        echo "unchanged claude"
      elif claude plugin install "${NAME}@${NAME}" >/dev/null 2>&1; then
        echo "installed claude"
      else
        echo "error claude"
      fi
      ;;
    codex)
      command -v codex >/dev/null 2>&1 || { echo "skip-no-cli codex"; continue; }
      codex plugin marketplace add "$DIR" >/dev/null 2>&1
      if codex plugin add "${NAME}@${NAME}" >/dev/null 2>&1; then
        echo "installed codex"
      else
        echo "error codex"
      fi
      ;;
    gemini)
      command -v gemini >/dev/null 2>&1 || { echo "skip-no-cli gemini"; continue; }
      if gemini extensions list 2>&1 | grep -q "$NAME"; then
        gemini extensions update "$NAME" >/dev/null 2>&1
        echo "unchanged gemini"
      elif gemini extensions install "$PKG" --consent >/dev/null 2>&1; then
        echo "installed gemini"
      else
        echo "error gemini"
      fi
      ;;
    *)
      # cursor 等: プラグイン CLI を持たない二級市民。自動導入の対象外 (手動 or 非対応)。
      echo "skip-no-cli $id"
      ;;
  esac
done
