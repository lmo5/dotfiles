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

## 2. Device Pairing (one-time per laptop)

Run the bootstrap (installs Syncthing, pairs with the hub, introducer on,
autoAcceptFolders OFF, registers the laptop on the hub):

    STSYNC_SERVER_APIKEY=<hub key> bash ~/.dotfiles/syncthing/setup-syncthing.sh

Put the hub key in `~/.shell/.env.local` (gitignored) so it persists:

    echo 'export STSYNC_SERVER_APIKEY="<hub key>"' >> ~/.shell/.env.local

---

## 3. Per-Repo Onboarding

First laptop (clones history from GitHub, registers WIP sync, mirrors to hub):

    repo-sync get git@github.com:owner/repo.git

Any other laptop (pulls everything the hub offers, at the correct ghq path):

    repo-sync adopt

Check sync state before switching machines:

    repo-sync status

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

| Variable                    | Purpose                                      |
|-----------------------------|----------------------------------------------|
| `STSYNC_SERVER_DEVICE_ID`   | Hub server device ID (required)              |
| `STSYNC_SERVER_APIKEY`      | Hub API key (store in `~/.shell/.env.local`) |
| `STSYNC_SERVER_REPOS_ROOT`  | Hub repos root (default: `/var/syncthing/data`, the hub container path) |
| `STSYNC_APIKEY`             | API key override (default: parsed from XML)  |
| `STSYNC_URL`                | API base URL (default: `http://127.0.0.1:8384`) |
| `GHQ_ROOT`                  | ghq tree root (default: `~/repos`)           |

Add `STSYNC_SERVER_DEVICE_ID` to `~/.shell/.env` to avoid setting it every session. The hub runs Syncthing in Docker (`homelab-sync`).

---

## 8. Security Notes

- No laptop ever NFS-mounts the NAS.  Laptops hold ordinary local clones.
- The server's Syncthing writes files to the NAS volume but never executes repo code.
- Malicious code at rest on the `repos` volume is inert (NAS executes nothing).
