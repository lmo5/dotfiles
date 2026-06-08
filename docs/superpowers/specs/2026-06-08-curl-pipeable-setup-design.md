# Curl-pipeable, rollback-safe `setup.sh` — Design

**Date:** 2026-06-08
**Status:** Approved
**Repo:** https://github.com/lmo5/dotfiles.git (branch: `master`)

## Goal

Make the dotfiles setup script runnable as a single `curl … | bash` one-liner on a
fresh machine, with timestamped backups that allow a clean rollback, and a polished,
hassle-free UX. Keep the existing multi-distro behavior intact.

The one-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/lmo5/dotfiles/master/setup.sh | bash
```

## Decisions (locked)

| Topic | Decision |
|-------|----------|
| Rollback scope | **Configs only** — timestamped backup + restore + unstow. No package uninstall. |
| Interactivity | **Interactive by default via `/dev/tty`, flags/env to override** (`--yes`, `--minimal`). |
| UX style | **Plain bash, polished** — colors, step counter, spinners, final summary. No extra deps. |
| Script layout | **Keep both scripts**; only `setup.sh` becomes pipeable. `ubuntu-setup.sh` untouched. |
| Clone location | **`~/.dotfiles`** (skip clone if already running from inside a real clone). |
| Rollback trigger | **`setup.sh --rollback`** (single entry point). |

## Architecture

The script keeps its current function-per-tool structure. New plumbing wraps it:

```
main()
  ├─ parse_args            # flags + env → globals
  ├─ bootstrap_repo        # curl|bash: ensure git, clone ~/.dotfiles, re-exec, exit
  ├─ (if --rollback) → rollback_mode; exit
  ├─ checkEnv              # fatal
  ├─ run_step ... (all install phases, non-fatal per step)
  ├─ backup_configs        # timestamped, restorable (fatal)
  ├─ setup_dotfiles        # stow from $DOTFILES_DIR (fatal)
  └─ print_summary
