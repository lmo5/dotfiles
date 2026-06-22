# Multi-Laptop Repo Sync via Hub — Design

Date: 2026-06-22

## Goal

Work on the same set of git repos from multiple machines (currently three laptops:
ThinkPad X1 Carbon, ay-laptop, Latitude 3540), continuing seamlessly on any of them.
Edits sometimes overlap, but rarely on the same repo at the same time. Keep Syncthing
as the live transport, and add safety so an occasional same-repo clash is recoverable
rather than catastrophic.

## Validated against the live hub (2026-06-22)

Verified over SSH (`homelab` → `ay-server-1`) and the hub REST API:

- Syncthing runs in Docker (stack `homelab-sync`,
  `/srv/homelab-infrastructure/docker/sync/compose.yaml`), image
  `syncthing/syncthing:latest`, **as root** (`user: "0:0"`).
- Volume mapping: `${SYNCTHING_DATA_PATH:-/mnt/nas_repos}:/var/syncthing/data`.
  Host `/mnt/nas_repos` is an **NFS mount** of `10.13.1.3:/volume1/repos`; the
  index/config DB is a **local** named volume `syncthing_config` (never on NFS).
  → **Repos root, as seen by the hub Syncthing process, is the container path
  `/var/syncthing/data`** — NOT a host path.
- Hub REST API is reachable over the public URL **with the API key**:
  `curl -H "X-API-Key: …" https://sync.ayplace.xyz/rest/system/status` → HTTP 200.
  Full CRUD validated against the live hub: POST/PATCH/DELETE of a throwaway folder
  all returned 200, with label, staggered versioning, and multi-device sharing
  persisting correctly (the hub auto-adds itself to each folder's device list).
  → the "automate hub via API key" decision is implementable from the laptops.
- Hub device ID `EAEYI32…` (matches the laptop's server entry). Paired devices:
  `EAEYI32` = hub (`ec51fe54298e`), `QZFPWDD` = ThinkPad X1 Carbon,
  `ZWKATOA` = ay-laptop (this machine), `7R7VAR2` = Latitude 3540.
- **Hub has 0 folders** and the NFS data dir is empty (only `#recycle`). → the mesh
  is empty; this is why no repos appear on *any* laptop, not just this one.
- Hub `defaultFolderPath` is unset → do not rely on hub-side auto-accept; the hub
  folder must be created with an explicit path.

## Constraints & decisions (from brainstorming)

- **Work pattern:** overlapping edits possible, but *rarely the same repo* on both
  laptops before it syncs.
- **Transport:** keep Syncthing (per-repo folders, including `.git`).
- **History source:** clone committed history from GitHub/GitLab first (`ghq`), so
  Syncthing only reconciles the small *uncommitted WIP delta* — not the whole
  `.git`. This is the primary corruption-surface reducer.
- **autoAcceptFolders:** **disabled** on laptops. It creates folders at flat,
  wrong paths (`~/repos/github.com-owner-repo`) instead of the nested ghq path
  (`~/repos/github.com/owner/repo`). Repos enter the mesh explicitly via
  `repo-sync`, at the correct path. `introducer` stays **enabled** (device mesh).
- **Hub config:** automated via the hub's REST API using `STSYNC_SERVER_APIKEY`
  (never hardcoded; read from env, consistent with existing convention).

## Roles & data flow

```
GitHub / GitLab ──(ghq get / git push-pull)──────────────┐ committed history = truth
                                                          │
 Home laptop  ◄── Syncthing (WIP delta, incl .git) ──► Hub (Surface server)
 Work laptop  ◄── Syncthing (WIP delta, incl .git) ──►  │  index DB → local SSD
                                                        NAS repos volume + versioning
```

- **GitHub/GitLab** — source of truth for committed history.
- **Hub** — always-on Syncthing peer, the registry of which repos are in the mesh,
  and the recovery point (staggered file versioning on the repos volume).
- **Laptops** — ordinary `ghq` clones; Syncthing carries the WIP delta only.

## Components

### 1. `setup-syncthing.sh` (laptop pairing)

Changes from current behaviour:

- Set `autoAcceptFolders = false` on the server device entry (was `true`).
- Keep `introducer = true`.
- Keep the device-ID resolution already fixed (env var → `~/.shell/.env` →
  optional REST via `STSYNC_SERVER_APIKEY` → interactive prompt).
- After pairing, register *this laptop* with the hub: ensure the hub knows this
  laptop's device ID (so the hub can share folders with it without manual GUI
  steps). Uses `STSYNC_SERVER_APIKEY`.

### 2. `repo-sync` (per-repo onboarding & status)

Existing `add` / `list` / `rm` stay. New behaviour:

- **`repo-sync get <url>`** — `ghq get <url>` then `repo-sync add` on the resulting
  path. One step to clone (history from GitHub) and register (WIP via Syncthing).

- **`repo-sync add` becomes hub-aware** — in addition to creating the local folder,
  it configures the hub via `STSYNC_SERVER_APIKEY`:
  - ensure the folder exists on the hub at the **container path**
    `${STSYNC_SERVER_REPOS_ROOT}/<host>/<owner>/<repo>`
    (default `STSYNC_SERVER_REPOS_ROOT=/var/syncthing/data`; Syncthing runs as root
    in the container and creates the directory on the NFS mount),
  - set the hub folder's **label** to the reversible relative path
    `<host>/<owner>/<repo>` (see "Reversible identity" below),
  - enable **staggered file versioning** on the hub folder (per-folder recovery net),
  - share the folder with **all known laptop devices** (every device the hub knows
    except the hub itself — currently the three laptops), so any other laptop can
    adopt it.

- **`repo-sync adopt`** — on the *other* laptop: query the hub's folder list via
  `STSYNC_SERVER_APIKEY`, and for every repo folder not present locally:
  - read the hub folder's **label** to recover the exact `<host>/<owner>/<repo>`,
  - `ghq get` the derived URL (`git@<host>:<owner>/<repo>.git`) into the correct
    nested path (history from GitHub),
  - `repo-sync add` it locally so the WIP delta starts syncing.
  Intended to be run manually or from a periodic timer.

- **`repo-sync status`** — show each local folder's sync state (e.g. *Up to Date* /
  *Syncing* / *Out of Sync*) from the local REST API, so you can glance before
  starting work on the other laptop.

