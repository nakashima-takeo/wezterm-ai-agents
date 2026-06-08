#!/usr/bin/env bash
# Ensure the wezterm-mcp binary exists at the shared install path, so all agents
# (claude/codex/gemini) can point their MCP config at one prebuilt binary without
# requiring Go on the user's machine.
#
# Stored under XDG_STATE_HOME, alongside the other wezterm-ai-agents state, so everything
# lives under one app namespace. A compiled binary is platform-specific (non-portable) and
# re-derivable (re-download / rebuild), which fits XDG_STATE ("persists, but not important
# or portable enough for XDG_DATA"). Not XDG_CACHE (disposable: if cleared while offline the
# MCP would break) and not ~/.local/bin (that is for user-invoked CLIs on PATH).
#
# Usage:
#   install_mcp.sh <repo_url> <version> <source_dir>
#     repo_url   : e.g. https://github.com/nakashima-takeo/wezterm-ai-agents
#     version    : release tag (e.g. v0.12.0) or "latest"
#     source_dir : path to the Go source (agent-plugin/mcp) for the dev fallback build
#
# Resolution order: (1) already cached, (2) download the matching prebuilt from the
# Release, (3) dev fallback: build from source with Go. Prints the binary path on success.
# Idempotent and safe to run on every startup.

set -u

REPO="${1:?repo_url required}"
VERSION="${2:-latest}"
SRC="${3:-}"

BIN_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/wezterm-ai-agents/bin"
BIN="$BIN_DIR/wezterm-mcp"
# 調達済みバイナリのバージョンを併置で記録する。固定パスだけだとプラグイン更新後も古い
# バイナリを使い続けるため、要求 VERSION と一致する時だけキャッシュヒットとする。
VERSION_FILE="$BIN.version"

# Already provisioned at the requested version.
if [ -x "$BIN" ] && [ "$(cat "$VERSION_FILE" 2>/dev/null)" = "$VERSION" ]; then
  echo "$BIN"
  exit 0
fi

mkdir -p "$BIN_DIR"

# Map uname -> Go GOOS/GOARCH = release asset suffix.
case "$(uname -s)" in
  Darwin) goos=darwin ;;
  Linux) goos=linux ;;
  *) goos="" ;;
esac
case "$(uname -m)" in
  arm64 | aarch64) goarch=arm64 ;;
  x86_64 | amd64) goarch=amd64 ;;
  *) goarch="" ;;
esac
asset="wezterm-mcp-${goos}-${goarch}"

# (2) Download the prebuilt binary for this platform.
if [ -n "$goos" ] && [ -n "$goarch" ] && command -v curl >/dev/null 2>&1; then
  if [ "$VERSION" = "latest" ]; then
    url="$REPO/releases/latest/download/$asset"
  else
    url="$REPO/releases/download/$VERSION/$asset"
  fi
  tmp="$BIN.tmp.$$"
  if curl -fsSL "$url" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    chmod +x "$tmp" && mv "$tmp" "$BIN" && echo "$VERSION" > "$VERSION_FILE" && { echo "$BIN"; exit 0; }
  fi
  rm -f "$tmp"
fi

# (3) Dev fallback: build from source.
if [ -n "$SRC" ] && [ -d "$SRC" ] && command -v go >/dev/null 2>&1; then
  if (cd "$SRC" && go build -o "$BIN" .) >/dev/null 2>&1; then
    echo "$VERSION" > "$VERSION_FILE"
    echo "$BIN"
    exit 0
  fi
fi

echo "install_mcp: could not provision wezterm-mcp (no prebuilt for ${goos}-${goarch} and no Go fallback)" >&2
exit 1
