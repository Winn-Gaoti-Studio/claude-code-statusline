#!/usr/bin/env bash
# Cache and transport helpers for ~/.claude/statusline.sh.
# Sourcing this file only defines functions; it performs no I/O.

_claude_statusline_runtime_dir() {
  printf '%s' "${CLAUDE_STATUSLINE_RUNTIME_DIR:-/tmp/claude}"
}

_claude_statusline_get_oauth_token() {
  local token=""
  local blob=""

  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN"
    return 0
  fi

  if command -v security >/dev/null 2>&1; then
    blob="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)"
    if [ -n "$blob" ]; then
      token="$(printf '%s' "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)"
      if [ -n "$token" ] && [ "$token" != "null" ]; then
        printf '%s' "$token"
        return 0
      fi
    fi
  fi

  if [ -f "${HOME}/.claude/.credentials.json" ]; then
    token="$(jq -r '.claudeAiOauth.accessToken // empty' "${HOME}/.claude/.credentials.json" 2>/dev/null)"
    if [ -n "$token" ] && [ "$token" != "null" ]; then
      printf '%s' "$token"
      return 0
    fi
  fi

  if command -v secret-tool >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    blob="$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)"
    if [ -n "$blob" ]; then
      token="$(printf '%s' "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)"
      if [ -n "$token" ] && [ "$token" != "null" ]; then
        printf '%s' "$token"
        return 0
      fi
    fi
  fi

  return 1
}

_claude_statusline_request_usage() {
  local token="$1"

  (
    trap 'exit 1' HUP INT TERM
    printf 'Authorization: Bearer %s\n' "$token" | \
      curl -s --max-time 10 \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H @- \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/2.1.34" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null
  )
}

_claude_statusline_refresh_usage() {
  local cache_file="$1"
  local token=""
  local response=""
  local tmp=""

  token="$(_claude_statusline_get_oauth_token)" || return 0
  [ -n "$token" ] && [ "$token" != "null" ] || return 0

  response="$(_claude_statusline_request_usage "$token")" || return 0
  token=""

  [ -n "$response" ] || return 0
  printf '%s' "$response" | jq -e '.five_hour' >/dev/null 2>&1 || return 0

  (
    umask 077
    tmp="$(mktemp "${cache_file}.XXXXXX" 2>/dev/null)" || exit 1
    trap 'rm -f "$tmp"' EXIT HUP INT TERM
    printf '%s' "$response" > "$tmp" || exit 1
    mv -f "$tmp" "$cache_file" || exit 1
    trap - EXIT HUP INT TERM
  )
}

claude_statusline_read_usage() {
  local runtime_dir=""
  local cache_file=""

  runtime_dir="$(_claude_statusline_runtime_dir)"
  cache_file="$runtime_dir/statusline-usage-cache.json"
  [ -f "$cache_file" ] || return 1
  cat "$cache_file" 2>/dev/null
}

_claude_statusline_path_age() {
  local path="$1"
  local now=""
  local mtime=""

  [ -e "$path" ] || { printf '999999'; return 0; }
  now="$(date +%s 2>/dev/null)"
  mtime="$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null)"
  case "$now:$mtime" in
    *[!0-9:]*) printf '999999' ;;
    *) printf '%s' "$((now - mtime))" ;;
  esac
}

_claude_statusline_acquire_usage_lock() {
  local lock_file="$1"

  if command -v lockf >/dev/null 2>&1; then
    exec 9>"$lock_file" || return 1
    chmod 600 "$lock_file" 2>/dev/null || return 1
    lockf -s -t 0 9 >/dev/null 2>&1
    return $?
  fi

  if command -v flock >/dev/null 2>&1; then
    exec 9>"$lock_file" || return 1
    chmod 600 "$lock_file" 2>/dev/null || return 1
    flock -n 9 >/dev/null 2>&1
    return $?
  fi

  return 2
}

_claude_statusline_cleanup_legacy_auth_files() {
  local runtime_dir="$1"
  local auth_file=""
  local auth_age=""
  local auth_max_age=120

  while IFS= read -r auth_file; do
    [ -f "$auth_file" ] && [ ! -L "$auth_file" ] || continue
    auth_age="$(_claude_statusline_path_age "$auth_file")"
    [ "$auth_age" -ge "$auth_max_age" ] || continue
    rm -f "$auth_file" 2>/dev/null || true
  done < <(find "$runtime_dir" -maxdepth 1 -type f -name '.statusline-auth.*' -print 2>/dev/null)
}

claude_statusline_refresh_usage_async() {
  local runtime_dir=""
  local cache_file=""
  local lock_file=""
  local legacy_lock_dir=""
  local cache_max_age=60
  local lock_max_age=30
  local cache_age=""
  local legacy_lock_age=""

  runtime_dir="$(_claude_statusline_runtime_dir)"
  cache_file="$runtime_dir/statusline-usage-cache.json"
  lock_file="$runtime_dir/statusline-usage.lockfile"
  legacy_lock_dir="$runtime_dir/statusline-usage.lock"

  ( umask 077 && mkdir -p "$runtime_dir" 2>/dev/null ) || return 1
  cache_age="$(_claude_statusline_path_age "$cache_file")"
  [ "$cache_age" -ge "$cache_max_age" ] || return 0

  # A pre-refactor refresh may still own the legacy directory briefly. Defer
  # while it is plausibly live, but never delete it; deletion was racy with a
  # replacement owner. Old orphaned directories are ignored after 30 seconds.
  if [ -d "$legacy_lock_dir" ]; then
    legacy_lock_age="$(_claude_statusline_path_age "$legacy_lock_dir")"
    [ "$legacy_lock_age" -ge "$lock_max_age" ] || return 0
  fi

  (
    umask 077
    trap 'exit 1' HUP INT TERM
    _claude_statusline_acquire_usage_lock "$lock_file" || exit 0

    # Another owner may have refreshed between the caller's age check and
    # this lease acquisition. Recheck under the lease to avoid a second call.
    cache_age="$(_claude_statusline_path_age "$cache_file")"
    [ "$cache_age" -ge "$cache_max_age" ] || exit 0
    _claude_statusline_cleanup_legacy_auth_files "$runtime_dir"
    _claude_statusline_refresh_usage "$cache_file"
  ) </dev/null >/dev/null 2>&1 &

  return 0
}