### 3. Hub configuration

No standalone "enable auto-accept" step is needed: `repo-sync add` creates the hub
folder **explicitly** via the API (correct container path, label, versioning,
device sharing), so the hub never has to auto-accept anything. Everything the hub
needs is applied idempotently at `add` time. An optional `repo-sync hub-doctor`
subcommand can audit the hub (folders present, all laptops shared, versioning on)
and report drift — read-only by default.

## Reversible identity (resolves a real ambiguity)

Folder IDs sanitise slashes to hyphens (`github.com-owner-repo`). That is **lossy**
when owner/repo names contain hyphens — `github.com-my-org-my-repo` could split many
ways, so a path/URL cannot be reconstructed from the folder ID alone.

Resolution: store the canonical relative path `<host>/<owner>/<repo>` (slashes
intact) in the Syncthing **folder label**. Labels are free-form per device, so
`repo-sync add` sets the label on **both** the local folder and the hub folder (via
API). `adopt` reads the hub label to reconstruct path + URL exactly. The folder ID
remains the hyphenated, Syncthing-valid form, used only for uniqueness/addressing.

## Hardening ("add safety")

- **Staggered file versioning** on the hub's repo folders — recover a mangled `.git`
  from real prior versions.
- **History from GitHub first** (the `ghq get` rule above) — Syncthing reconciles
  only the small WIP delta, so packfiles/objects already match and rarely conflict.
- **`.stignore`** keeps build-artifact excludes; additionally ignore transient git
  lock files (`*.lock`, `.git/index.lock`) to cut spurious churn. `.git` itself
  stays synced.
- **`repo-sync status`** as a soft "wait for Up to Date before switching" aid — a
  visible check, not an enforced lock.

## Configuration (env vars)

| Variable                   | Purpose                                            | Default                     |
|----------------------------|----------------------------------------------------|-----------------------------|
| `STSYNC_SERVER_DEVICE_ID`  | Hub Syncthing device ID                            | from `~/.shell/.env`        |
| `STSYNC_SERVER_APIKEY`     | Hub REST API key (hub-aware ops; never hardcoded)  | unset (required for hub ops)|
| `STSYNC_SERVER_URL`        | Hub REST/base URL                                  | `https://sync.ayplace.xyz`  |
| `STSYNC_SERVER_REPOS_ROOT` | Hub repos root (Syncthing **container** path)      | `/var/syncthing/data`       |
| `STSYNC_APIKEY`            | Local API key override                             | parsed from local config    |
| `STSYNC_URL`               | Local Syncthing API base URL                       | `http://127.0.0.1:8384`     |
| `GHQ_ROOT`                 | Local ghq tree root                                | `~/repos`                   |

**Secret handling (important):** `shell/.shell/.env` is **tracked in git and pushed
to origin**. `STSYNC_SERVER_APIKEY` grants full control of the hub, so it MUST NOT
go there. Store it in a gitignored `~/.shell/.env.local` (add the file to
`.gitignore` and source it from the shell rc alongside `.env`), or pull it from the
existing vault. The non-secret `STSYNC_SERVER_DEVICE_ID` may stay in the tracked
`.env`.

## Out of scope

- Auto-committing WIP to git (user declined; Syncthing remains the WIP transport).
- Multi-user setups (single user, multiple personal laptops). The "share with all
  known laptops" logic already covers the three currently-paired laptops + hub.
- NFS access from laptops (laptops hold ordinary local clones only).
- Changing the hub's Docker/compose definition (the existing `homelab-sync` stack is
  already correct; we only drive it via the REST API).

## Workflow summary (end state)

First laptop, per repo:
```
repo-sync get git@github.com:owner/repo.git   # clone history + register + share via hub
```
Other laptop:
```
repo-sync adopt                                # ghq-get + register everything the hub offers
```
Daily:
```
repo-sync status                               # confirm Up to Date before switching machines
```
