#!/usr/bin/env bash
# Hermetic behavior checks for the Claude status line and cache helper.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATUSLINE_SOURCE="$ROOT/statusline.sh"
SUBAGENT_SOURCE="$ROOT/subagent-statusline.sh"
HELPER_SOURCE="$ROOT/lib/statusline-cache.sh"
REAL_JQ="$(command -v jq)"
REAL_GIT="$(command -v git)"
ORIGINAL_PATH="$PATH"
TEMP_ROOT="$(mktemp -d)" || exit 1
FAILED=0
SMOKE_SESSION="codex-statusline-smoke-$$"

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1"
  FAILED=$((FAILED + 1))
}

assert_status() {
  if [ "$STATUS" -eq "$1" ]; then
    pass "$2"
  else
    fail "$2 (expected exit $1, got $STATUS)"
  fi
}

assert_empty() {
  if [ -z "$1" ]; then
    pass "$2"
  else
    fail "$2"
  fi
}

assert_equal() {
  if [ "$1" = "$2" ]; then
    pass "$3"
  else
    fail "$3"
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) pass "$3" ;;
    *) fail "$3" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3" ;;
    *) pass "$3" ;;
  esac
}

strip_ansi() {
  printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'
}

wait_for_file() {
  local path="$1"
  local attempts=0
  while [ ! -e "$path" ] && [ "$attempts" -lt 200 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  [ -e "$path" ]
}

wait_for_usage() {
  local path="$1"
  local expected="$2"
  local attempts=0
  while ! "$REAL_JQ" -e --argjson expected "$expected" '.five_hour.utilization == $expected' "$path" >/dev/null 2>&1 \
    && [ "$attempts" -lt 200 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  "$REAL_JQ" -e --argjson expected "$expected" '.five_hour.utilization == $expected' "$path" >/dev/null 2>&1
}

write_fake_commands() {
  cat > "$FAKE_BIN/jq" <<'EOF'
#!/usr/bin/env bash
exec "$REAL_JQ" "$@"
EOF

  cat > "$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
printf 'call\n' >> "$FAKE_SECURITY_LOG"
if [ -n "${FAKE_SECURITY_BLOB:-}" ]; then
  printf '%s' "$FAKE_SECURITY_BLOB"
  exit 0
fi
exit 44
EOF

  cat > "$FAKE_BIN/secret-tool" <<'EOF'
#!/usr/bin/env bash
exit 44
EOF

  cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf 'call\n' >> "$FAKE_CURL_LOG"
trap '[ -z "${FAKE_CURL_FINISHED:-}" ] || : > "$FAKE_CURL_FINISHED"' EXIT

authorization_ok=false
header_stdin_ok=false
token_in_argv=false
previous=""
for argument in "$@"; do
  if [ -n "${FAKE_CURL_EXPECT_TOKEN:-}" ]; then
    case "$argument" in
      *"$FAKE_CURL_EXPECT_TOKEN"*) token_in_argv=true ;;
    esac
  fi
  if [ "$previous" = "-H" ]; then
    case "$argument" in
      @-)
        header_content="$(cat)"
        if [ "$header_content" = "Authorization: Bearer ${FAKE_CURL_EXPECT_TOKEN:-}" ]; then
          authorization_ok=true
          header_stdin_ok=true
        fi
        ;;
    esac
  fi
  previous="$argument"
done

[ "$token_in_argv" = "false" ] || printf 'token-in-argv\n' >> "$FAKE_CURL_LOG"
[ "$header_stdin_ok" = "false" ] || printf 'header-stdin\n' >> "$FAKE_CURL_LOG"

if [ "$authorization_ok" != "true" ]; then
  printf 'bad-authorization\n' >> "$FAKE_CURL_LOG"
  exit 65
fi

if [ "${FAKE_CURL_FAIL:-0}" = "1" ]; then
  exit 28
fi

if [ "${FAKE_CURL_BLOCK:-0}" = "1" ]; then
  : > "$FAKE_CURL_STARTED"
  attempts=0
  while [ ! -e "$FAKE_CURL_RELEASE" ] && [ "$attempts" -lt 500 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
fi

[ -z "${FAKE_CURL_RESPONSE_FILE:-}" ] || cat "$FAKE_CURL_RESPONSE_FILE"
EOF

  cat > "$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
[ -z "${FAKE_GIT_LOG:-}" ] || printf '%s\n' "$*" >> "$FAKE_GIT_LOG"
if [ "${1:-}" = "-C" ]; then
  shift 2
fi

case "${1:-}" in
  rev-parse)
    case "${2:-}" in
      --is-inside-work-tree)
        [ "${FAKE_GIT_MODE:-none}" = "none" ] && exit 1
        printf 'true\n'
        ;;
      --git-common-dir)
        printf '%s\n' "${FAKE_GIT_COMMON_DIR:-/workspace/project/.git}"
        ;;
      *) exit 91 ;;
    esac
    ;;
  symbolic-ref)
    [ "${2:-}" = "--short" ] && [ "${3:-}" = "HEAD" ] || exit 91
    [ -n "${FAKE_GIT_BRANCH-main}" ] || exit 128
    printf '%s\n' "${FAKE_GIT_BRANCH-main}"
    ;;
  --no-optional-locks)
    shift
    [ "${1:-}" = "status" ] && [ "${2:-}" = "--porcelain" ] \
      && [ "${3:-}" = "--untracked-files=no" ] && [ "$#" -eq 3 ] || exit 91
    [ "${FAKE_GIT_MODE:-clean}" = "dirty" ] && printf ' M tracked-file\n'
    ;;
  *)
    # Reject status when the Git-global flag is misplaced after --porcelain.
    exit 91
    ;;
esac
EOF

  cat > "$FAKE_BIN/jj" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$PWD $*" >> "$FAKE_JJ_LOG"
[ "${FAKE_JJ_MODE:-none}" = "repo" ] || exit 1
printf '%s' "${FAKE_JJ_BOOKMARK:-}"
EOF

  chmod +x "$FAKE_BIN/jq" "$FAKE_BIN/security" "$FAKE_BIN/secret-tool" "$FAKE_BIN/curl" "$FAKE_BIN/git" "$FAKE_BIN/jj"
}

new_case() {
  CASE_DIR="$TEMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  RUNTIME_DIR="$CASE_DIR/runtime"
  FAKE_BIN="$CASE_DIR/bin"
  FAKE_CURL_LOG="$CASE_DIR/curl.log"
  FAKE_SECURITY_LOG="$CASE_DIR/security.log"
  FAKE_CURL_STARTED="$CASE_DIR/curl.started"
  FAKE_CURL_FINISHED="$CASE_DIR/curl.finished"
  FAKE_CURL_RELEASE="$CASE_DIR/curl.release"
  FAKE_CURL_RESPONSE_FILE="$CASE_DIR/curl-response.json"
  STDERR_FILE="$CASE_DIR/stderr"
  FAKE_GIT_MODE=clean
  FAKE_GIT_BRANCH=main
  FAKE_GIT_COMMON_DIR=/workspace/project/.git
  FAKE_JJ_MODE=none
  FAKE_JJ_BOOKMARK=""
  FAKE_JJ_LOG="$CASE_DIR/jj.log"
  FAKE_GIT_LOG="$CASE_DIR/git.log"
  TEST_GIT_TTL=""
  TEST_GIT_DIR=""
  FAKE_CURL_BLOCK=0
  FAKE_CURL_FAIL=0
  TEST_OAUTH_TOKEN=""
  TEST_COLUMNS=""
  mkdir -p "$HOME_DIR/.claude/lib" "$FAKE_BIN"
  ln -s "$STATUSLINE_SOURCE" "$HOME_DIR/.claude/statusline.sh"
  ln -s "$HELPER_SOURCE" "$HOME_DIR/.claude/lib/statusline-cache.sh"
  write_fake_commands
}

base_input() {
  printf '%s' '{"model":{"display_name":"Claude Opus"},"context_window":{"context_window_size":200000,"used_percentage":42.9,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":3000,"output_tokens":4000}},"cwd":"/workspace/repo","workspace":{"git_worktree":""},"effort":{"level":"high"},"session_id":"'"$SMOKE_SESSION"'"}'
}

