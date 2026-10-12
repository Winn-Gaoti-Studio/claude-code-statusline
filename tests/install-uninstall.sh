#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

HOME_DIR="$TEMP_ROOT/home"
mkdir -p "$HOME_DIR/.claude"
printf '{"theme":"dark"}\n' > "$HOME_DIR/.claude/settings.json"

HOME="$HOME_DIR" INSTALL_FROM_LOCAL="$ROOT/statusline.sh" bash "$ROOT/install.sh" >/dev/null
cmp "$ROOT/statusline.sh" "$HOME_DIR/.claude/statusline.sh"
cmp "$ROOT/subagent-statusline.sh" "$HOME_DIR/.claude/subagent-statusline.sh"
cmp "$ROOT/lib/statusline-cache.sh" "$HOME_DIR/.claude/lib/statusline-cache.sh"
jq -e '. == {"theme":"dark"}' "$HOME_DIR/.claude/settings.json.claude-statusline.original.bak" >/dev/null
jq -e '
  .theme == "dark"
  and .statusLine.command == "bash \"$HOME/.claude/statusline.sh\""
  and .subagentStatusLine.command == "bash \"$HOME/.claude/subagent-statusline.sh\""
' "$HOME_DIR/.claude/settings.json" >/dev/null

HOME="$HOME_DIR" INSTALL_FROM_LOCAL="$ROOT/statusline.sh" bash "$ROOT/install.sh" >/dev/null
if [ "$(find "$HOME_DIR/.claude" -name 'settings.json.*.bak' | wc -l | tr -d ' ')" -ne 1 ]; then
  printf 'repeat install should not create a second backup\n' >&2
  exit 1
fi

# A changed bundle setting must not turn the installed state into the backup
# that uninstall later restores, even when both installs share a timestamp.
jq '.statusLine.refreshInterval = 15' "$HOME_DIR/.claude/settings.json" > "$TEMP_ROOT/edited-settings.json"
mv "$TEMP_ROOT/edited-settings.json" "$HOME_DIR/.claude/settings.json"
HOME="$HOME_DIR" INSTALL_FROM_LOCAL="$ROOT/statusline.sh" bash "$ROOT/install.sh" >/dev/null
jq -e '.statusLine.refreshInterval == 30' "$HOME_DIR/.claude/settings.json" >/dev/null
jq -e '. == {"theme":"dark"}' "$HOME_DIR/.claude/settings.json.claude-statusline.original.bak" >/dev/null

HOME="$HOME_DIR" bash "$ROOT/uninstall.sh" >/dev/null
jq -e '. == {"theme":"dark"}' "$HOME_DIR/.claude/settings.json" >/dev/null || {
  printf 'uninstall must restore the original settings after a changed-settings reinstall\n' >&2
  exit 1
}
test ! -e "$HOME_DIR/.claude/statusline.sh"
test ! -e "$HOME_DIR/.claude/subagent-statusline.sh"
test ! -e "$HOME_DIR/.claude/lib/statusline-cache.sh"

printf '{"theme":"light"}\n' > "$HOME_DIR/.claude/settings.json"
HOME="$HOME_DIR" INSTALL_FROM_LOCAL="$ROOT/statusline.sh" bash "$ROOT/install.sh" >/dev/null
HOME="$HOME_DIR" bash "$ROOT/uninstall.sh" >/dev/null
jq -e '. == {"theme":"light"}' "$HOME_DIR/.claude/settings.json" >/dev/null || {
  printf 'a later install must back up the settings current at that install\n' >&2
  exit 1
}

EMPTY_HOME="$TEMP_ROOT/empty-home"
HOME="$EMPTY_HOME" INSTALL_FROM_LOCAL="$ROOT/statusline.sh" bash "$ROOT/install.sh" >/dev/null
jq '.statusLine.refreshInterval = 15' "$EMPTY_HOME/.claude/settings.json" > "$TEMP_ROOT/edited-empty-settings.json"
mv "$TEMP_ROOT/edited-empty-settings.json" "$EMPTY_HOME/.claude/settings.json"
HOME="$EMPTY_HOME" INSTALL_FROM_LOCAL="$ROOT/statusline.sh" bash "$ROOT/install.sh" >/dev/null
HOME="$EMPTY_HOME" bash "$ROOT/uninstall.sh" >/dev/null
test ! -e "$EMPTY_HOME/.claude/settings.json" || {
  printf 'uninstall must remove bundle-only settings after a no-backup reinstall\n' >&2
  exit 1
}

