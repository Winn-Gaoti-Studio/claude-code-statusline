#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

payload='{"session_id":"smoke","model":{"display_name":"Sonnet"},"context_window":{"context_window_size":200000,"used_percentage":42,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":500}},"cwd":"/tmp","workspace":{},"effort":{"level":"high"}}'
output="$(HOME="$TEMP_ROOT/home" CLAUDE_STATUSLINE_RUNTIME_DIR="$TEMP_ROOT/runtime" bash "$ROOT/statusline.sh" <<< "$payload" 2>"$TEMP_ROOT/main.err")"
test ! -s "$TEMP_ROOT/main.err"
case "$output" in *Sonnet*high*42%*) ;; *) printf 'unexpected main statusline output\n' >&2; exit 1 ;; esac

subagent_payload='{"columns":100,"tasks":[{"id":"task-1","name":"worker","description":"checking config","status":"running","tokenCount":2000,"contextWindowSize":200000}]}'
subagent_output="$(bash "$ROOT/subagent-statusline.sh" <<< "$subagent_payload" 2>"$TEMP_ROOT/subagent.err")"
test ! -s "$TEMP_ROOT/subagent.err"
printf '%s' "$subagent_output" | jq -e 'select(.id == "task-1") | .content | contains("worker")' >/dev/null

printf 'render tests passed\n'
