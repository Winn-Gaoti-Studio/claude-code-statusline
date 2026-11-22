#!/usr/bin/env bash
# The subagent-rows mod must give the same rows as subagent-statusline.sh.
# The test sends each payload to both renderers and compares the rows byte
# for byte. The node on PATH must import TypeScript with
# --experimental-strip-types (Node 22.7 or later).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

# The probe imports the mod as the render helper does, so an unsatisfactory
# Node version stops here with a clear message.
if ! (cd "$ROOT/tests" && node --no-warnings --experimental-strip-types \
  --input-type=module -e "await import('../mod/hooks/register.ts')") 2>/dev/null; then
  printf 'subagent-mod parity: node cannot import mod/hooks/register.ts (Node 22.7 or later is necessary)\n' >&2
  exit 1
fi

failures=0
check_payload() {
  local name=$1 payload=$2
  printf '%s' "$payload" | env -i PATH="$PATH" bash --noprofile --norc "$ROOT/subagent-statusline.sh" \
    | jq -c . >"$TEMP_ROOT/script.jsonl"
  printf '%s' "$payload" | node --no-warnings --experimental-strip-types "$ROOT/tests/subagent-mod-render.mjs" \
    | jq -c . >"$TEMP_ROOT/mod.jsonl"
  if ! [ -s "$TEMP_ROOT/script.jsonl" ]; then
    printf 'FAIL %s: the script gave no rows\n' "$name" >&2
    failures=$((failures + 1))
  elif ! cmp -s "$TEMP_ROOT/script.jsonl" "$TEMP_ROOT/mod.jsonl"; then
    printf 'FAIL %s: the mod rows differ from the script rows\n' "$name" >&2
    diff "$TEMP_ROOT/script.jsonl" "$TEMP_ROOT/mod.jsonl" >&2 || true
    failures=$((failures + 1))
  fi
}

check_payload model-and-effort '{"columns":100,"tasks":[
  {"id":"a1","name":"reviewer","description":"Review the auth diff","tokenCount":34000,"contextWindowSize":200000,"model":"claude-opus-5-5","effort":"high"},
  {"id":"a2","name":"scout","description":"Find callers","tokenCount":1200,"contextWindowSize":200000},
  {"id":"a3","name":"budgeted","description":"Summarize logs","tokenCount":500,"model":"us.anthropic.claude-sonnet-5-v1:0","effort":8000}]}'

for columns in 30 40 52 64 70 80 120 200; do
  check_payload "narrow-$columns" "{\"columns\":$columns,\"tasks\":[
    {\"id\":\"n\",\"name\":\"implementation-worker-with-a-long-name\",\"description\":\"Refactor the statusline layout engine and add tests\",\"tokenCount\":5000,\"contextWindowSize\":200000,\"model\":\"claude-sonnet-5[1m]\",\"effort\":\"xhigh\"},
    {\"id\":\"c\",\"name\":\"审查员\",\"description\":\"重构状态栏布局引擎并补充测试用例\",\"tokenCount\":1200,\"contextWindowSize\":200000,\"model\":\"claude-opus-5-5\",\"effort\":\"high\"},
    {\"id\":\"w\",\"name\":\"ｗｉｄｅ\",\"description\":\"emoji 🌳 and ⚡ and ﹏ and ￥ and ⺀ text\",\"tokenCount\":99,\"contextWindowSize\":1000}]}"
done

check_payload token-rounding '{"columns":100,"tasks":[
  {"id":"t1","name":"a","description":"half even","tokenCount":2500,"contextWindowSize":200000},
  {"id":"t2","name":"b","description":"half even","tokenCount":3500,"contextWindowSize":200000},
  {"id":"t3","name":"c","description":"above half","tokenCount":2501,"contextWindowSize":200000},
  {"id":"t4","name":"d","description":"millions tie","tokenCount":1250000,"contextWindowSize":2000000},
  {"id":"t5","name":"e","description":"millions inexact","tokenCount":1150000,"contextWindowSize":2000000},
  {"id":"t6","name":"f","description":"millions","tokenCount":2350000,"contextWindowSize":1000000},
  {"id":"t7","name":"g","description":"zero","tokenCount":0,"contextWindowSize":200000},
  {"id":"t8","name":"h","description":"no window","tokenCount":999}]}'

check_payload percent-colors '{"columns":100,"tasks":[
  {"id":"p1","name":"a","description":"half","tokenCount":100000,"contextWindowSize":200000},
  {"id":"p2","name":"b","description":"seventy","tokenCount":140000,"contextWindowSize":200000},
  {"id":"p3","name":"c","description":"ninety","tokenCount":180000,"contextWindowSize":200000},
  {"id":"p4","name":"d","description":"over","tokenCount":300000,"contextWindowSize":200000}]}'

check_payload effort-levels '{"columns":120,"tasks":[
  {"id":"e1","name":"a","description":"x","tokenCount":1,"effort":"max","model":"claude-haiku-5-5"},
  {"id":"e2","name":"b","description":"x","tokenCount":1,"effort":"medium","model":"gpt-something-very-long-name"},
  {"id":"e3","name":"c","description":"x","tokenCount":1,"effort":"low","model":"anthropic.claude-fable-5-2@20260101"},
  {"id":"e4","name":"d","description":"x","tokenCount":1,"effort":"custom"},
  {"id":"e5","name":"e","description":"x","tokenCount":1,"effort":1500000},
  {"id":"e6","name":"f","description":"x","tokenCount":1,"effort":0}]}'

check_payload missing-fields '{"tasks":[
  {"id":"m1","description":"no name"},
  {"id":"m2","name":"no description","label":"label text"},
  {"id":"m3","name":"empty description","description":""},
  {"id":"m4"},
  {"id":"m5","name":"tabs\tand\nnew lines","description":"a\tb\nc\rd"}]}'

if [ "$failures" -gt 0 ]; then
  printf 'subagent-mod parity: %s payloads differ\n' "$failures" >&2
  exit 1
fi
printf 'subagent-mod parity tests passed\n'