```

### Globals
- `DOTFILES_DIR` — resolved repo root (replaces fragile `cd "$(dirname "$0")"`).
- `DOTFILES_YES`, `DOTFILES_MINIMAL` — behavior flags (settable via env or CLI).
- `STEP`, `TOTAL` — step counter state.
- `STEPS_OK`, `STEPS_SKIPPED`, `STEPS_FAILED` — arrays for the final summary.
- `BACKUP_DIR` — `~/.dotfiles-backups/<UTC-timestamp>/` for this run.

## Components

### 1. `bootstrap_repo` (curl|bash entry)
- Determine if running from a real clone: `$0` is a readable file **and** a `.git`
  directory plus stow packages (`zsh`, `shell`) sit next to it → set `DOTFILES_DIR`
  to that dir, return (no clone).
- Otherwise (piped/stdin, or `$0` == `bash`):
  1. Ensure `git` is installed (use the same package-manager detection; this requires
     `checkEnv`'s package-manager probe to be callable early, or a minimal inline git
     install).
  2. If `~/.dotfiles` exists and is a git repo → `git -C ~/.dotfiles pull --ff-only`.
     Else → `git clone https://github.com/lmo5/dotfiles.git ~/.dotfiles`.
  3. `exec bash ~/.dotfiles/setup.sh "$@"` and stop (the re-exec'd copy runs from disk).
- `--no-clone` forces use of the current directory (dev/testing), skipping clone/re-exec.
- Honors `DOTFILES_DIR` env override as the clone/target location.

### 2. `parse_args`
Flags: `--yes`/`-y`, `--minimal`, `--rollback`, `--no-clone`, `--help`.
Env: `DOTFILES_DIR`, `DOTFILES_YES=1`, `DOTFILES_MINIMAL=1`.
Unknown flag → usage + exit 2.

### 3. `prompt_yn "question" [default]`
Replaces every raw `read -p`.
- `DOTFILES_YES` → yes.
- `DOTFILES_MINIMAL` → no (for optional/heavy tools).
- Else if `[ -r /dev/tty ]` → `read … < /dev/tty` (works under curl|bash).
- Else → the provided default (default: no) + a logged note.
Returns 0 for yes, 1 for no.

### 4. `run_step "label" function_name`
- Increments `STEP`, prints `[ N/TOTAL ] label …`.
- Runs the function in a way that captures failure **without** aborting the whole run
  (per-tool failures are non-fatal).
- On success → green ✓, append to `STEPS_OK`. On failure → red ✗ + reason, append to
  `STEPS_FAILED`. If the step decided to skip, append to `STEPS_SKIPPED`.
- `TOTAL` is the count of `run_step` phases (kept in sync with `main`).

### 5. Backup + rollback engine
`backup_configs` (rewritten):
- `BACKUP_DIR=~/.dotfiles-backups/$(date -u +%Y%m%dT%H%M%SZ)/`.
- For each managed config path (reuse existing `configs` list) that exists in `$HOME`
  as a **real file** (skip if it's already a symlink into the repo): copy (preserve
  path) into `BACKUP_DIR`.
- Write `BACKUP_DIR/manifest.txt`: timestamp, backed-up file list, and the stow package
  list that will be applied.

`rollback_mode` (`setup.sh --rollback`):
1. List `~/.dotfiles-backups/*` newest-first. TTY → user picks; `--yes` → newest.
2. For each package in that backup's manifest: `stow -D -t "$HOME"` from `DOTFILES_DIR`.
3. Restore each saved file back to its `$HOME` location.
4. Print a summary of what was unstowed and restored.

### 6. Robustness change
- Current top-level `set -eo pipefail` + `trap … ERR exit 1` aborts the entire run on
  any single failure — wrong for a long installer.
- New behavior: `set -uo pipefail` (drop `-e` for tool phases). Critical steps
  (`checkEnv`, `bootstrap_repo`, `backup_configs`, `setup_dotfiles`) remain fatal via
  explicit `error` calls. Optional tool steps are non-fatal via `run_step`.

### 7. `setup_dotfiles`
Use `$DOTFILES_DIR` instead of `$(dirname "$0")`. No other behavior change.

## What stays the same
Distro/package-manager detection, repository (apt/dnf/zypper) setup, base dependency
lists, every individual tool installer, the stow package list, and `ubuntu-setup.sh`.
These are only **wrapped** by `run_step` and fed by the new prompt/flag plumbing.

## Error handling
- Missing `git`/`curl` during bootstrap → install or fatal error with a clear message.
- No supported package manager → fatal (unchanged).
- No TTY and no flags → optional tools default to skip, base setup still completes.
- Individual tool install failure → recorded, run continues, surfaced in summary.
- Stow conflict → fatal with the offending package named (unchanged).

## Testing
- `bash -n setup.sh` (syntax) and `shellcheck setup.sh` clean (or justified disables).
- Dry simulation of bootstrap detection (real-clone vs piped) without network.
- `prompt_yn` honors `--yes`, `--minimal`, and no-TTY default paths.
- Backup creates a timestamped dir + manifest; `--rollback` unstows and restores from it.
- Idempotent: a second full run re-detects installed tools and does not error.
- Manual: `curl … | bash` on a throwaway VM/container reaches a working shell.

## Out of scope
Package uninstall on rollback; changes to `ubuntu-setup.sh`; new tools; CI.

## Implementation parallelization (preview)
Independent, smaller-model-friendly tasks (separate functions → low conflict):
- **A** bootstrap + re-exec + `parse_args` + `--help`.
- **B** `prompt_yn` TTY helper; swap the 6 `read -p` call sites.
- **C** backup + `rollback_mode` engine.
- **D** `run_step` + step counter + spinner + `print_summary`.
- **E** (integration, after A–D) wire `main`, adjust `set` flags, update `setup_dotfiles`,
  README one-liner + docs, `shellcheck`/`bash -n` pass.
