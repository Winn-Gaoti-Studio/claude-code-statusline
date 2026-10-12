#!/bin/bash
set -euo pipefail

INSTALL_DIR="$HOME/.claude"
TARGET_SETTINGS="$INSTALL_DIR/settings.json"
TARGET_MAIN="$INSTALL_DIR/statusline.sh"
TARGET_SUBAGENT="$INSTALL_DIR/subagent-statusline.sh"
TARGET_HELPER="$INSTALL_DIR/lib/statusline-cache.sh"
ORIGINAL_SETTINGS="$TARGET_SETTINGS.claude-statusline.original.bak"
NO_ORIGINAL_SETTINGS="$TARGET_SETTINGS.claude-statusline.no-original"

command -v jq >/dev/null 2>&1 || { printf 'Error: missing required tool: jq\n' >&2; exit 1; }

timestamp="$(date +%Y%m%dT%H%M%S)"
if [ -f "$ORIGINAL_SETTINGS" ] && [ ! -L "$ORIGINAL_SETTINGS" ]; then
  latest_backup="$ORIGINAL_SETTINGS"
elif [ -f "$NO_ORIGINAL_SETTINGS" ] && [ ! -L "$NO_ORIGINAL_SETTINGS" ]; then
  latest_backup=""
else
  # Keep the legacy timestamped-backup path for older installations.
  latest_backup="$(find "$INSTALL_DIR" -maxdepth 1 -type f -name 'settings.json.[0-9]*.bak' -print 2>/dev/null | sort | tail -1)"
fi

if [ -n "$latest_backup" ]; then
  if [ -f "$TARGET_SETTINGS" ]; then
    pre_uninstall_backup="${TARGET_SETTINGS}.pre-uninstall.${timestamp}.bak"
    cp "$TARGET_SETTINGS" "$pre_uninstall_backup"
    printf 'Saved pre-uninstall state: %s\n' "$pre_uninstall_backup"
  fi
  cp "$latest_backup" "$TARGET_SETTINGS"
  printf 'Restored:  %s (from %s)\n' "$TARGET_SETTINGS" "$latest_backup"
  if [ "$latest_backup" = "$ORIGINAL_SETTINGS" ]; then
    rm -f "$ORIGINAL_SETTINGS"
  fi
elif [ -f "$TARGET_SETTINGS" ]; then
  stripped="$(mktemp)"
  jq 'del(.statusLine, .subagentStatusLine)' "$TARGET_SETTINGS" > "$stripped"
  if jq -e '. == {}' "$stripped" >/dev/null; then
    rm -f "$TARGET_SETTINGS" "$stripped"
    printf 'Removed:   %s (contained only status-line settings)\n' "$TARGET_SETTINGS"
  else
    mv "$stripped" "$TARGET_SETTINGS"
    printf 'Updated:   %s (status-line settings removed)\n' "$TARGET_SETTINGS"
  fi
else
  printf 'Nothing to restore: %s does not exist.\n' "$TARGET_SETTINGS"
fi
if [ -f "$NO_ORIGINAL_SETTINGS" ] && [ ! -L "$NO_ORIGINAL_SETTINGS" ]; then
  rm -f "$NO_ORIGINAL_SETTINGS"
fi

for target in "$TARGET_MAIN" "$TARGET_SUBAGENT" "$TARGET_HELPER"; do
  if [ -f "$target" ]; then
    rm -f "$target"
    printf 'Removed:   %s\n' "$target"
  else
    printf 'Nothing to remove: %s does not exist.\n' "$target"
  fi
done
rmdir "$INSTALL_DIR/lib" 2>/dev/null || true

printf '\nUninstall complete. Restart Claude Code (exit, then `claude`) to apply.\n'
