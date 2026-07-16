# Codex Status Line Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configure Codex's native footer to show model, context, usage-limit, project, and Git information with native colors.

**Architecture:** Use Codex's built-in `[tui].status_line` field in the global user config. No scripts, dependencies, custom renderers, or tmux integration.

**Tech Stack:** TOML, Codex CLI 0.144.5

## Global Constraints

- Modify only `/home/ayoub/.codex/config.toml`.
- Preserve every existing setting.
- Use only status-line item IDs supported by the installed Codex binary.
- Do not add a custom renderer.

---

### Task 1: Configure the native Codex footer

**Files:**
- Modify: `/home/ayoub/.codex/config.toml`
- Test: Codex strict configuration parser

**Interfaces:**
- Consumes: Codex's built-in `[tui].status_line` and `status_line_use_colors` settings.
- Produces: A native footer configured in the requested display order.

- [ ] **Step 1: Record the current parser result**

Run:

```bash
codex --strict-config --version
```

Expected: exit code `0` and `codex-cli 0.144.5`.

- [ ] **Step 2: Add the minimal configuration**

Append this table to `/home/ayoub/.codex/config.toml`:

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

- [ ] **Step 3: Validate the edited configuration**

Run:

```bash
codex --strict-config --version
```

Expected: exit code `0` and `codex-cli 0.144.5`, with no unknown-field or TOML parsing error.

- [ ] **Step 4: Inspect the exact diff**

Run:

```bash
tail -n 12 /home/ayoub/.codex/config.toml
```

Expected: the `[tui]` table contains the six requested fields in order and enables native colors.

- [ ] **Step 5: Confirm in the TUI**

Start a new Codex TUI session. Expected footer order: model/reasoning, context used, five-hour limit, weekly limit, project name, Git branch.

The live Codex config is not tracked by the dotfiles repository, so this task has no configuration commit.
