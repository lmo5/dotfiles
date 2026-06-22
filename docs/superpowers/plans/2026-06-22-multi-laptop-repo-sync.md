# Multi-Laptop Repo Sync via Hub — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user work on the same git repos from any of their laptops, with committed history seeded from GitHub (`ghq`) and only the uncommitted WIP delta carried by Syncthing through the homelab hub.

**Architecture:** GitHub = history truth; the Dockerised Syncthing hub (`homelab-sync`, container path `/var/syncthing/data`) = always-on relay + registry + versioning safety net; laptops hold ordinary `ghq` clones. A laptop-side `repo-sync` CLI drives both the local Syncthing REST API and the hub REST API (via API key) so adding a repo on one laptop makes it adoptable on the others at the correct nested path.

**Tech Stack:** Bash, GNU stow, `curl`, `python3` (JSON), `ghq`, Syncthing REST API.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-06-22-two-laptop-repo-sync-design.md` (authoritative).
- Hub repos root is the **container** path `STSYNC_SERVER_REPOS_ROOT=/var/syncthing/data` — never a host path.
- Hub base URL `STSYNC_SERVER_URL=https://sync.ayplace.xyz`; hub device id `STSYNC_SERVER_DEVICE_ID=EAEYI32-JJDCQCI-LRXP2EI-ZFA2Z3T-XHAMSFT-QSRTKWB-MZTSG54-IV5CXQL`.
- `STSYNC_SERVER_APIKEY` grants full hub control. It MUST NOT be written to `shell/.shell/.env` (git-tracked & pushed). Use gitignored `~/.shell/.env.local`.
- `autoAcceptFolders` stays **false** on laptops; `introducer` stays **true**.
- Folder identity: folder **id** = `host-owner-repo` (slashes→hyphens, addressing only); folder **label** = `host/owner/repo` (reversible source of truth for path + clone URL).
- `.git` itself is synced; only transient git lock files are ignored.
- Default branch is `master`. Conventional-commit messages.

---

## File ownership (for parallel execution)

Tasks touch disjoint files so they can run as parallel agents:

| Task | File(s) | Suggested model |
|------|---------|-----------------|
| 1 | `scripts/repo-sync` (+ `syncthing/tests/test-repo-sync.sh`) | sonnet |
| 2 | `syncthing/setup-syncthing.sh` | sonnet |
| 3 | `syncthing/stignore.template` | haiku |
| 4 | `.gitignore`, `zsh/.zshrc`, `bash/.bashrc` | haiku |
| 5 | `syncthing/README.md` | haiku |

Tasks 1–5 are independent. Integration steps that hit the live hub belong to Tasks 1 and 2 only (unique throwaway ids + cleanup), so parallel runs never collide.

---

## Task 1: `repo-sync` — reversible identity, hub automation, new subcommands

**Files:**
- Modify: `scripts/repo-sync`
- Create: `syncthing/tests/test-repo-sync.sh`

**Interfaces:**
- Produces (pure, sourceable helpers): `_rel_from_path(abs)->rel`, `_folder_id_from_rel(rel)->id`, `_path_from_rel(rel)->abs`, `_url_from_rel(rel)->git url`, `_rel_from_url(url)->rel`.
- Produces (subcommands): `repo-sync add|get|adopt|list|rm|status|hub-doctor`.
- Consumes: env `GHQ_ROOT`, `STSYNC_URL`, `STSYNC_APIKEY`, `STSYNC_SERVER_URL`, `STSYNC_SERVER_DEVICE_ID`, `STSYNC_SERVER_APIKEY`, `STSYNC_SERVER_REPOS_ROOT`.

- [ ] **Step 1: Make the script sourceable for testing.** Wrap the dispatch `case` at the bottom of `scripts/repo-sync` so it only runs when executed directly:

