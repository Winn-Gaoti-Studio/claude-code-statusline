#!/bin/bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/Winn-Gaoti-Studio/claude-code-statusline/main"
INSTALL_DIR="$HOME/.claude"
TARGET_SETTINGS="$INSTALL_DIR/settings.json"
TARGET_MAIN="$INSTALL_DIR/statusline.sh"
TARGET_SUBAGENT="$INSTALL_DIR/subagent-statusline.sh"
TARGET_HELPER="$INSTALL_DIR/lib/statusline-cache.sh"
ORIGINAL_SETTINGS="$TARGET_SETTINGS.claude-statusline.original.bak"
NO_ORIGINAL_SETTINGS="$TARGET_SETTINGS.claude-statusline.no-original"
SETTINGS_BLOCK='{"statusLine":{"type":"command","command":"bash \"$HOME/.claude/statusline.sh\"","refreshInterval":30},"subagentStatusLine":{"type":"command","command":"bash \"$HOME/.claude/subagent-statusline.sh\""}}'

for dependency in jq; do
  command -v "$dependency" >/dev/null 2>&1 || { printf 'Error: missing required tool: %s\n' "$dependency" >&2; exit 1; }
done
if [ -z "${INSTALL_FROM_LOCAL:-}" ]; then
  command -v curl >/dev/null 2>&1 || { printf 'Error: missing required tool: curl\n' >&2; exit 1; }
fi

mkdir -p "$INSTALL_DIR/lib"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

if [ -n "${INSTALL_FROM_LOCAL:-}" ]; then
  LOCAL_ROOT="$(cd "$(dirname "$INSTALL_FROM_LOCAL")" && pwd)"
  cp "$INSTALL_FROM_LOCAL" "$TEMP_DIR/statusline.sh"
  cp "$LOCAL_ROOT/subagent-statusline.sh" "$TEMP_DIR/subagent-statusline.sh"
  cp "$LOCAL_ROOT/lib/statusline-cache.sh" "$TEMP_DIR/statusline-cache.sh"
else
  curl -fsSL "$REPO_RAW/statusline.sh" -o "$TEMP_DIR/statusline.sh"
  curl -fsSL "$REPO_RAW/subagent-statusline.sh" -o "$TEMP_DIR/subagent-statusline.sh"
  curl -fsSL "$REPO_RAW/lib/statusline-cache.sh" -o "$TEMP_DIR/statusline-cache.sh"
fi

for script in statusline.sh subagent-statusline.sh statusline-cache.sh; do
  [ -s "$TEMP_DIR/$script" ] || { printf 'Error: %s is empty.\n' "$script" >&2; exit 1; }
  case "$(sed -n '1p' "$TEMP_DIR/$script")" in
    '#!'*bash*) ;;
    *) printf 'Error: %s is not a Bash script.\n' "$script" >&2; exit 1 ;;
  esac
done

install -m 755 "$TEMP_DIR/statusline.sh" "$TARGET_MAIN"
install -m 755 "$TEMP_DIR/subagent-statusline.sh" "$TARGET_SUBAGENT"
install -m 644 "$TEMP_DIR/statusline-cache.sh" "$TARGET_HELPER"

backup_path=""
if [ -f "$TARGET_SETTINGS" ]; then
  already_installed=false
  if jq -e --argjson desired "$SETTINGS_BLOCK" '
    .statusLine.command == $desired.statusLine.command
    and .subagentStatusLine.command == $desired.subagentStatusLine.command
  ' "$TARGET_SETTINGS" >/dev/null 2>&1; then
    already_installed=true
  fi
  if [ ! -e "$ORIGINAL_SETTINGS" ] && [ ! -L "$ORIGINAL_SETTINGS" ] && [ ! -f "$NO_ORIGINAL_SETTINGS" ]; then
    if [ "$already_installed" = true ]; then
      # Older installs used timestamped backups; preserve the first one.
      legacy_backup="$(find "$INSTALL_DIR" -maxdepth 1 -type f -name 'settings.json.[0-9]*.bak' -print | sort | head -1)"
      if [ -n "$legacy_backup" ]; then
        cp "$legacy_backup" "$ORIGINAL_SETTINGS"
        backup_path="$ORIGINAL_SETTINGS"
      fi
    else
      cp "$TARGET_SETTINGS" "$ORIGINAL_SETTINGS"
      backup_path="$ORIGINAL_SETTINGS"
    fi
  fi
  if ! jq -e --argjson desired "$SETTINGS_BLOCK" '
    .statusLine == $desired.statusLine
    and .subagentStatusLine == $desired.subagentStatusLine
  ' "$TARGET_SETTINGS" >/dev/null 2>&1; then
    merged="$(mktemp)"
    jq -s '.[0] * .[1]' "$TARGET_SETTINGS" <(printf '%s\n' "$SETTINGS_BLOCK") > "$merged"
    mv "$merged" "$TARGET_SETTINGS"
  fi
else
  if [ ! -e "$NO_ORIGINAL_SETTINGS" ] && [ ! -L "$NO_ORIGINAL_SETTINGS" ]; then
    : > "$NO_ORIGINAL_SETTINGS"
  fi
  printf '%s\n' "$SETTINGS_BLOCK" | jq '.' > "$TARGET_SETTINGS"
fi

printf '\nInstalled: %s\n' "$TARGET_MAIN"
printf 'Installed: %s\n' "$TARGET_SUBAGENT"
printf 'Installed: %s\n' "$TARGET_HELPER"
[ -z "$backup_path" ] || printf 'Backup:    %s\n' "$backup_path"
printf 'Settings:  %s\n\n' "$TARGET_SETTINGS"
printf 'Restart Claude Code (exit, then `claude`) for the status lines to take effect.\n'
