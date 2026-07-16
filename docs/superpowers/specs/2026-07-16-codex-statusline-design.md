# Codex Status Line

## Goal

Configure Codex's native footer to mirror the useful parts of the existing
Claude Code status line without external scripts or tmux integration.

## Configuration

Add this table to `~/.codex/config.toml`:

```toml
[tui]
status_line = [
  "model-with-reasoning",
  "context-used",
  "five-hour-limit",
  "weekly-limit",
  "project-name",
  "git-branch",
]
status_line_use_colors = true
```

The ordered fields show model and reasoning effort, context usage, five-hour
and weekly limits, project name, and Git branch. Codex supplies the native
formatting and colors.

## Scope

Do not add a custom renderer. Codex's native status line cannot reproduce
Claude's cost, worktree name, dirty-file counts, Caveman badge, custom bars,
or two-line layout.

## Verification

Run Codex with strict configuration validation and confirm the TUI footer
shows the configured fields in order.