run_statusline() {
  local input="$1"
  STATUS=0
  OUTPUT="$(printf '%s' "$input" | env -i \
    HOME="$HOME_DIR" \
    PATH="$FAKE_BIN:$ORIGINAL_PATH" \
    REAL_JQ="$REAL_JQ" \
    CLAUDE_STATUSLINE_RUNTIME_DIR="$RUNTIME_DIR" \
    CLAUDE_CODE_OAUTH_TOKEN="${TEST_OAUTH_TOKEN:-}" \
    FAKE_GIT_MODE="${FAKE_GIT_MODE:-clean}" \
    FAKE_GIT_BRANCH="${FAKE_GIT_BRANCH-main}" \
    FAKE_JJ_MODE="${FAKE_JJ_MODE:-none}" \
    FAKE_JJ_BOOKMARK="${FAKE_JJ_BOOKMARK:-}" \
    FAKE_JJ_LOG="$FAKE_JJ_LOG" \
    FAKE_GIT_LOG="$FAKE_GIT_LOG" \
    FAKE_GIT_COMMON_DIR="${FAKE_GIT_COMMON_DIR:-/workspace/project/.git}" \
    FAKE_CURL_LOG="$FAKE_CURL_LOG" \
    FAKE_SECURITY_LOG="$FAKE_SECURITY_LOG" \
    FAKE_CURL_EXPECT_TOKEN="${TEST_OAUTH_TOKEN:-}" \
    FAKE_CURL_RESPONSE_FILE="$FAKE_CURL_RESPONSE_FILE" \
    FAKE_CURL_STARTED="$FAKE_CURL_STARTED" \
    FAKE_CURL_FINISHED="$FAKE_CURL_FINISHED" \
    FAKE_CURL_RELEASE="$FAKE_CURL_RELEASE" \
    FAKE_CURL_BLOCK="${FAKE_CURL_BLOCK:-0}" \
    FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-0}" \
    ${TEST_COLUMNS:+COLUMNS="$TEST_COLUMNS"} \
    ${TEST_GIT_TTL:+CLAUDE_STATUSLINE_GIT_TTL="$TEST_GIT_TTL"} \
    ${TEST_GIT_DIR:+GIT_DIR="$TEST_GIT_DIR"} \
    bash --noprofile --norc "$HOME_DIR/.claude/statusline.sh" 2>"$STDERR_FILE")" || STATUS=$?
  STDERR_OUTPUT="$(cat "$STDERR_FILE" 2>/dev/null)"
}

write_usage() {
  local path="$1" five="$2" seven="$3"
  mkdir -p "$(dirname "$path")"
  printf '{"five_hour":{"utilization":%s,"resets_at":null},"seven_day":{"utilization":%s,"resets_at":null},"extra_usage":{"is_enabled":false}}\n' "$five" "$seven" > "$path"
}

write_usage_json() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
}

# ISO-8601 UTC like the usage API's resets_at, on GNU or BSD date.
iso_utc() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%S+00:00 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%S+00:00
}

# A sourced helper must define only inert shell functions until one is called.
new_case source-contract
STATUS=0
SOURCE_OUTPUT="$(env -i HOME="$HOME_DIR" PATH="$FAKE_BIN:$ORIGINAL_PATH" REAL_JQ="$REAL_JQ" \
  CLAUDE_STATUSLINE_RUNTIME_DIR="$RUNTIME_DIR" bash --noprofile --norc -c '
    before_umask=$(umask)
    before_options=$(set +o)
    . "$1" || exit 10
    [ "$before_umask" = "$(umask)" ] || exit 11
    [ "$before_options" = "$(set +o)" ] || exit 12
    declare -F claude_statusline_read_usage >/dev/null || exit 14
    declare -F claude_statusline_refresh_usage_async >/dev/null || exit 15
  ' bash "$HELPER_SOURCE" 2>&1)" || STATUS=$?
assert_status 0 "cache helper can be sourced"
assert_empty "$SOURCE_OUTPUT" "sourcing the cache helper has no output"
if [ ! -e "$RUNTIME_DIR" ]; then
  pass "sourcing the cache helper creates no runtime state"
else
  fail "sourcing the cache helper creates no runtime state"
fi

# Characterization snapshots keep the existing visual format byte-for-byte.
new_case clean-snapshot
FAKE_GIT_MODE=clean
run_statusline "$(base_input)"
EXPECTED_CLEAN="$(printf '\033[1;38;2;130;170;255mClaude Opus\033[0m \033[38;2;130;170;255mhigh\033[0m \033[2m│\033[0m \033[38;2;125;205;160m42%%\033[0m \033[2m6k/200k\033[0m \033[2m│\033[0m \033[38;2;130;170;255mrepo\033[0m \033[38;2;195;165;255m(main\033[38;2;240;120;135m\033[38;2;195;165;255m)\033[0m')"
assert_status 0 "clean statusline exits successfully"
assert_equal "$OUTPUT" "$EXPECTED_CLEAN" "clean ANSI snapshot is unchanged"
assert_empty "$STDERR_OUTPUT" "clean statusline has no stderr"

new_case dirty-snapshot
FAKE_GIT_MODE=dirty
run_statusline "$(base_input)"
EXPECTED_DIRTY="$(printf '\033[1;38;2;130;170;255mClaude Opus\033[0m \033[38;2;130;170;255mhigh\033[0m \033[2m│\033[0m \033[38;2;125;205;160m42%%\033[0m \033[2m6k/200k\033[0m \033[2m│\033[0m \033[38;2;130;170;255mrepo\033[0m \033[38;2;195;165;255m(main\033[38;2;240;120;135m*\033[38;2;195;165;255m)\033[0m')"
assert_equal "$OUTPUT" "$EXPECTED_DIRTY" "dirty repository restores the red asterisk"

new_case worktree-snapshot
FAKE_GIT_MODE=dirty
FAKE_GIT_BRANCH=gaotity/long-topic
FAKE_GIT_COMMON_DIR=/workspace/project/.git
WORKTREE_INPUT="$(base_input | "$REAL_JQ" -c '.cwd="/workspace/topic-worktree" | .workspace.git_worktree="/workspace/project/.git/worktrees/topic-worktree"')"
run_statusline "$WORKTREE_INPUT"
EXPECTED_WORKTREE="$(printf '\033[1;38;2;130;170;255mClaude Opus\033[0m \033[38;2;130;170;255mhigh\033[0m \033[2m│\033[0m \033[38;2;125;205;160m42%%\033[0m \033[2m6k/200k\033[0m \033[2m│\033[0m \033[38;2;130;170;255mproject\033[0m 🌳 \033[38;2;195;165;255mlong-topic\033[38;2;240;120;135m*\033[0m')"
assert_equal "$OUTPUT" "$EXPECTED_WORKTREE" "worktree ANSI snapshot is unchanged"
if [ ! -e "$FAKE_JJ_LOG" ]; then
  pass "a checked-out Git branch does not run jj"
else
  fail "a checked-out Git branch does not run jj"
fi

# A jj workspace leaves Git HEAD detached; the bookmark takes the place of the branch.
new_case jj-bookmark
mkdir -p "$CASE_DIR/repo"
FAKE_GIT_MODE=dirty
FAKE_GIT_BRANCH=""
FAKE_JJ_MODE=repo
FAKE_JJ_BOOKMARK=topic
run_statusline "$(base_input | "$REAL_JQ" -c --arg cwd "$CASE_DIR/repo" '.cwd=$cwd')"
assert_status 0 "a jj workspace statusline exits successfully"
assert_contains "$(strip_ansi "$OUTPUT")" "repo (topic*)" "a jj workspace shows its bookmark and dirty state"
JJ_CALL="$(cat "$FAKE_JJ_LOG" 2>/dev/null)"
assert_contains "$JJ_CALL" "$CASE_DIR/repo " "jj runs in the session directory"
assert_contains "$JJ_CALL" "--ignore-working-copy" "the jj query does not snapshot the working copy"
assert_contains "$JJ_CALL" "--at-op @" "the jj query does not merge or write operations"
assert_empty "$STDERR_OUTPUT" "a jj workspace statusline has no stderr"