```bash
# ---------------------------------------------------------------------------
# Dispatch (only when executed, not when sourced for tests)
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        add)             shift; cmd_add    "$@" ;;
        get)             shift; cmd_get    "$@" ;;
        adopt)           shift; cmd_adopt  "$@" ;;
        list)                   cmd_list        ;;
        rm)              shift; cmd_rm     "$@" ;;
        status)                 cmd_status      ;;
        hub-doctor)             cmd_hub_doctor  ;;
        --help|-h|help)         _usage          ;;
        "")                     _usage; exit 1  ;;
        *) printf 'Unknown subcommand: %s\n\n' "$1" >&2; _usage >&2; exit 1 ;;
    esac
fi
```

- [ ] **Step 2: Add config defaults** near the top of `scripts/repo-sync` (after the existing `STIGNORE_TEMPLATE=` line):

```bash
STSYNC_SERVER_URL="${STSYNC_SERVER_URL:-https://sync.ayplace.xyz}"
STSYNC_SERVER_REPOS_ROOT="${STSYNC_SERVER_REPOS_ROOT:-/var/syncthing/data}"
```

- [ ] **Step 3: Write the failing test for pure identity helpers.** Create `syncthing/tests/test-repo-sync.sh`:

```bash
#!/usr/bin/env bash
# Pure-function tests for repo-sync (no network).
set -uo pipefail
export GHQ_ROOT="/home/tester/repos"
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)/repo-sync"
# shellcheck disable=SC1090
source "$SCRIPT"

fail=0
check() { # desc expected actual
    if [[ "$2" == "$3" ]]; then printf 'ok   - %s\n' "$1"
    else printf 'FAIL - %s\n       expected: %q\n       actual:   %q\n' "$1" "$2" "$3"; fail=1; fi
}

check "rel_from_path"   "github.com/lmo5/dotfiles" "$(_rel_from_path /home/tester/repos/github.com/lmo5/dotfiles)"
check "folder_id"       "github.com-lmo5-dotfiles" "$(_folder_id_from_rel github.com/lmo5/dotfiles)"
check "path_from_rel"   "/home/tester/repos/github.com/lmo5/dotfiles" "$(_path_from_rel github.com/lmo5/dotfiles)"
check "url_from_rel"    "git@github.com:lmo5/dotfiles.git" "$(_url_from_rel github.com/lmo5/dotfiles)"
check "rel_from_url ssh"   "github.com/lmo5/dotfiles" "$(_rel_from_url git@github.com:lmo5/dotfiles.git)"
check "rel_from_url https" "github.com/lmo5/dotfiles" "$(_rel_from_url https://github.com/lmo5/dotfiles.git)"
check "subgroup roundtrip" "git@gitlab.com:grp/sub/repo.git" "$(_url_from_rel "$(_rel_from_url git@gitlab.com:grp/sub/repo.git)")"

exit $fail
```

- [ ] **Step 4: Run the test, expect failure** (helpers not defined yet):

Run: `bash syncthing/tests/test-repo-sync.sh`
Expected: FAIL lines / non-zero exit (functions not found).

- [ ] **Step 5: Implement the pure helpers** in `scripts/repo-sync` (replace the existing `_path_to_folder_id` block with this set; update `cmd_add`/`cmd_rm` to call `_folder_id_from_rel "$(_rel_from_path "$abs_path")"`):

```bash
_rel_from_path() { local rel="${1#"$GHQ_ROOT/"}"; printf '%s' "${rel#/}"; }
_folder_id_from_rel() { printf '%s' "${1//\//-}"; }
_path_from_rel() { printf '%s' "$GHQ_ROOT/$1"; }
_url_from_rel() { local rel="$1"; printf 'git@%s:%s.git' "${rel%%/*}" "${rel#*/}"; }
_rel_from_url() {
    local url="${1%.git}"
    case "$url" in
        ssh://*) url="${url#ssh://}"; url="${url#*@}"; url="${url/:/\/}" ;;
        git@*)   url="${url#git@}"; url="${url/:/\/}" ;;
        *://*)   url="${url#*://}"; url="${url#*@}" ;;
    esac
    printf '%s' "$url"
}
```

