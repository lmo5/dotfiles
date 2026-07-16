# Codex Aliases Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add short Codex CLI aliases while preserving the existing Claude Code aliases.

**Architecture:** Define both aliases in the shared alias file already sourced by Bash and Zsh. Add no functions, dependencies, or setup-script changes.

**Tech Stack:** POSIX-compatible shell aliases, Bash, Zsh, Git.

## Global Constraints

- Keep `alias c='claude'` and `alias cyolo='claude --dangerously-skip-permissions'` unchanged.
- Define `x` as `codex`.
- Define `xyolo` as `codex --dangerously-bypass-approvals-and-sandbox`.
- Stage and commit only files belonging to this change.

---

### Task 1: Add and verify Codex aliases

**Files:**
- Modify: `shell/.shell/.aliases:274`
- Verify: `docs/superpowers/specs/2026-07-16-codex-aliases-design.md`
- Include: `docs/superpowers/plans/2026-07-16-codex-aliases.md`

**Interfaces:**
- Consumes: the shared alias file sourced by `~/.bashrc` and `~/.zshrc`.
- Produces: shell commands `x` and `xyolo`.

- [ ] **Step 1: Confirm the aliases are absent**

Run:

```bash
bash -ic 'alias x' 2>/dev/null
bash -ic 'alias xyolo' 2>/dev/null
```

Expected: both commands exit non-zero because the aliases are not defined.

- [ ] **Step 2: Add the minimal definitions**

Add beside the Claude Code aliases:

```sh
# Codex
alias x='codex'
alias xyolo='codex --dangerously-bypass-approvals-and-sandbox'
```

- [ ] **Step 3: Verify Bash and Zsh**

Run:

```bash
bash -ic 'alias x; alias xyolo'
zsh -ic 'alias x; alias xyolo'
```

Expected: both shells print definitions equivalent to:

```text
alias x='codex'
alias xyolo='codex --dangerously-bypass-approvals-and-sandbox'
```

- [ ] **Step 4: Commit only this change**

Run:

```bash
git add shell/.shell/.aliases docs/superpowers/plans/2026-07-16-codex-aliases.md
git commit -m "feat: add Codex shell aliases"
```