LEGACY_HOME="$TEMP_ROOT/legacy-home"
mkdir -p "$LEGACY_HOME/.claude"
printf '{"theme":"dark"}\n' > "$LEGACY_HOME/.claude/settings.json.20260101000000.bak"
printf '%s\n' '{"theme":"dark","statusLine":{"type":"command","command":"bash \"$HOME/.claude/statusline.sh\"","refreshInterval":15},"subagentStatusLine":{"type":"command","command":"bash \"$HOME/.claude/subagent-statusline.sh\""}}' > "$LEGACY_HOME/.claude/settings.json"
HOME="$LEGACY_HOME" INSTALL_FROM_LOCAL="$ROOT/statusline.sh" bash "$ROOT/install.sh" >/dev/null
HOME="$LEGACY_HOME" bash "$ROOT/uninstall.sh" >/dev/null
jq -e '. == {"theme":"dark"}' "$LEGACY_HOME/.claude/settings.json" >/dev/null

LEGACY_MATCH_HOME="$TEMP_ROOT/legacy-match-home"
mkdir -p "$LEGACY_MATCH_HOME/.claude"
printf '{"theme":"dark"}\n' > "$LEGACY_MATCH_HOME/.claude/settings.json.20260101000000.bak"
printf '%s\n' '{"theme":"dark","statusLine":{"type":"command","command":"bash \"$HOME/.claude/statusline.sh\"","refreshInterval":15},"subagentStatusLine":{"type":"command","command":"bash \"$HOME/.claude/subagent-statusline.sh\""}}' > "$LEGACY_MATCH_HOME/.claude/settings.json.20260102000000.bak"
jq '.statusLine.refreshInterval = 30' "$LEGACY_MATCH_HOME/.claude/settings.json.20260102000000.bak" > "$LEGACY_MATCH_HOME/.claude/settings.json"
HOME="$LEGACY_MATCH_HOME" INSTALL_FROM_LOCAL="$ROOT/statusline.sh" bash "$ROOT/install.sh" >/dev/null
HOME="$LEGACY_MATCH_HOME" bash "$ROOT/uninstall.sh" >/dev/null
jq -e '. == {"theme":"dark"}' "$LEGACY_MATCH_HOME/.claude/settings.json" >/dev/null || {
  printf 'a matching legacy install must restore its earliest original backup\n' >&2
  exit 1
}

FOREIGN_HOME="$TEMP_ROOT/foreign-home"
mkdir -p "$FOREIGN_HOME/.claude"
printf '{"theme":"light"}\n' > "$FOREIGN_HOME/.claude/settings.json.20260101000000.bak"
printf '{"theme":"dark"}\n' > "$FOREIGN_HOME/.claude/settings.json"
HOME="$FOREIGN_HOME" INSTALL_FROM_LOCAL="$ROOT/statusline.sh" bash "$ROOT/install.sh" >/dev/null
HOME="$FOREIGN_HOME" bash "$ROOT/uninstall.sh" >/dev/null
jq -e '. == {"theme":"dark"}' "$FOREIGN_HOME/.claude/settings.json" >/dev/null

FOREIGN_EMPTY_HOME="$TEMP_ROOT/foreign-empty-home"
mkdir -p "$FOREIGN_EMPTY_HOME/.claude"
printf '{"theme":"light"}\n' > "$FOREIGN_EMPTY_HOME/.claude/settings.json.20260101000000.bak"
HOME="$FOREIGN_EMPTY_HOME" INSTALL_FROM_LOCAL="$ROOT/statusline.sh" bash "$ROOT/install.sh" >/dev/null
HOME="$FOREIGN_EMPTY_HOME" bash "$ROOT/uninstall.sh" >/dev/null
test ! -e "$FOREIGN_EMPTY_HOME/.claude/settings.json" || {
  printf 'an unrelated old backup must not be restored for a settings-free install\n' >&2
  exit 1
}

NO_BACKUP_HOME="$TEMP_ROOT/no-backup-home"
mkdir -p "$NO_BACKUP_HOME/.claude"
printf '{"theme":"light","statusLine":{"type":"command"},"subagentStatusLine":{"type":"command"}}\n' > "$NO_BACKUP_HOME/.claude/settings.json"
HOME="$NO_BACKUP_HOME" bash "$ROOT/uninstall.sh" >/dev/null
jq -e '. == {"theme":"light"}' "$NO_BACKUP_HOME/.claude/settings.json" >/dev/null

printf 'install and uninstall tests passed\n'