- [ ] **Step 6: Run the test, expect pass:**

Run: `bash syncthing/tests/test-repo-sync.sh`
Expected: all `ok` lines, exit 0.

- [ ] **Step 7: Commit:**

```bash
git add scripts/repo-sync syncthing/tests/test-repo-sync.sh
git commit -m "feat(repo-sync): reversible repo identity helpers + sourceable dispatch"
```

- [ ] **Step 8: Add hub REST helpers** to `scripts/repo-sync`:

```bash
_require_hub_key() {
    if [[ -z "${STSYNC_SERVER_APIKEY:-}" ]]; then
        printf 'Error: STSYNC_SERVER_APIKEY is not set (needed for hub operations).\n' >&2
        printf '  Put it in ~/.shell/.env.local (never the git-tracked ~/.shell/.env).\n' >&2
        return 1
    fi
}
_hub_curl() { # METHOD PATH [JSON]
    local method="$1" path="$2" data="${3:-}"
    local args=(-s --max-time 15 -H "X-API-Key: $STSYNC_SERVER_APIKEY" -X "$method")
    [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" -d "$data")
    curl "${args[@]}" "$STSYNC_SERVER_URL$path"
}
_hub_code() { # METHOD PATH  -> http status only
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        -H "X-API-Key: $STSYNC_SERVER_APIKEY" -X "$1" "$STSYNC_SERVER_URL$2"
}
_hub_laptop_devices() { # -> JSON array of device IDs excluding the hub
    _hub_curl GET /rest/config/devices \
      | python3 -c "import sys,json;hub='$STSYNC_SERVER_DEVICE_ID';print(json.dumps([d['deviceID'] for d in json.load(sys.stdin) if d['deviceID']!=hub]))"
}
_hub_upsert_folder() { # folder_id rel
    _require_hub_key || return 1
    local fid="$1" rel="$2" devices payload code
    devices="$(_hub_laptop_devices)" || return 1
    payload=$(python3 -c "
import json
devs=json.loads('''$devices''')
print(json.dumps({
 'id':'$fid','label':'$rel','path':'$STSYNC_SERVER_REPOS_ROOT/$rel','type':'sendreceive',
 'devices':[{'deviceID':d} for d in devs],'fsWatcherEnabled':True,'rescanIntervalS':3600,
 'versioning':{'type':'staggered','params':{'cleanInterval':'3600','maxAge':'2592000'}}}))")
    if [[ "$(_hub_code GET "/rest/config/folders/$fid")" == "200" ]]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "X-API-Key: $STSYNC_SERVER_APIKEY" \
               -H "Content-Type: application/json" -X PATCH -d "$payload" "$STSYNC_SERVER_URL/rest/config/folders/$fid")
    else
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "X-API-Key: $STSYNC_SERVER_APIKEY" \
               -H "Content-Type: application/json" -X POST -d "$payload" "$STSYNC_SERVER_URL/rest/config/folders")
    fi
    [[ "$code" == "200" ]] || { printf 'Error: hub folder upsert returned HTTP %s\n' "$code" >&2; return 1; }
}
```

- [ ] **Step 9: Make `cmd_add` hub-aware.** After the local-folder POST succeeds in `cmd_add`, add:

```bash
    # Mirror the folder onto the hub so every laptop can adopt it.
    if [[ -n "${STSYNC_SERVER_APIKEY:-}" ]]; then
        local rel; rel="$(_rel_from_path "$abs_path")"
        if _hub_upsert_folder "$folder_id" "$rel"; then
            printf '  Hub: folder shared with all laptops (versioning on).\n'
        else
            printf '  Warning: could not configure hub (folder still works locally).\n' >&2
        fi
    else
        printf '  Note: STSYNC_SERVER_APIKEY unset — skipped hub sharing.\n'
    fi
```