new_case jj-worktree
mkdir -p "$CASE_DIR/topic-worktree"
FAKE_GIT_MODE=clean
FAKE_GIT_BRANCH=""
FAKE_JJ_MODE=repo
FAKE_JJ_BOOKMARK=topic
run_statusline "$(base_input | "$REAL_JQ" -c --arg cwd "$CASE_DIR/topic-worktree" '.cwd=$cwd | .workspace.git_worktree="topic-worktree"')"
assert_contains "$(strip_ansi "$OUTPUT")" "project 🌳 topic" "a jj worktree shows the main repository and its bookmark"

new_case detached-without-jj
mkdir -p "$CASE_DIR/repo"
FAKE_GIT_BRANCH=""
FAKE_JJ_MODE=none
run_statusline "$(base_input | "$REAL_JQ" -c --arg cwd "$CASE_DIR/repo" '.cwd=$cwd')"
assert_status 0 "a detached Git HEAD outside jj exits successfully"
assert_not_contains "$(strip_ansi "$OUTPUT")" "(" "a detached Git HEAD outside jj shows no branch"
assert_empty "$STDERR_OUTPUT" "a detached Git HEAD outside jj has no stderr"

# The Git result is cached per directory, so a render inside the TTL starts no Git process.
git_calls() {
  if [ -f "$FAKE_GIT_LOG" ]; then
    wc -l < "$FAKE_GIT_LOG" | tr -d ' '
  else
    printf '0'
  fi
}

git_cache_file() {
  find "$RUNTIME_DIR" -maxdepth 1 -name 'statusline-git-*' -print -quit 2>/dev/null
}

# Set the stored time of a cache file to epoch second 1, so the file is older than any TTL.
age_git_cache() {
  awk 'NR == 2 { print 1; next } { print }' "$1" > "$1.aged" && mv -f "$1.aged" "$1"
}

real_git() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$REAL_GIT" "$@"
}

new_case git-cache-hit
run_statusline "$(base_input)"
FIRST_OUTPUT="$OUTPUT"
FIRST_CALLS="$(git_calls)"
assert_equal "$FIRST_CALLS" "3" "the first render probes Git three times"
if [ -n "$(git_cache_file)" ]; then
  pass "the first render writes a Git cache file"
else
  fail "the first render writes a Git cache file"
fi
FAKE_GIT_BRANCH=changed
FAKE_GIT_MODE=dirty
run_statusline "$(base_input)"
assert_equal "$(git_calls)" "$FIRST_CALLS" "a render inside the TTL starts no Git process"
assert_equal "$OUTPUT" "$FIRST_OUTPUT" "a render inside the TTL shows the cached branch and dirty state"
assert_empty "$STDERR_OUTPUT" "a cached render has no stderr"

# A different directory is a different cache entry.
run_statusline "$(base_input | "$REAL_JQ" -c '.cwd="/workspace/other"')"
assert_contains "$(strip_ansi "$OUTPUT")" "other (changed*)" "a new directory does not reuse the cache of another directory"
assert_equal "$(git_calls)" "$((FIRST_CALLS + 3))" "a new directory probes Git again"

# An old cache file is ignored and replaced.
new_case git-cache-expired
run_statusline "$(base_input)"
FIRST_CALLS="$(git_calls)"
age_git_cache "$(git_cache_file)"
FAKE_GIT_BRANCH=changed
run_statusline "$(base_input)"
assert_equal "$(git_calls)" "$((FIRST_CALLS * 2))" "a render after the TTL probes Git again"
assert_contains "$(strip_ansi "$OUTPUT")" "repo (changed)" "a render after the TTL shows the live branch"
run_statusline "$(base_input)"
assert_equal "$(git_calls)" "$((FIRST_CALLS * 2))" "the live result replaces the old cache file"

new_case git-cache-ttl-zero
TEST_GIT_TTL=0
run_statusline "$(base_input)"
FIRST_CALLS="$(git_calls)"
FAKE_GIT_BRANCH=changed
run_statusline "$(base_input)"
assert_equal "$(git_calls)" "$((FIRST_CALLS * 2))" "a TTL of 0 probes Git on every render"
assert_contains "$(strip_ansi "$OUTPUT")" "repo (changed)" "a TTL of 0 shows the live branch"
if [ -z "$(git_cache_file)" ]; then
  pass "a TTL of 0 writes no Git cache file"
else
  fail "a TTL of 0 writes no Git cache file"
fi

new_case git-cache-ttl-invalid
TEST_GIT_TTL=soon
run_statusline "$(base_input)"
FIRST_CALLS="$(git_calls)"
run_statusline "$(base_input)"
assert_equal "$(git_calls)" "$FIRST_CALLS" "an invalid TTL falls back to the default of 30 seconds"

# A TTL that the shell cannot compare as an integer also falls back to the default.
new_case git-cache-ttl-overflow
TEST_GIT_TTL=999999999999999999999
run_statusline "$(base_input)"
FIRST_CALLS="$(git_calls)"
run_statusline "$(base_input)"
assert_equal "$(git_calls)" "$FIRST_CALLS" "a TTL out of the integer range falls back to the default of 30 seconds"
assert_empty "$STDERR_OUTPUT" "a TTL out of the integer range is silent"

# GIT_DIR selects the repository, but the cache key has only the directory. Thus no cache.
new_case git-cache-git-dir
TEST_GIT_DIR=/workspace/alpha.git
run_statusline "$(base_input)"
FIRST_CALLS="$(git_calls)"
FAKE_GIT_BRANCH=beta
TEST_GIT_DIR=/workspace/beta.git
run_statusline "$(base_input)"
assert_equal "$(git_calls)" "$((FIRST_CALLS * 2))" "a session with GIT_DIR probes Git on every render"
assert_contains "$(strip_ansi "$OUTPUT")" "repo (beta)" "a session with GIT_DIR shows the live branch"
if [ -z "$(git_cache_file)" ]; then
  pass "a session with GIT_DIR writes no Git cache file"
else
  fail "a session with GIT_DIR writes no Git cache file"
fi

# A FIFO in place of the cache file must not block the render.
new_case git-cache-fifo
run_statusline "$(base_input)"
CACHE_FILE="$(git_cache_file)"
rm -f "$CACHE_FILE"
mkfifo "$CACHE_FILE"
FAKE_GIT_BRANCH=fifo
( sleep 5; [ -p "$CACHE_FILE" ] && printf '' > "$CACHE_FILE" ) >/dev/null 2>&1 &
FIFO_GUARD=$!
FIFO_START=$(date +%s)
run_statusline "$(base_input)"
FIFO_ELAPSED=$(( $(date +%s) - FIFO_START ))
kill "$FIFO_GUARD" 2>/dev/null
wait "$FIFO_GUARD" 2>/dev/null
if [ "$FIFO_ELAPSED" -lt 4 ]; then
  pass "a FIFO in place of the Git cache does not block the render"
else
  fail "a FIFO in place of the Git cache does not block the render"
fi
assert_contains "$(strip_ansi "$OUTPUT")" "repo (fifo)" "a FIFO in place of the Git cache falls back to the live probe"

new_case git-cache-corrupt
run_statusline "$(base_input)"
FIRST_CALLS="$(git_calls)"
CACHE_FILE="$(git_cache_file)"
printf 'garbage\n' > "$CACHE_FILE"
FAKE_GIT_BRANCH=changed
run_statusline "$(base_input)"
assert_equal "$(git_calls)" "$((FIRST_CALLS * 2))" "a corrupt Git cache falls back to the live probe"
assert_contains "$(strip_ansi "$OUTPUT")" "repo (changed)" "a corrupt Git cache shows the live branch"
assert_empty "$STDERR_OUTPUT" "a corrupt Git cache is silent"
head -n 5 "$CACHE_FILE" > "$CACHE_FILE.short" && mv -f "$CACHE_FILE.short" "$CACHE_FILE"
FAKE_GIT_BRANCH=truncated
run_statusline "$(base_input)"
assert_contains "$(strip_ansi "$OUTPUT")" "repo (truncated)" "a truncated Git cache falls back to the live probe"
rm -f "$CACHE_FILE"
mkdir "$CACHE_FILE"
FAKE_GIT_BRANCH=directory
run_statusline "$(base_input)"
assert_status 0 "a directory in place of the Git cache keeps the statusline successful"
assert_contains "$(strip_ansi "$OUTPUT")" "repo (directory)" "a directory in place of the Git cache falls back to the live probe"
assert_empty "$STDERR_OUTPUT" "a directory in place of the Git cache is silent"

