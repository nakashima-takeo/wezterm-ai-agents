#!/usr/bin/env bash
# wezterm-ai-agents: 各エージェントの設定ファイルに agent_status.sh フックを冪等マージする。
#
# Usage:
#   install_hooks.sh <hooks_dir> <agent_id>...
#
# 各 id について stdout に結果を1行返す:
#   applied <id> | unchanged <id> | skip-symlink <id> | skip-invalid-json <id> | skip-unknown <id>
# jq が無い場合は何も書かず "jq-missing" を出して exit 3 (呼び出し側 Lua が diagnostics に上げる)。
#
# 冪等性: command に "agent_status.sh <id>" を含むエントリ (= プラグイン管理対象) を除去してから
# 正規版を再追加する。hooks_dir が変わっても古いエントリを残さず追従し、何度実行しても結果は同一。
# 既存の他フック・他キーは保持する。
#
# bash 3.2 / POSIX 互換で書く (連想配列・mapfile を使わない)。dotfiles の symlink は壊さない。

DIR="${1:?hooks_dir required}"
shift

command -v jq >/dev/null 2>&1 || {
  echo "jq-missing"
  exit 3
}

for id in "$@"; do
  case "$id" in
    claude)
      file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
      style=nested
      spec='[{"event":"SessionStart","state":"idle"},{"event":"SessionEnd","state":"clear"},{"event":"UserPromptSubmit","state":"working"},{"event":"Stop","state":"done"},{"event":"PreToolUse","state":"waiting","matcher":"AskUserQuestion"},{"event":"PostToolUse","state":"working","matcher":"AskUserQuestion"}]'
      ;;
    codex)
      file="${CODEX_HOME:-$HOME/.codex}/hooks.json"
      style=nested
      spec='[{"event":"SessionStart","state":"idle"},{"event":"UserPromptSubmit","state":"working"},{"event":"PermissionRequest","state":"waiting"},{"event":"Stop","state":"done"}]'
      ;;
    gemini)
      file="$HOME/.gemini/settings.json"
      style=nested
      spec='[{"event":"SessionStart","state":"idle"},{"event":"SessionEnd","state":"clear"},{"event":"BeforeAgent","state":"working"},{"event":"Notification","state":"waiting"},{"event":"AfterAgent","state":"done"}]'
      ;;
    cursor)
      file="${CURSOR_CONFIG_DIR:-$HOME/.cursor}/hooks.json"
      style=cursor
      spec='[{"event":"sessionStart","state":"unknown"},{"event":"sessionEnd","state":"clear"}]'
      ;;
    *)
      echo "skip-unknown $id"
      continue
      ;;
  esac

  # symlink (dotfiles 管理等) は真実源を侵さない。
  if [ -L "$file" ]; then
    echo "skip-symlink $id"
    continue
  fi

  # 既存ファイルは jq でパース検証。不正 (JSONC/破損/BOM) なら一切触らない (全消去防止)。
  if [ -f "$file" ]; then
    if ! jq empty "$file" >/dev/null 2>&1; then
      echo "skip-invalid-json $id"
      continue
    fi
    current=$(cat "$file")
    # 空/空白のみのファイルは jq empty を通過してしまう (current="" のまま後段が空出力になり
    # before==after で unchanged に化け、フックが無言で未設定になる)。非存在ファイルと同じ {} 扱いにする。
    [ -z "${current//[[:space:]]/}" ] && current='{}'
  else
    current='{}'
  fi

  if [ "$style" = cursor ]; then
    result=$(printf '%s' "$current" | jq --arg dir "$DIR" --argjson spec "$spec" '
      .version = 1
      # 全イベントから自分の command を除去 (command 単位。同居する他フックは残す。空になったイベントは掃除)
      | .hooks = (
          (.hooks // {})
          | map_values(map(select((.command // "") | contains("agent_status.sh cursor") | not)))
          | with_entries(select(.value | length > 0))
        )
      # spec の正規エントリを追加
      | reduce $spec[] as $s (.;
          .hooks[$s.event] = (((.hooks[$s.event]) // []) + [ {command: ($dir + "/agent_status.sh cursor " + $s.state)} ])
        )
    ') || {
      echo "skip-invalid-json $id"
      continue
    }
  else
    result=$(printf '%s' "$current" | jq --arg dir "$DIR" --arg id "$id" --argjson spec "$spec" '
      # 全イベントから自分の command を除去 (command 単位。matcher グループ内の同居フックは残し、
      # 自分のエントリだけ消す。空になったグループ/イベントは掃除)。spec 外イベントの古い残骸も消える。
      .hooks = (
        (.hooks // {})
        | map_values(
            map(.hooks = ((.hooks // []) | map(select((.command // "") | contains("agent_status.sh " + $id) | not))))
            | map(select(((.hooks) // []) | length > 0))
          )
        | with_entries(select(.value | length > 0))
      )
      # spec の正規エントリを追加
      | reduce $spec[] as $s (.;
          .hooks[$s.event] = (
            ((.hooks[$s.event]) // [])
            + [ (if $s.matcher then {matcher: $s.matcher} else {} end)
                + {hooks: [{type: "command", command: ($dir + "/agent_status.sh " + $id + " " + $s.state)}]} ]
          )
        )
    ') || {
      echo "skip-invalid-json $id"
      continue
    }
  fi

  # 正規形 (キーソート) で比較し、変更が無ければ書かない → 冪等。
  if [ -f "$file" ]; then
    before=$(printf '%s' "$current" | jq -S .)
  else
    before=""
  fi
  after=$(printf '%s' "$result" | jq -S .)
  if [ "$before" = "$after" ]; then
    echo "unchanged $id"
    continue
  fi

  parent=$(dirname "$file")
  mkdir -p "$parent"
  # tmp + mv のアトミック書き込み。jq 変換失敗時は mv に到達せず、mv は成功(新内容)か無変更の
  # どちらかなので途中破損が起きない。マージ自体も他キー/他フックを保持する非破壊処理のため、
  # バックアップ (.bak) は作らない (外部ツールの設定ディレクトリに残骸を残さない)。
  tmp="$file.tmp.$$"
  printf '%s\n' "$result" >"$tmp" && mv "$tmp" "$file"
  echo "applied $id"
done