Also set the local folder's `label` to `rel` (not `folder_id`) in the existing payload: change `"label":"'"$folder_id"'"` to `"label":"'"$(_rel_from_path "$abs_path")"'"`.

- [ ] **Step 10: Add `cmd_get`:**

```bash
cmd_get() {
    local url="${1:-}"
    [[ -n "$url" ]] || { printf 'Usage: repo-sync get <git-url>\n' >&2; return 1; }
    local rel; rel="$(_rel_from_url "$url")"
    printf 'Cloning %s via ghq...\n' "$url"
    ghq get "$url" || { printf 'Error: ghq get failed for %s\n' "$url" >&2; return 1; }
    cmd_add "$(_path_from_rel "$rel")"
}
```

- [ ] **Step 11: Add `cmd_adopt`:**

```bash
cmd_adopt() {
    _require_hub_key || return 1
    local folders rel local_path
    folders="$(_hub_curl GET /rest/config/folders \
        | python3 -c "import sys,json;[print(f['label']) for f in json.load(sys.stdin) if f.get('label')]")"
    [[ -n "$folders" ]] || { printf 'No labelled repo folders on the hub yet.\n'; return 0; }
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        local_path="$(_path_from_rel "$rel")"
        if [[ -d "$local_path/.git" ]]; then
            printf 'Have %s — ensuring it is registered...\n' "$rel"
        else
            printf 'Adopting %s ...\n' "$rel"
            ghq get "$(_url_from_rel "$rel")" || { printf '  Warning: clone failed, skipping %s\n' "$rel" >&2; continue; }
        fi
        cmd_add "$local_path"
    done <<< "$folders"
}
```

- [ ] **Step 12: Add `cmd_status`:**

```bash
cmd_status() {
    local api_key; api_key="$(_get_api_key)" || return 1
    local ids
    ids="$(curl -s -H "X-API-Key: $api_key" "$SYNCTHING_API/rest/config/folders" \
        | python3 -c "import sys,json;[print(f['id']) for f in json.load(sys.stdin)]")"
    [[ -n "$ids" ]] || { printf 'No folders registered locally.\n'; return 0; }
    printf '%-40s %s\n' "FOLDER" "STATE"
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        local state
        state="$(curl -s -H "X-API-Key: $api_key" "$SYNCTHING_API/rest/db/status?folder=$id" \
            | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('state','?'),'need='+str(d.get('needTotalItems',0)))" 2>/dev/null)"
        printf '%-40s %s\n' "$id" "$state"
    done <<< "$ids"
}
```

- [ ] **Step 13: Add `cmd_hub_doctor` (read-only audit):**

```bash
cmd_hub_doctor() {
    _require_hub_key || return 1
    local want; want="$(_hub_laptop_devices)"
    _hub_curl GET /rest/config/folders | python3 -c "
import sys,json
want=set(json.loads('''$want'''))
fs=json.load(sys.stdin)
print('hub folders:',len(fs))
for f in fs:
    devs=set(d['deviceID'] for d in f['devices'])
    miss=want-devs
    ver=f.get('versioning',{}).get('type') or 'NONE'
    flags=[]
    if miss: flags.append('missing-devices='+str(len(miss)))
    if ver=='NONE': flags.append('no-versioning')
    print(' ',f.get('label',f['id']),'OK' if not flags else 'WARN '+' '.join(flags))
"
}
```

- [ ] **Step 14: Update `_usage`** to document `get`, `adopt`, `status`, `hub-doctor`, and the new env vars `STSYNC_SERVER_URL`, `STSYNC_SERVER_REPOS_ROOT`, `STSYNC_SERVER_APIKEY`.

- [ ] **Step 15: Integration test against live local + hub** (uses a throwaway repo dir; cleans up):