new_case git-cache-unwritable
printf 'not a directory\n' > "$RUNTIME_DIR"
run_statusline "$(base_input)"
FIRST_CALLS="$(git_calls)"
FAKE_GIT_BRANCH=changed
run_statusline "$(base_input)"
assert_equal "$(git_calls)" "$((FIRST_CALLS * 2))" "an unwritable runtime directory probes Git on every render"
assert_contains "$(strip_ansi "$OUTPUT")" "repo (changed)" "an unwritable runtime directory shows the live branch"
assert_empty "$STDERR_OUTPUT" "an unwritable runtime directory is silent"

# The dirty mark ignores untracked files and follows changes to tracked files.
new_case dirty-tracked-only
rm -f "$FAKE_BIN/git"
TEST_GIT_TTL=0
REPO_DIR="$CASE_DIR/repo"
mkdir -p "$REPO_DIR"
real_git -C "$REPO_DIR" init -q
real_git -C "$REPO_DIR" symbolic-ref HEAD refs/heads/main
printf 'one\n' > "$REPO_DIR/tracked"
real_git -C "$REPO_DIR" add tracked
real_git -C "$REPO_DIR" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false commit -q -m init
REPO_INPUT="$(base_input | "$REAL_JQ" -c --arg cwd "$REPO_DIR" '.cwd=$cwd')"
run_statusline "$REPO_INPUT"
assert_contains "$(strip_ansi "$OUTPUT")" "repo (main)" "a clean repository shows no dirty mark"
printf 'new\n' > "$REPO_DIR/untracked"
run_statusline "$REPO_INPUT"
assert_contains "$(strip_ansi "$OUTPUT")" "repo (main)" "an untracked file alone shows no dirty mark"
printf 'two\n' > "$REPO_DIR/tracked"
run_statusline "$REPO_INPUT"
assert_contains "$(strip_ansi "$OUTPUT")" "repo (main*)" "a modified tracked file shows the dirty mark"
real_git -C "$REPO_DIR" checkout -q -- tracked
run_statusline "$REPO_INPUT"
assert_contains "$(strip_ansi "$OUTPUT")" "repo (main)" "a restored tracked file clears the dirty mark"
real_git -C "$REPO_DIR" add untracked
run_statusline "$REPO_INPUT"
assert_contains "$(strip_ansi "$OUTPUT")" "repo (main*)" "a staged new file shows the dirty mark"
real_git -C "$REPO_DIR" reset -q
rm -f "$REPO_DIR/tracked"
run_statusline "$REPO_INPUT"
assert_contains "$(strip_ansi "$OUTPUT")" "repo (main*)" "a deleted tracked file shows the dirty mark"

# Fresh usage renders immediately without an API refresh.
new_case fresh-cache
write_usage "$RUNTIME_DIR/statusline-usage-cache.json" 11 22
TEST_OAUTH_TOKEN="statusline-token-$RANDOM-$$"
FAKE_GIT_MODE=clean
run_statusline "$(base_input)"
assert_contains "$OUTPUT" "11%" "fresh cache renders current usage"
assert_contains "$OUTPUT" "22%" "fresh cache renders weekly usage"
if [ ! -e "$FAKE_CURL_LOG" ]; then
  pass "fresh cache performs no usage request"
else
  fail "fresh cache performs no usage request"
fi

# A stale cache renders last-known-good data while one detached refresh runs.
new_case stale-cache
write_usage "$RUNTIME_DIR/statusline-usage-cache.json" 10 20
touch -t 202001010000 "$RUNTIME_DIR/statusline-usage-cache.json"
write_usage "$FAKE_CURL_RESPONSE_FILE" 30 40
TEST_OAUTH_TOKEN="statusline-token-$RANDOM-$$"
FAKE_CURL_BLOCK=1
run_statusline "$(base_input)"
assert_contains "$OUTPUT" "10%" "stale cache remains available during refresh"
if wait_for_file "$FAKE_CURL_STARTED"; then
  pass "stale cache starts a detached refresh"
else
  fail "stale cache starts a detached refresh"
fi
if grep -q '^token-in-argv$' "$FAKE_CURL_LOG" 2>/dev/null; then
  fail "OAuth token is absent from curl argv"
else
  pass "OAuth token is absent from curl argv"
fi
if grep -q '^header-stdin$' "$FAKE_CURL_LOG" 2>/dev/null; then
  pass "OAuth header is delivered to curl on stdin"
else
  fail "OAuth header is delivered to curl on stdin"
fi
if [ ! -e "$FAKE_CURL_FINISHED" ]; then
  pass "stale refresh remains detached after rendering returns"
else
  fail "stale refresh remains detached after rendering returns"
fi
: > "$FAKE_CURL_RELEASE"
if wait_for_usage "$RUNTIME_DIR/statusline-usage-cache.json" 30; then
  pass "successful refresh atomically replaces the stale cache"
else
  fail "successful refresh atomically replaces the stale cache"
fi
if find "$RUNTIME_DIR" -name '.statusline-auth.*' -print -quit | grep -q .; then
  fail "OAuth header never persists after refresh"
else
  pass "OAuth header never persists after refresh"
fi

# Concurrent stale renders share one native lock and therefore one request.
new_case concurrent-lock
write_usage "$RUNTIME_DIR/statusline-usage-cache.json" 12 24
touch -t 202001010000 "$RUNTIME_DIR/statusline-usage-cache.json"
mkdir -p "$RUNTIME_DIR/statusline-usage.lock"
touch -t 202001010000 "$RUNTIME_DIR/statusline-usage.lock"
write_usage "$FAKE_CURL_RESPONSE_FILE" 36 48
TEST_OAUTH_TOKEN="statusline-token-$RANDOM-$$"
FAKE_CURL_BLOCK=1
INPUT="$(base_input)"
RUNNER_PIDS=""
for number in 1 2; do
  (
    status=0
    printf '%s' "$INPUT" | env -i \
      HOME="$HOME_DIR" PATH="$FAKE_BIN:$ORIGINAL_PATH" REAL_JQ="$REAL_JQ" \
      CLAUDE_STATUSLINE_RUNTIME_DIR="$RUNTIME_DIR" CLAUDE_CODE_OAUTH_TOKEN="$TEST_OAUTH_TOKEN" \
      FAKE_GIT_MODE=clean FAKE_GIT_BRANCH=main FAKE_GIT_COMMON_DIR=/workspace/project/.git \
      FAKE_CURL_LOG="$FAKE_CURL_LOG" FAKE_SECURITY_LOG="$FAKE_SECURITY_LOG" \
      FAKE_CURL_EXPECT_TOKEN="$TEST_OAUTH_TOKEN" FAKE_CURL_RESPONSE_FILE="$FAKE_CURL_RESPONSE_FILE" \
      FAKE_CURL_STARTED="$FAKE_CURL_STARTED" FAKE_CURL_FINISHED="$FAKE_CURL_FINISHED" FAKE_CURL_RELEASE="$FAKE_CURL_RELEASE" \
      FAKE_CURL_BLOCK=1 FAKE_CURL_FAIL=0 bash --noprofile --norc "$HOME_DIR/.claude/statusline.sh" \
      > "$CASE_DIR/output-$number" 2> "$CASE_DIR/error-$number" || status=$?
    printf '%s' "$status" > "$CASE_DIR/status-$number"
  ) &
  RUNNER_PIDS="$RUNNER_PIDS $!"
done
wait_for_file "$FAKE_CURL_STARTED" || true
sleep 0.05
CURL_CALLS=0
[ ! -f "$FAKE_CURL_LOG" ] || CURL_CALLS="$(grep -c '^call$' "$FAKE_CURL_LOG")"
if [ "$CURL_CALLS" -eq 1 ]; then
  pass "concurrent stale renders start exactly one request"
else
  fail "concurrent stale renders start exactly one request"
fi
: > "$FAKE_CURL_RELEASE"
for runner_pid in $RUNNER_PIDS; do
  wait "$runner_pid"
done
wait_for_usage "$RUNTIME_DIR/statusline-usage-cache.json" 36 || true

