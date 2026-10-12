#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for script in "$ROOT/statusline.sh" "$ROOT/subagent-statusline.sh" \
  "$ROOT/lib/statusline-cache.sh" "$ROOT/install.sh" "$ROOT/uninstall.sh" \
  "$ROOT/tests/check.sh" "$ROOT/tests/runtime.smoke.sh" "$ROOT/tests/render.smoke.sh" \
  "$ROOT/tests/install-uninstall.sh"; do
  bash -n "$script"
done
bash "$ROOT/tests/runtime.smoke.sh"
bash "$ROOT/tests/render.smoke.sh"
bash "$ROOT/tests/install-uninstall.sh"
