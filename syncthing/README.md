# Syncthing — Repo Sync Runbook

WIP transport layer: Syncthing syncs the whole repo folder (including `.git`) between
laptops and the Surface homelab server.  GitHub/GitLab remain the authoritative remote
for committed history; Syncthing carries uncommitted work-in-progress only.

## Architecture

```
GitHub / GitLab  ──(ghq clone / git push-pull)──────────────────┐
                                                                 │
  Laptop A  ◄── Syncthing (per-repo folders, incl .git) ──►  Surface server (hub + Introducer)
  Laptop B  ◄── Syncthing (introduced folders, opt-in)  ──►    │  index DB → local SSD
                                                               NAS  repos volume (capacity)
```

The server is the Syncthing hub.  Its index/config DB lives on the server's local SSD
(never on NFS — LevelDB corrupts on NFS).  The actual repo data is stored on an NFS mount
of the NAS `repos` volume.

---

## 1. Prerequisites

- Syncthing installed and running on each laptop and on the server.
- `ghq` installed; `ghq.root = ~/repos` set in `~/.gitconfig`.
- `STSYNC_SERVER_DEVICE_ID` exported (see below).

### Enable the Syncthing user service (laptop side)

Ubuntu / Debian (ships `syncthing` user service):
```bash
systemctl --user enable --now syncthing
```

openSUSE Tumbleweed (ships `syncthing@.service`):
```bash
sudo systemctl enable --now syncthing@"$USER"
```

Arch / Manjaro:
```bash
systemctl --user enable --now syncthing
```

The web UI is available at `http://127.0.0.1:8384` after the service starts.

---

## 2. Device Pairing

Pair each laptop with the server (one-time per laptop).

### On the server

1. Open the Syncthing GUI (`https://sync.homelab.local` via Caddy, or port `8384`).
2. Note the server's **Device ID** — Actions → Show ID.
3. Export it on both laptops:
   ```bash
   export STSYNC_SERVER_DEVICE_ID="XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX"
   # Add to ~/.shell/.env to make it permanent
   ```

### On each laptop

1. Open `http://127.0.0.1:8384`.
2. Add the server: **Add Remote Device** → paste the server Device ID → Save.
3. On the server, accept the pending device introduction.
4. Tick **Introducer** on the server device entry (on the laptop):
   - Go to the device entry → Edit → tick **Introducer**.
   - This lets the server introduce shared folders to other laptops automatically.

---

## 3. Per-Repo Onboarding (add a repo to sync)

```bash
# 1. Clone the repo via ghq (creates ~/repos/<host>/<owner>/<repo>)
ghq get git@github.com:lmo5/dotfiles.git

# 2. Register it with Syncthing (shares with the server, applies .stignore)
repo-sync add ~/repos/github.com/lmo5/dotfiles

# 3. Accept the folder on the server when prompted, or wait for auto-accept.
# 4. On laptop B: the folder is introduced by the server — accept it when prompted.
```

The `repo-sync add` command:
- Derives a folder ID from the ghq path (e.g. `github.com-lmo5-dotfiles`).
- Copies `stignore.template` → `<repo>/.stignore` (excludes build artefacts).
- POSTs the folder config to the local Syncthing REST API.

---

## 4. Discipline Rules (sequential use)

These rules prevent conflict storms in `.git`:

1. **One laptop at a time per repo.**  Only work on a repo from one laptop during a session.
2. **Wait for "Up to Date" before switching.**  Before picking up work on laptop B, confirm
   Syncthing shows the folder as *Up to Date* on the server.  The server is the truth — if it
   is up to date, laptop B can safely accept.
3. **No git ops during sync.**  Do not run `git commit`, `git stash`, `git rebase`, etc.,
   while the Syncthing folder is actively syncing (yellow icon).  Wait for the green *Up to
   Date* icon first.
4. **Stash before closing the laptop.**  A stash is safer than loose staged changes during
   transport.  `git stash push -u -m "wip: before sync"` before you close the lid.

---

## 5. Recovery via File Versioning

The server is configured with **Staggered File Versioning** on the repos volume.
If a sync event garbles the `.git` directory:

1. Check Syncthing's **Out of Sync** items and resolve conflicts from the GUI.
2. If `.git` is corrupted locally, restore from versioned copies on the NAS:
   ```bash
   # On the server — find the versioned backup
   ls /mnt/nas/repos/.stversions/<host>/<owner>/<repo>/.git/
   # Restore as needed
   ```
3. Last resort: re-clone from GitHub/GitLab (`ghq get <url>`) and re-register with
   `repo-sync add`.  You lose uncommitted WIP, but committed history is intact.

---

## 6. Listing and Removing Synced Repos

```bash
# Show all Syncthing folders registered on this laptop
repo-sync list

# Stop syncing a repo (local files are kept; sync registration removed)
repo-sync rm ~/repos/github.com/lmo5/old-project
```

---

## 7. Environment Variables

| Variable                 | Purpose                                      |
|--------------------------|----------------------------------------------|
| `STSYNC_SERVER_DEVICE_ID`| Hub server device ID (required)              |
| `STSYNC_APIKEY`          | API key override (default: parsed from XML)  |
| `STSYNC_URL`             | API base URL (default: `http://127.0.0.1:8384`) |
| `GHQ_ROOT`               | ghq tree root (default: `~/repos`)           |

Add `STSYNC_SERVER_DEVICE_ID` to `~/.shell/.env` to avoid setting it every session.

---

## 8. Security Notes

- No laptop ever NFS-mounts the NAS.  Laptops hold ordinary local clones.
- The server's Syncthing writes files to the NAS volume but never executes repo code.
- Malicious code at rest on the `repos` volume is inert (NAS executes nothing).