# Native-lock refresh removes only old regular legacy header files.
new_case legacy-auth-cleanup
write_usage "$RUNTIME_DIR/statusline-usage-cache.json" 16 32
touch -t 202001010000 "$RUNTIME_DIR/statusline-usage-cache.json"
write_usage "$FAKE_CURL_RESPONSE_FILE" 64 72
ORPHAN_AUTH="$RUNTIME_DIR/.statusline-auth.orphan"
FRESH_AUTH="$RUNTIME_DIR/.statusline-auth.fresh"
SYMLINK_TARGET="$RUNTIME_DIR/auth-target"
SYMLINK_AUTH="$RUNTIME_DIR/.statusline-auth.symlink"
printf 'old header\n' > "$ORPHAN_AUTH"
printf 'fresh header\n' > "$FRESH_AUTH"
printf 'symlink target\n' > "$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$SYMLINK_AUTH"
touch -t 202001010000 "$ORPHAN_AUTH"
TEST_OAUTH_TOKEN="statusline-token-$RANDOM-$$"
run_statusline "$(base_input)"
wait_for_file "$FAKE_CURL_FINISHED" || true
if [ ! -e "$ORPHAN_AUTH" ]; then
  pass "native-lock cleanup removes an aged regular legacy header"
else
  fail "native-lock cleanup removes an aged regular legacy header"
fi
if [ -f "$FRESH_AUTH" ] && [ "$(cat "$FRESH_AUTH")" = "fresh header" ]; then
  pass "native-lock cleanup preserves a fresh legacy header"
else
  fail "native-lock cleanup preserves a fresh legacy header"
fi
if [ -L "$SYMLINK_AUTH" ] && [ "$(cat "$SYMLINK_TARGET")" = "symlink target" ]; then
  pass "native-lock cleanup never touches a legacy header symlink"
else
  fail "native-lock cleanup never touches a legacy header symlink"
fi

# Without lockf or flock, refresh is skipped while the helper remains successful.
new_case no-native-lock
write_usage "$RUNTIME_DIR/statusline-usage-cache.json" 17 34
touch -t 202001010000 "$RUNTIME_DIR/statusline-usage-cache.json"
write_usage "$FAKE_CURL_RESPONSE_FILE" 68 76
TEST_OAUTH_TOKEN="statusline-token-$RANDOM-$$"
NO_NATIVE_FALLBACK_DIR="$RUNTIME_DIR/statusline-usage.lockfile.d"
NO_NATIVE_FALLBACK_MARKER="$CASE_DIR/native-lock-fallback"
STATUS=0
NO_NATIVE_OUTPUT="$(env -i HOME="$HOME_DIR" PATH="$FAKE_BIN:$ORIGINAL_PATH" REAL_JQ="$REAL_JQ" \
  CLAUDE_STATUSLINE_RUNTIME_DIR="$RUNTIME_DIR" CLAUDE_CODE_OAUTH_TOKEN="$TEST_OAUTH_TOKEN" \
  FAKE_CURL_LOG="$FAKE_CURL_LOG" FAKE_CURL_EXPECT_TOKEN="$TEST_OAUTH_TOKEN" \
  FAKE_CURL_RESPONSE_FILE="$FAKE_CURL_RESPONSE_FILE" FAKE_CURL_FINISHED="$FAKE_CURL_FINISHED" \
  NO_NATIVE_FALLBACK_DIR="$NO_NATIVE_FALLBACK_DIR" NO_NATIVE_FALLBACK_MARKER="$NO_NATIVE_FALLBACK_MARKER" \
  bash --noprofile --norc -c '
    command() {
      if [ "${1:-}" = "-v" ] && { [ "${2:-}" = "lockf" ] || [ "${2:-}" = "flock" ]; }; then
        return 1
      fi
      builtin command "$@"
    }
    mkdir() {
      if [ "${1:-}" = "$NO_NATIVE_FALLBACK_DIR" ]; then
        : > "$NO_NATIVE_FALLBACK_MARKER"
        return 1
      fi
      command mkdir "$@"
    }
    . "$1" || exit 10
    claude_statusline_refresh_usage_async
    sleep 0.1
  ' bash "$HELPER_SOURCE" 2>&1)" || STATUS=$?
assert_status 0 "no native lock keeps the cache helper successful"
assert_empty "$NO_NATIVE_OUTPUT" "no native lock refresh stays silent"
if [ ! -e "$NO_NATIVE_FALLBACK_MARKER" ]; then
  pass "no native lock never attempts a directory-lock fallback"
else
  fail "no native lock never attempts a directory-lock fallback"
fi
if [ ! -e "$FAKE_CURL_LOG" ]; then
  pass "no native lock performs no detached refresh"
else
  fail "no native lock performs no detached refresh"
fi

# Invalid responses and transport failures preserve the old cache.
new_case invalid-response
write_usage "$RUNTIME_DIR/statusline-usage-cache.json" 13 26
touch -t 202001010000 "$RUNTIME_DIR/statusline-usage-cache.json"
printf '%s\n' '{"error":"invalid"}' > "$FAKE_CURL_RESPONSE_FILE"
OLD_CACHE="$(cat "$RUNTIME_DIR/statusline-usage-cache.json")"
TEST_OAUTH_TOKEN="statusline-token-$RANDOM-$$"
FAKE_CURL_BLOCK=0
run_statusline "$(base_input)"
wait_for_file "$FAKE_CURL_FINISHED" || true
assert_equal "$(cat "$RUNTIME_DIR/statusline-usage-cache.json")" "$OLD_CACHE" "invalid API response preserves the old cache"
assert_contains "$OUTPUT" "13%" "invalid API response still renders last-known-good usage"

new_case transport-failure
write_usage "$RUNTIME_DIR/statusline-usage-cache.json" 14 28
touch -t 202001010000 "$RUNTIME_DIR/statusline-usage-cache.json"
OLD_CACHE="$(cat "$RUNTIME_DIR/statusline-usage-cache.json")"
TEST_OAUTH_TOKEN="statusline-token-$RANDOM-$$"
FAKE_CURL_FAIL=1
run_statusline "$(base_input)"
wait_for_file "$FAKE_CURL_FINISHED" || true
assert_equal "$(cat "$RUNTIME_DIR/statusline-usage-cache.json")" "$OLD_CACHE" "usage transport failure preserves the old cache"

# Missing credentials and an unusable runtime are both fail-open render paths.
new_case missing-token
write_usage "$RUNTIME_DIR/statusline-usage-cache.json" 15 30
touch -t 202001010000 "$RUNTIME_DIR/statusline-usage-cache.json"
TEST_OAUTH_TOKEN=""
FAKE_CURL_FAIL=0
run_statusline "$(base_input)"
assert_status 0 "missing token keeps the statusline successful"
assert_contains "$OUTPUT" "15%" "missing token keeps last-known-good usage visible"
if [ ! -e "$FAKE_CURL_LOG" ]; then
  pass "missing token performs no usage request"
else
  fail "missing token performs no usage request"
fi

new_case unusable-runtime
printf 'not a directory\n' > "$RUNTIME_DIR"
TEST_OAUTH_TOKEN=""
run_statusline "$(base_input)"
assert_status 0 "cache failure keeps the statusline successful"
assert_equal "$OUTPUT" "$EXPECTED_CLEAN" "cache failure preserves the primary visual output"
assert_empty "$STDERR_OUTPUT" "cache failure is silent"

# A higher native reading (epoch resets_at) beats the cache's reading.
new_case native-rate-limits
write_usage "$RUNTIME_DIR/statusline-usage-cache.json" 11 22
NOW="$(date +%s)"
NATIVE_INPUT="$(base_input | "$REAL_JQ" -c \
  --argjson five "$((NOW + 2 * 86400 + 3600 + 30))" --argjson seven "$((NOW + 5 * 86400 + 7200 + 30))" \
  '.rate_limits = {five_hour: {used_percentage: 55.4, resets_at: $five}, seven_day: {used_percentage: 66.6, resets_at: $seven}}')"
