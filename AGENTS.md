# Agent Guidelines

Docs and Git commits must be in English. Respond to users in Simplified Chinese.

## Repository Purpose

This public repository is the canonical source for the portable Claude Code status-line bundle:

- `statusline.sh` renders the main status line.
- `subagent-statusline.sh` renders rows in the subagent panel.
- `lib/statusline-cache.sh` owns OAuth lookup, usage refresh, and locking.

The shared harness consumes this repository as a submodule at
`components/claude-code-statusline`; chezmoi deploys the pinned bundle. Edit
runtime code and tests here first. This repository must build and test without
private repositories, a configured Claude account, or network access.

## Maintenance

```bash
bash tests/check.sh
```

The check script validates Bash syntax, the full runtime behavior suite, the
render smoke test, and installer/uninstaller behavior using synthetic home
directories. The old context handoff was removed from the canonical runtime;
do not reintroduce it to satisfy a stale test.

## Runtime Invariants

- Rendering must never block on a network request.
- The cache helper must keep tokens out of process arguments and logs.
- Date and stat behavior must remain portable across macOS and Linux.
- The installer must preserve unrelated settings and create a reversible backup.
- Repeated installation must not replace the original pre-install backup.
- The uninstaller must remove only this bundle and its two settings keys when no
  backup exists.

## Workflow

- Inspect before editing and preserve unrelated changes.
- Add tests before behavior changes and observe the expected failure.
- Run `bash tests/check.sh` before committing.
- Use Conventional Commits and signed commits only.