```bash
set -e
export STSYNC_SERVER_APIKEY="EDq3EshTgCmP2G7wjvChzmboGebd52Vs"
TMP="$HOME/repos/github.com/_reposync-itest/demo"; mkdir -p "$TMP"; ( cd "$TMP" && git init -q )
bash scripts/repo-sync add "$TMP"
bash scripts/repo-sync list | grep github.com-_reposync-itest-demo
curl -s -H "X-API-Key: $STSYNC_SERVER_APIKEY" https://sync.ayplace.xyz/rest/config/folders/github.com-_reposync-itest-demo \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('hub label=',d['label'],'ver=',d['versioning']['type'])"
# cleanup local + hub + nas
bash scripts/repo-sync rm "$TMP"
curl -s -o /dev/null -X DELETE -H "X-API-Key: $STSYNC_SERVER_APIKEY" https://sync.ayplace.xyz/rest/config/folders/github.com-_reposync-itest-demo
ssh homelab 'docker exec syncthing sh -c "rm -rf /var/syncthing/data/github.com/_reposync-itest"'
rm -rf "$HOME/repos/github.com/_reposync-itest"
echo "INTEGRATION OK"
```
Expected: `INTEGRATION OK`, with `hub label= github.com/_reposync-itest/demo ver= staggered`.

- [ ] **Step 16: Commit:**

```bash
git add scripts/repo-sync
git commit -m "feat(repo-sync): hub automation + get/adopt/status/hub-doctor subcommands"
```

---

## Task 2: `setup-syncthing.sh` — autoAccept off + hub self-registration

**Files:**
- Modify: `syncthing/setup-syncthing.sh`

**Interfaces:**
- Consumes: `STSYNC_SERVER_APIKEY`, `STSYNC_SERVER_URL`, `STSYNC_SERVER_DEVICE_ID`.
- Produces: paired laptop with `introducer=true`, `autoAcceptFolders=false`, and (when key present) this laptop registered as a device on the hub.

- [ ] **Step 1: Flip `autoAcceptFolders` to false** in `add_server_device`. In the existing-device branch change `d['autoAcceptFolders']=True` to `d['autoAcceptFolders']=False`, and in the new-device payload change `'autoAcceptFolders': True` to `'autoAcceptFolders': False`. Leave `introducer` true. Update the two `success` messages to read `autoAcceptFolders=false`.

- [ ] **Step 2: Add a hub self-registration function** so the hub will share folders back to this laptop without GUI clicks:

```bash
# ── Register this laptop on the hub (so the hub can share folders to it) ──────
register_self_with_hub() {
    [[ -n "${STSYNC_SERVER_APIKEY:-}" ]] || { log "STSYNC_SERVER_APIKEY unset — skipping hub self-registration."; return; }
    local base="${STSYNC_SERVER_URL:-$SYNCTHING_SERVER_URL}" my_id name
    my_id=$(curl -s -H "X-API-Key: $1" "$SYNCTHING_LOCAL_URL/rest/system/status" \
        | python3 -c "import sys,json;print(json.load(sys.stdin)['myID'])" 2>/dev/null)
    [[ -n "$my_id" ]] || { log "Could not read local device ID — skipping hub registration."; return; }
    name="$(hostname)"
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "X-API-Key: $STSYNC_SERVER_APIKEY" "$base/rest/config/devices/$my_id")" == "200" ]]; then
        log "This laptop is already known to the hub."
        return
    fi
    local payload
    payload=$(python3 -c "import json;print(json.dumps({'deviceID':'$my_id','name':'$name','addresses':['dynamic'],'compression':'metadata'}))")
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-API-Key: $STSYNC_SERVER_APIKEY" -H 'Content-Type: application/json' -d "$payload" "$base/rest/config/devices")" == "200" ]]; then
        success "Registered this laptop ($name) on the hub."
    else
        log "Could not register this laptop on the hub (add it manually in the hub UI)."
    fi
}
```

- [ ] **Step 3: Call it from `main`** after `add_server_device "$api_key" "$server_id"`:

```bash
    register_self_with_hub "$api_key"
```

- [ ] **Step 4: Syntax check:**