run_statusline "$NATIVE_INPUT"
PLAIN="$(strip_ansi "$OUTPUT")"
assert_contains "$PLAIN" "current ══════ 55% ⟳ in 2d 1h" "native five-hour window overrides the cache"
assert_contains "$PLAIN" "weekly ══════ 67% ⟳ in 5d 2h" "native seven-day window overrides the cache"
assert_not_contains "$PLAIN" "11%" "cached five-hour usage yields to stdin"

# Without a cache, stdin alone renders whichever windows it carries.
new_case native-rate-limits-only
NOW="$(date +%s)"
NATIVE_ONLY_INPUT="$(base_input | "$REAL_JQ" -c --argjson five "$((NOW + 3 * 3600 + 30))" \
  '.rate_limits = {five_hour: {used_percentage: 12, resets_at: $five}}')"
run_statusline "$NATIVE_ONLY_INPUT"
PLAIN="$(strip_ansi "$OUTPUT")"
assert_status 0 "stdin-only rate limits keep the statusline successful"
assert_contains "$PLAIN" "current ══════ 12% ⟳ in 3h" "stdin-only five-hour window renders without a cache"
assert_not_contains "$PLAIN" "weekly" "an absent seven-day window stays hidden"

# An idle session's stdin snapshot of the same window yields to a higher
# account-wide cache reading; a later window from stdin replaces an old one.
new_case stale-native-window
NOW="$(date +%s)"
FIVE_RESET="$((NOW + 2 * 3600 + 30))"
write_usage_json "$RUNTIME_DIR/statusline-usage-cache.json" \
  "{\"five_hour\":{\"utilization\":70,\"resets_at\":\"$(iso_utc "$FIVE_RESET")\"},\"seven_day\":{\"utilization\":22,\"resets_at\":null},\"extra_usage\":{\"is_enabled\":false}}"
run_statusline "$(base_input | "$REAL_JQ" -c --argjson five "$FIVE_RESET" \
  '.rate_limits = {five_hour: {used_percentage: 20, resets_at: $five}}')"
PLAIN="$(strip_ansi "$OUTPUT")"
assert_contains "$PLAIN" "current ══════ 70% ⟳ in 2h" "a fresher cache reading of the same window beats stale stdin"
assert_not_contains "$PLAIN" "20%" "stale stdin usage for the same window stays hidden"

new_case newer-native-window
NOW="$(date +%s)"
write_usage_json "$RUNTIME_DIR/statusline-usage-cache.json" \
  "{\"five_hour\":{\"utilization\":90,\"resets_at\":\"$(iso_utc "$((NOW - 600))")\"},\"seven_day\":{\"utilization\":22,\"resets_at\":null},\"extra_usage\":{\"is_enabled\":false}}"
run_statusline "$(base_input | "$REAL_JQ" -c --argjson five "$((NOW + 4 * 3600 + 30))" \
  '.rate_limits = {five_hour: {used_percentage: 5, resets_at: $five}}')"
PLAIN="$(strip_ansi "$OUTPUT")"
assert_contains "$PLAIN" "current ══════ 5% ⟳ in 4h" "a later native window replaces the cache's elapsed one"

# Windows stdin lacks, scoped weekly caps, and extra usage still come from the cache.
new_case per-window-fallback
NOW="$(date +%s)"
WEEK_RESET_ISO="$(iso_utc "$((NOW + 3 * 86400 + 7200 + 30))")"
write_usage_json "$RUNTIME_DIR/statusline-usage-cache.json" \
  "{\"five_hour\":{\"utilization\":11,\"resets_at\":null},\"seven_day\":{\"utilization\":22,\"resets_at\":\"$WEEK_RESET_ISO\"},\"limits\":[{\"kind\":\"weekly_scoped\",\"percent\":30,\"resets_at\":\"$WEEK_RESET_ISO\",\"is_active\":true,\"scope\":{\"model\":{\"display_name\":\"Fable\"}}}],\"extra_usage\":{\"is_enabled\":true,\"monthly_limit\":5000,\"used_credits\":5000,\"utilization\":100}}"
run_statusline "$(base_input | "$REAL_JQ" -c --argjson five "$((NOW + 2 * 3600 + 30))" \
  '.rate_limits = {five_hour: {used_percentage: 55, resets_at: $five}}')"
PLAIN="$(strip_ansi "$OUTPUT")"
assert_contains "$PLAIN" "current ══════ 55% ⟳ in 2h │ weekly ══════ 22% ⟳ in 3d 2h" "a window absent from stdin falls back to the cache"
assert_contains "$PLAIN" "│ Fable ══════ 30%* ⟳ in 3d 2h resets " "scoped weekly caps and the billing reset stay on line 2"
assert_contains "$(printf '%s\n' "$PLAIN" | head -n 1)" "│ ↗ \$50.00/\$50.00" "extra usage stays on line 1"

# Prompt cache: warm countdown, cold rebuild cost, misses, and hidden states.
new_case prompt-cache-warm
NOW="$(date +%s)"
WARM_INPUT="$(base_input | "$REAL_JQ" -c --argjson exp "$((NOW + 52 * 60 + 30))" \
  '.prompt_cache = {caching_observed: true, warm: true, ttl: "1h", expires_at: $exp, hit_ratio: 0.914, misses: 0, last_miss_cause: null, recache_tokens_if_cold: 45000}')"
run_statusline "$WARM_INPUT"
PLAIN="$(strip_ansi "$OUTPUT")"
assert_contains "$(printf '%s\n' "$PLAIN" | head -n 1)" "42% 6k/200k │ cache 91% ⟳ in 52m │ repo (main)" "prompt cache sits right after the context on line 1"
assert_contains "$PLAIN" "cache 91% ⟳ in 52m" "warm prompt cache shows hit ratio and time to cold"
assert_contains "$OUTPUT" "$(printf '\033[38;2;125;205;160m91%%')" "a high hit ratio takes the ok color"
assert_not_contains "$PLAIN" "✗" "prompt cache without misses shows no miss marker"

new_case prompt-cache-cold
COLD_INPUT="$(base_input | "$REAL_JQ" -c \
  '.prompt_cache = {caching_observed: true, warm: false, expires_at: null, hit_ratio: 0.42, misses: 2, last_miss_cause: {causes: ["tools_changed"], tools_added: 2, tools_removed: 0}, recache_tokens_if_cold: 45000}')"
run_statusline "$COLD_INPUT"
PLAIN="$(strip_ansi "$OUTPUT")"
assert_contains "$PLAIN" "cache 42% cold 45k to re-cache ✗2 tools" "cold prompt cache shows rebuild cost and last miss cause"
assert_contains "$OUTPUT" "$(printf '\033[38;2;240;160;110m42%%')" "a middling hit ratio takes the high color"

new_case prompt-cache-expired
NOW="$(date +%s)"
EXPIRED_INPUT="$(base_input | "$REAL_JQ" -c --argjson exp "$((NOW - 10))" \
  '.prompt_cache = {caching_observed: true, warm: true, expires_at: $exp, hit_ratio: 0.9, misses: 0, recache_tokens_if_cold: 1200}')"
run_statusline "$EXPIRED_INPUT"
PLAIN="$(strip_ansi "$OUTPUT")"
assert_contains "$PLAIN" "cache 90% cold 1k to re-cache" "a warm snapshot past expires_at renders as cold"

new_case prompt-cache-unobserved
run_statusline "$(base_input | "$REAL_JQ" -c '.prompt_cache = {caching_observed: false, warm: false, hit_ratio: null, misses: 0}')"
assert_equal "$OUTPUT" "$EXPECTED_CLEAN" "prompt cache stays hidden until caching is observed"

new_case malformed-native-fields
run_statusline "$(base_input | "$REAL_JQ" -c '.prompt_cache = "bogus" | .rate_limits = {five_hour: "bogus", seven_day: {used_percentage: "high"}}')"
assert_status 0 "malformed native fields keep the statusline successful"
assert_equal "$OUTPUT" "$EXPECTED_CLEAN" "malformed native fields leave the primary output intact"
assert_empty "$STDERR_OUTPUT" "malformed native fields are silent"

# Ultracode is independent of effort since Claude Code 2.1.284, so the word
# follows the effort label instead of replacing it.
new_case ultracode-with-effort
printf '{"ultracode": true}\n' > "$HOME_DIR/.claude/settings.json"
run_statusline "$(base_input)"
assert_contains "$(strip_ansi "$OUTPUT" | head -n 1)" "Claude Opus high ultracode │ 42% 6k/200k" \
  "ultracode follows the effort label"

