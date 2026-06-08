#!/usr/bin/env bash
# Unified hook bridge for wezterm-ai-agents.
# Writes agent state as JSON to a per-pane file that Lua reads at update-status.
#
# Usage:
#   agent_status.sh <agent_id> <state>
#
# States: idle | working | waiting | done | error | clear
# "clear" removes the state file (session ended).
#
# Expects WEZTERM_PANE env var (set by WezTerm for all spawned shells).
# Reads JSON on stdin to extract session_id (compatible with Claude Code,
# Codex, Gemini, Cursor hooks).

[ -z "$WEZTERM_PANE" ] && exit 0

AGENT="${1:?agent_id required}"
STATUS="${2:-idle}"
STATUS_DIR="${WEZTERM_AGENT_STATUS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wezterm-ai-agents}"

# 自 GUI プロセス PID で名前空間化する (複数 GUI プロセス間の誤削除・pane_id 衝突を防ぐ)。
# WEZTERM_UNIX_SOCKET はフルパス (…/gui-sock-<pid>)。末尾が純数値のときのみ名前空間を付ける。
case "$WEZTERM_UNIX_SOCKET" in
  *gui-sock-*) NS="${WEZTERM_UNIX_SOCKET##*gui-sock-}" ;;
  *) NS="" ;;
esac
case "$NS" in
  '' | *[!0-9]*) NS="" ;;
esac
[ -n "$NS" ] && STATUS_DIR="$STATUS_DIR/$NS"

STATE_FILE="$STATUS_DIR/wezterm-agent-$WEZTERM_PANE"

INPUT=$(cat)

case "$STATUS" in
  clear)
    rm -f "$STATE_FILE"
    ;;
  *)
    mkdir -p "$STATUS_DIR"
    SID=$(echo "$INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    # 近接イベント (working→done 等) でフックが並行発火するため、tmp は PID で一意化する。
    # 固定名だと一方の mv がもう一方の tmp を先に消し "No such file" で書き込みが落ちる。
    tmp="$STATE_FILE.tmp.$$"
    printf '{"agent":"%s","state":"%s","ts":%d,"session_id":"%s"}\n' \
      "$AGENT" "$STATUS" "$(date +%s)" "${SID:-}" > "$tmp" \
      && mv "$tmp" "$STATE_FILE"
    ;;
esac
