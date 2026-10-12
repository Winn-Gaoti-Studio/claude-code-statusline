# Claude Code statusline

A portable Claude Code status-line bundle with live context usage, subscription
rate bars, worktree-aware paths, effort indicators, and custom subagent rows.

This public repository is the canonical source for the three runtime scripts.
The [shared harness](https://github.com/Gaotity/harness) pins it as a submodule
at `components/claude-code-statusline`, and chezmoi deploys the pinned scripts.
The bundle and its tests work independently of those repositories.

![demo](./.github/demo.png)

## Components

- `statusline.sh` renders the main Claude Code status line.
- `subagent-statusline.sh` renders one custom row per subagent.
- `lib/statusline-cache.sh` performs non-blocking usage refresh, credential
  lookup, and locking.

The render path reads local state. Network refresh runs asynchronously, so the
prompt is never blocked by the Anthropic usage endpoint. The former context
handoff for reminder hooks is retired; the current runtime does not write a
context-usage file.

## Requirements

- Bash
- [jq](https://jqlang.github.io/jq/)
- [curl](https://curl.se/)
- Git

On macOS, install `jq` with `brew install jq` if needed.

## Install

The installer downloads all three components, backs up an existing
`~/.claude/settings.json` when it needs to change it, and merges both
`statusLine` and `subagentStatusLine`.

```bash
curl -fsSL https://raw.githubusercontent.com/Winn-Gaoti-Studio/claude-code-statusline/main/install.sh | bash
```

Restart Claude Code after installation. To uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/Winn-Gaoti-Studio/claude-code-statusline/main/uninstall.sh | bash
```

The uninstaller restores the original settings backup when available. Without a
backup, it removes only the two status-line keys and preserves unrelated
settings. The installer records the original settings once per installation;
when no settings file existed, it records that state separately. Uninstall
removes these bundle-owned records after restoring or updating settings.

## Manual install

```bash
mkdir -p ~/.claude/lib
curl -fsSL https://raw.githubusercontent.com/Winn-Gaoti-Studio/claude-code-statusline/main/statusline.sh \
  -o ~/.claude/statusline.sh
curl -fsSL https://raw.githubusercontent.com/Winn-Gaoti-Studio/claude-code-statusline/main/subagent-statusline.sh \
  -o ~/.claude/subagent-statusline.sh
curl -fsSL https://raw.githubusercontent.com/Winn-Gaoti-Studio/claude-code-statusline/main/lib/statusline-cache.sh \
  -o ~/.claude/lib/statusline-cache.sh
chmod +x ~/.claude/statusline.sh ~/.claude/subagent-statusline.sh
```

Add these settings to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash \"$HOME/.claude/statusline.sh\"",
    "refreshInterval": 30
  },
  "subagentStatusLine": {
    "type": "command",
    "command": "bash \"$HOME/.claude/subagent-statusline.sh\""
  }
}
```

## Development

Run all checks from this repository:

```bash
bash tests/check.sh
```

The suite uses synthetic home directories and fake credential and network
commands. It needs no Claude credentials, private repository, or live network
connection. `tests/runtime.smoke.sh` carries the full runtime behavior checks;
`tests/render.smoke.sh` provides a short render check, and
`tests/install-uninstall.sh` covers the local installation path.

## Security

No OAuth token is stored in this repository. At runtime, the cache helper checks
`CLAUDE_CODE_OAUTH_TOKEN`, macOS Keychain, Claude Code's local credentials
file, or Linux Secret Service. Tokens are passed to `curl` through a header on
standard input and are never logged.

Credentials, sessions, transcripts, caches, and machine-specific configuration
are excluded.

## Credits

Inspired by
[kamranahmedse/claude-statusline](https://github.com/kamranahmedse/claude-statusline).

## License

[MIT](./LICENSE). Portions originally from `kamranahmedse/claude-statusline`
(MIT, © Kamran Ahmed).