new_case ultracode-off
printf '{"ultracode": false}\n' > "$HOME_DIR/.claude/settings.json"
run_statusline "$(base_input)"
assert_not_contains "$(strip_ansi "$OUTPUT")" "ultracode" "no ultracode word when it is off"

# COLUMNS wraps segments onto extra rows, and below 100 columns it shortens
# bars and selects the compact form. Without COLUMNS every line stays one row
# in the full form (see the snapshots above). A window without a reset time
# shows no reset marker.
new_case narrow-columns
write_usage "$RUNTIME_DIR/statusline-usage-cache.json" 11 22
TEST_COLUMNS=60
run_statusline "$WARM_INPUT"
PLAIN="$(strip_ansi "$OUTPUT")"
EXPECTED_NARROW="$(printf '%s\n' \
  "Claude Opus high │ 42% 6k/200k │ cache 91% ⟳52m" \
  "repo (main)" \
  "" \
  "5h ═════ 11% │ 7d ═════ 22%")"
assert_equal "$PLAIN" "$EXPECTED_NARROW" "narrow terminal shortens bars and wraps only the segment that overflows"

# At 29 columns (25 usable) the two 12-cell usage segments fit only without
# their 3-cell separator, and line 1 wraps too.
new_case tight-columns
write_usage "$RUNTIME_DIR/statusline-usage-cache.json" 11 22
TEST_COLUMNS=29
run_statusline "$WARM_INPUT"
EXPECTED_TIGHT="$(printf '%s\n' \
  "Claude Opus high" \
  "42% 6k/200k" \
  "cache 91% ⟳52m" \
  "repo (main)" \
  "" \
  "5h ═════ 11%" \
  "7d ═════ 22%")"
assert_equal "$(strip_ansi "$OUTPUT")" "$EXPECTED_TIGHT" "separator width decides the wrap point"

# Below 100 columns every segment takes its compact form, so a split pane of
# about 80 columns keeps each line on one row.
NOW="$(date +%s)"
COMPACT_USAGE="{\"five_hour\":{\"utilization\":95,\"resets_at\":\"$(iso_utc "$((NOW + 98 * 60 + 30))")\"},\"seven_day\":{\"utilization\":76,\"resets_at\":\"$(iso_utc "$((NOW + 43 * 3600 + 30))")\"},\"limits\":[{\"kind\":\"weekly_scoped\",\"percent\":16,\"resets_at\":\"$(iso_utc "$((NOW + 43 * 3600 + 30))")\",\"is_active\":false,\"scope\":{\"model\":{\"display_name\":\"Fable\"}}}],\"extra_usage\":{\"is_enabled\":true,\"monthly_limit\":null,\"used_credits\":8725,\"utilization\":null}}"
compact_input() {
  base_input | "$REAL_JQ" -c --arg cwd "$1" '.model.display_name = "Opus 5.5" | .effort.level = "medium"
    | .cwd = $cwd | .context_window = {context_window_size: 1000000, used_percentage: 5.4, current_usage: {input_tokens: 4000, cache_creation_input_tokens: 0, cache_read_input_tokens: 50000}}'
}

new_case compact-split-pane
write_usage_json "$RUNTIME_DIR/statusline-usage-cache.json" "$COMPACT_USAGE"
TEST_COLUMNS=81
run_statusline "$(compact_input /workspace/harness | "$REAL_JQ" -c --argjson exp "$((NOW + 59 * 60 + 30))" \
  '.prompt_cache = {caching_observed: true, warm: true, expires_at: $exp, hit_ratio: 0.64, misses: 0, recache_tokens_if_cold: 0}')"
EXPECTED_COMPACT="$(printf '%s\n' \
  "Opus 5.5 medium │ 5% 54k/1.0m │ cache 64% ⟳59m │ harness (main) │ ↗ \$87.25" \
  "" \
  "5h ═════ 95% ⟳1h38m │ 7d ═════ 76% ⟳1d19h │ Fable ═════ 16% ⟳1d19h")"
assert_equal "$(strip_ansi "$OUTPUT")" "$EXPECTED_COMPACT" "a split pane renders each line on one row in compact form"

# The extra usage segment counts toward the dir cap decision.
new_case compact-long-branch
write_usage_json "$RUNTIME_DIR/statusline-usage-cache.json" "$COMPACT_USAGE"
FAKE_GIT_BRANCH=ci/cleanup-stale-ci-data
TEST_COLUMNS=81
run_statusline "$(compact_input /workspace/api-bruno)"
assert_equal "$(strip_ansi "$OUTPUT" | head -n 1)" "Opus 5.5 medium │ 5% 54k/1.0m │ api-bruno (ci/cleanu…e-ci-data) │ ↗ \$87.25" \
  "tighter caps keep extra usage on line 1"

new_case compact-cold-cache
TEST_COLUMNS=99
run_statusline "$COLD_INPUT"
assert_contains "$(strip_ansi "$OUTPUT")" "│ cache 42% cold 45k ✗2 tools │" "a compact cold cache drops the re-cache words"

new_case full-at-100-columns
write_usage_json "$RUNTIME_DIR/statusline-usage-cache.json" "$COMPACT_USAGE"
TEST_COLUMNS=100
run_statusline "$(compact_input /workspace/harness)"
assert_contains "$(strip_ansi "$OUTPUT")" "current ══════ 95% ⟳ in 1h 38m" "100 columns keep the full form"
assert_contains "$(strip_ansi "$OUTPUT")" "↗ \$87.25 used · unlimited" "100 columns keep the full extra usage text"

# Shorter dir/branch caps apply only where they keep the dir segment on the
# model/context/cache row, or where the full-cap segment overflows a row of its own.
LONG_BRANCH="feature/very-long-branch-name-for-testing-caps"
new_case line1-full-caps
FAKE_GIT_BRANCH="$LONG_BRANCH"
TEST_COLUMNS=104
run_statusline "$(base_input)"
assert_equal "$(strip_ansi "$OUTPUT")" "Claude Opus high │ 42% 6k/200k │ repo (feature/very-…-testing-caps)" \
  "a line 1 that fits keeps the full-width caps"

new_case line1-refit-fits
FAKE_GIT_BRANCH="$LONG_BRANCH"
TEST_COLUMNS=70
run_statusline "$(base_input)"
assert_equal "$(strip_ansi "$OUTPUT")" "Claude Opus high │ 42% 6k/200k │ repo (feature/v…ting-caps)" \
  "tighter caps keep line 1 on one row when that makes it fit"

# The prompt cache segment shares line 1, so it counts toward the cap decision:
# at 82 columns (78 usable) only the tighter caps fit beside it.
new_case line1-refit-with-cache
FAKE_GIT_BRANCH="$LONG_BRANCH"
TEST_COLUMNS=82
run_statusline "$(base_input | "$REAL_JQ" -c '.prompt_cache = {caching_observed: true, warm: false, expires_at: null, hit_ratio: 0.42, misses: 0, recache_tokens_if_cold: 0}')"
assert_equal "$(strip_ansi "$OUTPUT")" "Claude Opus high │ 42% 6k/200k │ cache 42% cold │ repo (feature/v…ting-caps)" \
  "the cache segment counts toward the line 1 cap decision"

new_case line1-wrap-keeps-caps
FAKE_GIT_BRANCH="$LONG_BRANCH"
TEST_COLUMNS=50
run_statusline "$(base_input)"
assert_equal "$(strip_ansi "$OUTPUT")" "$(printf '%s\n' "Claude Opus high │ 42% 6k/200k" "repo (feature/very-…-testing-caps)")" \
  "a dir segment that wraps anyway keeps its full caps"

new_case line1-dir-too-wide
FAKE_GIT_BRANCH="$LONG_BRANCH"
TEST_COLUMNS=36
run_statusline "$(base_input)"
assert_equal "$(strip_ansi "$OUTPUT")" "$(printf '%s\n' "Claude Opus high │ 42% 6k/200k" "repo (feature/v…ting-caps)")" \
  "a full-cap dir segment wider than a whole row takes the tighter caps"