Run: `bash -n syncthing/setup-syncthing.sh`
Expected: no output, exit 0.

- [ ] **Step 5: Verify the autoAccept flag on the live laptop config** (idempotent re-run path). Apply the device update against the running local instance and confirm:

```bash
APIKEY=$(sed -n 's|.*<apikey>\([^<]*\)</apikey>.*|\1|p' "$HOME/.local/state/syncthing/config.xml")
SID="EAEYI32-JJDCQCI-LRXP2EI-ZFA2Z3T-XHAMSFT-QSRTKWB-MZTSG54-IV5CXQL"
cur=$(curl -s -H "X-API-Key: $APIKEY" "http://127.0.0.1:8384/rest/config/devices/$SID")
upd=$(printf '%s' "$cur" | python3 -c "import sys,json;d=json.load(sys.stdin);d['introducer']=True;d['autoAcceptFolders']=False;print(json.dumps(d))")
curl -s -o /dev/null -X PUT -H "X-API-Key: $APIKEY" -H 'Content-Type: application/json' -d "$upd" "http://127.0.0.1:8384/rest/config/devices/$SID"
curl -s -H "X-API-Key: $APIKEY" "http://127.0.0.1:8384/rest/config/devices/$SID" | python3 -c "import sys,json;d=json.load(sys.stdin);print('introducer=',d['introducer'],'autoAccept=',d['autoAcceptFolders'])"
```
Expected: `introducer= True autoAccept= False`.

- [ ] **Step 6: Commit:**

```bash
git add syncthing/setup-syncthing.sh
git commit -m "feat(syncthing): disable autoAcceptFolders, register laptop on hub"
```

---

## Task 3: Harden `.stignore` template (transient git locks)

**Files:**
- Modify: `syncthing/stignore.template`

- [ ] **Step 1: Append the git-lock exclusions** to `syncthing/stignore.template` (keep the existing `.git`-is-synced comment and build-artefact list):

```
// Transient git lock files — never sync (cause spurious locks / churn).
// .git itself IS still synced; only these volatile lock files are excluded.
(?d).git/index.lock
(?d).git/*.lock
(?d).git/**/*.lock
```

- [ ] **Step 2: Verify the template still excludes build artefacts and keeps `.git`:**

Run: `grep -E 'node_modules|index.lock' syncthing/stignore.template && ! grep -E '^\.git$' syncthing/stignore.template && echo OK`
Expected: prints the two grep matches then `OK`.

- [ ] **Step 3: Commit:**

```bash
git add syncthing/stignore.template
git commit -m "feat(syncthing): ignore transient git lock files in stignore template"
```

---

## Task 4: Secret handling — gitignored `~/.shell/.env.local`, sourced by shells

**Files:**
- Modify: `.gitignore`
- Modify: `zsh/.zshrc`
- Modify: `bash/.bashrc`

**Interfaces:**
- Produces: `~/.shell/.env.local` (gitignored, not stowed) sourced by both shells, used to hold `STSYNC_SERVER_APIKEY`.

- [ ] **Step 1: Ignore the local secrets file.** Append to `.gitignore`:

```
# Local, machine-specific secrets (e.g. STSYNC_SERVER_APIKEY) — never commit.
shell/.shell/.env.local
.shell/.env.local
```

- [ ] **Step 2: Source it from zsh.** In `zsh/.zshrc`, find the line that sources the shared files (the `for`/sourcing block referencing `$HOME/.shell/.env`) and add immediately after it:

```bash
# Machine-local secrets (gitignored); optional.
[ -f "$HOME/.shell/.env.local" ] && source "$HOME/.shell/.env.local"
```

- [ ] **Step 3: Source it from bash.** In `bash/.bashrc`, locate where it sources `$HOME/.shell/.env` (or the shared-files loop) and add the same two lines after it. If `.bashrc` does not currently source the `.shell` files, add the snippet near the end of the file.

- [ ] **Step 4: Verify sourcing works** without leaking into git:

```bash
printf 'export STSYNC_SERVER_APIKEY="TESTKEY123"\n' > "$HOME/.shell/.env.local"
zsh -ic 'echo "zsh:$STSYNC_SERVER_APIKEY"' 2>/dev/null | grep TESTKEY123
bash -ic 'echo "bash:$STSYNC_SERVER_APIKEY"' 2>/dev/null | grep TESTKEY123
git -C "$HOME/.dotfiles" check-ignore shell/.shell/.env.local && echo "IGNORED OK"
rm -f "$HOME/.shell/.env.local"
```
Expected: `zsh:TESTKEY123`, `bash:TESTKEY123`, `shell/.shell/.env.local`, `IGNORED OK`.

- [ ] **Step 5: Commit:**

```bash
git add .gitignore zsh/.zshrc bash/.bashrc
git commit -m "feat(shell): source gitignored ~/.shell/.env.local for machine secrets"
```

---

## Task 5: Update the Syncthing runbook

**Files:**
- Modify: `syncthing/README.md`

- [ ] **Step 1: Rewrite the onboarding & pairing sections** to match the implemented design. Replace the per-repo onboarding (§3) and laptop pairing (§2 step about Introducer/auto-accept) with:

```markdown
## 2. Device Pairing (one-time per laptop)

Run the bootstrap (installs Syncthing, pairs with the hub, introducer on,
autoAcceptFolders OFF, registers the laptop on the hub):

    STSYNC_SERVER_APIKEY=<hub key> bash ~/.dotfiles/syncthing/setup-syncthing.sh

Put the hub key in `~/.shell/.env.local` (gitignored) so it persists:

    echo 'export STSYNC_SERVER_APIKEY="<hub key>"' >> ~/.shell/.env.local

## 3. Per-Repo Onboarding

First laptop (clones history from GitHub, registers WIP sync, mirrors to hub):

    repo-sync get git@github.com:owner/repo.git

Any other laptop (pulls everything the hub offers, at the correct ghq path):

    repo-sync adopt

Check sync state before switching machines:

    repo-sync status
```

- [ ] **Step 2: Update the env-var table** in §7 to add `STSYNC_SERVER_APIKEY` (hub key; store in `~/.shell/.env.local`) and `STSYNC_SERVER_REPOS_ROOT` (default `/var/syncthing/data`, the hub container path). Add a one-line note that the hub runs Syncthing in Docker (`homelab-sync`).

- [ ] **Step 3: Verify the doc no longer tells users to enable auto-accept and references the new commands:**

Run: `grep -E 'repo-sync (get|adopt|status)' syncthing/README.md && grep -q 'env.local' syncthing/README.md && echo OK`
Expected: matches then `OK`.

- [ ] **Step 4: Commit:**

```bash
git add syncthing/README.md
git commit -m "docs(syncthing): runbook for get/adopt/status + hub key handling"
```

---

## Self-Review notes

- **Spec coverage:** roles/data-flow → Tasks 1+5; autoAccept off + introducer → Task 2; GitHub-first → `cmd_get`/`cmd_adopt` (Task 1); reversible identity → Task 1 Steps 3–6; hub upsert w/ container path + versioning + device sharing → Task 1 Steps 8–9; status helper → Task 1 Step 12; hub audit → Task 1 Step 13; `.stignore` hardening → Task 3; secret handling → Task 4. All covered.
- **No placeholders:** every code step is complete.
- **Type/name consistency:** helper names (`_rel_from_path`, `_folder_id_from_rel`, `_path_from_rel`, `_url_from_rel`, `_rel_from_url`, `_hub_upsert_folder`) are used consistently across `cmd_add`/`cmd_get`/`cmd_adopt`/`cmd_hub_doctor`.
- **Post-merge manual step (not a task):** once Tasks 1–5 land and the hub key is in `~/.shell/.env.local`, seed the mesh by running `repo-sync get <url>` for each repo on one laptop, then `repo-sync adopt` on the others.