# Fullwidth punctuation is two cells: 报告（终稿） is 12 cells, so line 1 is 45
# cells and fits 49 columns (45 usable) but wraps at 48.
new_case fullwidth-dir-fits
FAKE_GIT_MODE=none
TEST_COLUMNS=49
run_statusline "$(base_input | "$REAL_JQ" -c '.cwd="/workspace/报告（终稿）"')"
assert_equal "$(strip_ansi "$OUTPUT")" "Claude Opus high │ 42% 6k/200k │ 报告（终稿）" "a fullwidth dir name that fits stays on line 1"

new_case fullwidth-dir-wraps
FAKE_GIT_MODE=none
TEST_COLUMNS=48
run_statusline "$(base_input | "$REAL_JQ" -c '.cwd="/workspace/报告（终稿）"')"
assert_equal "$(strip_ansi "$OUTPUT")" "$(printf '%s\n' "Claude Opus high │ 42% 6k/200k" "报告（终稿）")" \
  "a fullwidth dir name one cell too wide wraps"

# Truncation counts cells and cuts between whole characters in any locale.
new_case cjk-branch-truncation
FAKE_GIT_BRANCH="功能/超长的中文分支名称用于测试截断效果"
run_statusline "$(base_input)"
assert_equal "$(strip_ansi "$OUTPUT")" "Claude Opus high │ 42% 6k/200k │ repo (功能/超长的中…测试截断效果)" \
  "a CJK branch is capped at 28 cells on character boundaries"

# Every render is complete: switching the locale per call inside $(...) made
# bash 5.3 drop the dir segment in roughly one of twenty fresh processes.
new_case repeated-renders
FAKE_GIT_MODE=none
TEST_COLUMNS=49
CJK_INPUT="$(base_input | "$REAL_JQ" -c '.cwd="/workspace/报告（终稿）"')"
BAD_RENDERS=0
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  run_statusline "$CJK_INPUT"
  [ "$(strip_ansi "$OUTPUT")" = "Claude Opus high │ 42% 6k/200k │ 报告（终稿）" ] || BAD_RENDERS=$((BAD_RENDERS + 1))
done
assert_equal "$BAD_RENDERS" "0" "thirty fresh renders of a CJK line are all complete"

# The double-width 🌳 counts as two cells: line 1 is 49 cells against 48
# usable, so it wraps; counting 🌳 as one cell would keep it on one row.
new_case worktree-wide-glyph
FAKE_GIT_BRANCH=gaotity/topic
TEST_COLUMNS=52
run_statusline "$(base_input | "$REAL_JQ" -c '.cwd="/workspace/topic" | .workspace.git_worktree="topic"')"
assert_equal "$(strip_ansi "$OUTPUT")" "$(printf '%s\n' "Claude Opus high │ 42% 6k/200k" "project 🌳 topic")" \
  "a worktree segment one cell too wide for the row wraps"

new_case wide-columns
write_usage "$RUNTIME_DIR/statusline-usage-cache.json" 11 22
TEST_COLUMNS=200
run_statusline "$WARM_INPUT"
PLAIN="$(strip_ansi "$OUTPUT")"
assert_contains "$PLAIN" "current ══════ 11%" "wide terminal keeps full-width usage bars"
assert_equal "$(printf '%s\n' "$PLAIN" | wc -l | tr -d ' ')" "3" "wide terminal keeps line 2 on one row"
assert_contains "$PLAIN" "│ cache 91%" "wide terminal joins the cache segment with a separator"

# Subagent rows gain the model family and a non-inherited effort badge.
new_case subagent-rows
SUBAGENT_INPUT='{"columns":100,"tasks":[
  {"id":"a1","name":"reviewer","description":"Review the auth diff","tokenCount":34000,"contextWindowSize":200000,"model":"claude-opus-5-5","effort":"high"},
  {"id":"a2","name":"scout","description":"Find callers","tokenCount":1200,"contextWindowSize":200000},
  {"id":"a3","name":"budgeted","description":"Summarize logs","tokenCount":500,"model":"us.anthropic.claude-sonnet-5-v1:0","effort":8000}]}'
STATUS=0
SUBAGENT_OUTPUT="$(printf '%s' "$SUBAGENT_INPUT" | env -i PATH="$ORIGINAL_PATH" \
  bash --noprofile --norc "$SUBAGENT_SOURCE" 2>"$STDERR_FILE")" || STATUS=$?
assert_status 0 "subagent statusline exits successfully"
assert_empty "$(cat "$STDERR_FILE")" "subagent statusline has no stderr"
subagent_row() {
  strip_ansi "$(printf '%s\n' "$SUBAGENT_OUTPUT" | "$REAL_JQ" -r --arg id "$1" 'select(.id == $id) | .content')"
}
assert_equal "$(printf '%s\n' "$SUBAGENT_OUTPUT" | "$REAL_JQ" -r '.id' | tr '\n' ' ')" "a1 a2 a3 " "subagent statusline emits one row per task"
assert_equal "$(subagent_row a1)" "reviewer  Review the auth diff  opus ◕ high  34k 17%" "subagent row shows model family and effort level"
assert_equal "$(subagent_row a2)" "scout  Find callers  1k 0%" "subagent row without model or effort keeps the old layout"
assert_equal "$(subagent_row a3)" "budgeted  Summarize logs  sonnet ◑ 8k  500" "subagent row shortens provider IDs and humanizes a token budget"

# Narrow panels shed the badge, then the family, before the description floor.
narrow_subagent_row() {
  printf '{"columns":%s,"tasks":[{"id":"n","name":"implementation-worker","description":"Refactor the statusline layout engine","tokenCount":5000,"contextWindowSize":200000,"model":"claude-sonnet-5","effort":"xhigh"}]}' "$1" \
    | env -i PATH="$ORIGINAL_PATH" bash --noprofile --norc "$SUBAGENT_SOURCE" 2>/dev/null \
    | "$REAL_JQ" -r '.content' | sed $'s/\033\\[[0-9;]*m//g'
}
assert_equal "$(narrow_subagent_row 70)" "implementation-worker  Refactor…  sonnet ● xhigh  5k 2%" "a roomy row keeps model and effort"
assert_equal "$(narrow_subagent_row 64)" "implementation-worker  Refactor t…  sonnet  5k 2%" "a tighter row drops the effort badge first"
assert_equal "$(narrow_subagent_row 40)" "implementation-worker  Refacto…  5k 2%" "the narrowest row drops model and effort"

CJK_SUBAGENT_OUTPUT="$(printf '%s' '{"columns":50,"tasks":[{"id":"c","name":"审查员","description":"重构状态栏布局引擎并补充测试用例","tokenCount":1200,"contextWindowSize":200000,"model":"claude-opus-5-5","effort":"high"}]}' \
  | env -i PATH="$ORIGINAL_PATH" bash --noprofile --norc "$SUBAGENT_SOURCE" 2>/dev/null | "$REAL_JQ" -r '.content')"
assert_equal "$(strip_ansi "$CJK_SUBAGENT_OUTPUT")" "审查员  重构状态栏布…  opus  1k 0%" \
  "CJK names and descriptions are budgeted in cells and cut between whole characters"

# Both scripts carry the same cell-width helpers.
function_body() {
  awk -v name="$1" '$0 == name "() {" { p = 1 } p { print } p && $0 == "}" { exit }' "$2"
}
for helper in cell_width split_chars; do
  HELPER_BODY="$(function_body "$helper" "$STATUSLINE_SOURCE")"
  if [ -n "$HELPER_BODY" ] && [ "$HELPER_BODY" = "$(function_body "$helper" "$SUBAGENT_SOURCE")" ]; then
    pass "$helper is identical in both status line scripts"
  else
    fail "$helper is identical in both status line scripts"
  fi
done

# No captured output or fake-command log may expose the runtime token.
if grep -R -F 'statusline-token-' "$TEMP_ROOT" >/dev/null 2>&1; then
  fail "statusline token never appears in smoke output or logs"
else
  pass "statusline token never appears in smoke output or logs"
fi

if [ "$FAILED" -eq 0 ]; then
  printf 'Claude statusline smoke passed.\n'
  exit 0
fi

printf '%s Claude statusline assertion(s) failed.\n' "$FAILED"
exit 1
