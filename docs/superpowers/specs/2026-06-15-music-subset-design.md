# Early Music Subset — Phase 1 Deployment Design

**Date:** 2026-06-15
**Status:** Approved (design); pending implementation plan + spec review
**Related:** `0 inbox/homelab-plan.md` (Media stack §, line ~331/339), [[hermes-deployed]], CouchDB deploy (`apps/base/couchdb/`)
**Repos:** `homelab` (Flux manifests) + `homelab-network` (DNS, restic, Proton)

## Summary

Deploy the **music subset** of the media stack on the home k3s host (hephaestus) **now**, ahead of the NAS, on interim local-path storage. Owner wants to start curating/collecting music before Phase 2. Everything is designed so the **NAS migration is later a path change only** (rsync library → NFS, repoint PVCs, no re-download).

**In scope:** Prowlarr · Lidarr · qBittorrent + gluetun(Proton) · unflac cue-split (CronJob) · Navidrome.
**Deferred:** Radarr/Sonarr/Bazarr/Jellyfin (→ NAS); Music Assistant + Symfonium multiroom (→ smart-home phase); tiddl (Tidal FLAC) manual-import path (fast-follow); custom-image build pipeline (needs Forgejo, later).

## Architecture

All workloads in a new `media` namespace.

```
                         Proton WG (dedicated config, +port-forward)
                               ▲ ONLY egress path for qB
        ┌──────────────────────┴───────────────────────┐
        │  POD: qbittorrent  (one pod, shared netns)    │
        │   ├─ gluetun     [NET_ADMIN, wg0 + killswitch]│  ← qB has NO network if the tunnel drops
        │   └─ qbittorrent [WebUI :8080]                │
        └───────────────────────────────────────────────┘
  Prowlarr ──indexers──► Lidarr ──grabs──► qBittorrent ──downloads──┐
                            │                                        │
                            └── hardlink import from /import/music   │
  unflac CronJob: scan /torrents/music-cue ──split+tag──► /import/music
  Lidarr library: /library/music ──read──► Navidrome ──► Supersonic / Symfonium
```

Only **qBittorrent** rides the Proton tunnel. Prowlarr, Lidarr, and Navidrome use normal pod egress (they need MusicBrainz / indexer APIs / clients, not Proton).

## Components

| Workload | Image (pin at build) | Purpose | Notes |
|---|---|---|---|
| qbittorrent + gluetun | `lscr.io/linuxserver/qbittorrent` + `qmcgaw/gluetun` | torrent client behind a hard VPN kill-switch | one Pod, shared netns; gluetun owns the network |
| prowlarr | `lscr.io/linuxserver/prowlarr` | indexer manager → feeds Lidarr | normal egress |
| lidarr | `lscr.io/linuxserver/lidarr` | music library mgmt, grabs + imports | normal egress; download client = qB; hardlink imports |
| unflac (CronJob) | small image w/ ffmpeg + `unflac` binary | split RuTracker image+cue → per-track FLAC | Option A (see below) |
| navidrome | `deluan/navidrome` | Subsonic server (playback) | reads `/library/music` RO; built-in DB backup |

## VPN — gluetun sidecar (kill-switch) + dedicated Proton WG

- gluetun and qBittorrent share the pod network namespace. gluetun (with `NET_ADMIN`) brings up WireGuard + its built-in firewall in that netns; qB inherits it. If gluetun stops, the firewall rules remain in the netns until pod restart → **qB stays network-dead (no leak)**.
- **Dedicated Proton WireGuard config** (NOT zeus's), on a **P2P server with port-forwarding enabled**. Provided as a syncer secret (`proton-wg`).
- gluetun env: `VPN_SERVICE_PROVIDER=protonvpn`, `VPN_TYPE=wireguard`, `WIREGUARD_PRIVATE_KEY`/`WIREGUARD_ADDRESSES` (from secret), `VPN_PORT_FORWARDING=on`, `PORT_FORWARD_ONLY=on`.
- **Firewall gotcha (must handle):** Traefik must reach qB's WebUI, and qB must reach cluster DNS. Set `FIREWALL_INPUT_PORTS=8080` and `FIREWALL_OUTBOUND_SUBNETS=10.42.0.0/16,10.43.0.0/16` (k3s pod + service CIDRs — verified: CouchDB svc was `10.43.x`). Without this the WebUI is unreachable.
- **Port-forwarding → qB:** wire gluetun's forwarded port to qB's listen port (gluetun writes the PF port to a file / exposes it; a small `VPN_PORT_FORWARDING_UP_COMMAND` or init updates qB's `Connection\PortRangeMin` via its API). Needed for healthy seeding.

## unflac cue-split — Option A: CronJob (approved)

A `CronJob` (every ~5 min) mounts the shared media volume, scans `/data/torrents/music-cue` for newly-complete albums (an image flac/ape/wv + `.cue`), and for each:
1. `iconv -f WINDOWS-1251 -t UTF-8` the `.cue` (RuTracker cues are usually CP-1251).
2. `unflac` (Go single binary; decodes flac/ape/wv via ffmpeg) splits + tags into `/data/import/music/<artist>/<album>/`.
3. Marks the source done (sentinel file) so it isn't re-split; **leaves the torrent seeding** in place.
Lidarr's import source = `/data/import/music`. Image = minimal (alpine + ffmpeg + the unflac binary). Decoupled from qB's image; the charset/decoder logic lives in one observable place.

## Storage — single shared volume (hardlink-capable)

One hostPath PV `/var/data/media` (storageClass `media`, ~150 Gi of 186 GB free; pace pulls), mounted `/data` (RW) in qB + Lidarr + the unflac job, and `/data/library/music` (RO) in Navidrome:
```
/data/torrents/music       qB complete (standard category)
/data/torrents/music-cue   image+cue category (unflac input)
/data/import/music         unflac split output → Lidarr import source
/data/library/music        Lidarr-managed final library ← Navidrome reads
```
Single volume ⇒ Lidarr **hardlinks** torrents→library (instant move, keeps seeding, no double space). Navidrome config/DB on a small separate PV `/var/data/navidrome`.

## Secrets (Vaultwarden syncer)

- `proton-wg` (ns `media`): `WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES` — gluetun. Owner provides a dedicated Proton WG config (P2P + PF).
- qB WebUI password: set in-app on first run (or `WEBUI_PASSWORD` env). *arr API keys are app-internal (on the PV); Prowlarr↔Lidarr linked via Prowlarr "Apps" — no k8s secrets.

## Networking / egress

- qB egress: only via gluetun/Proton. Prowlarr/Lidarr/Navidrome: normal pod egress.
- hephaestus host egress jail (litellm/hermes) does not affect k3s pods — pods egress freely. gluetun reaches Proton's WG endpoint (UDP) fine.
- Independent of zeus's network-wide Proton toggle (that's for client VLANs; this is a per-pod always-on tunnel).

## Ingress / DNS (existing Traefik + wildcard pattern)

`navidrome` · `prowlarr` · `lidarr` · `qbittorrent` `.leotsgo.dev` → `192.168.50.10`, wildcard `*.leotsgo.dev` TLS (no per-host secret), LAN + tailnet. AdGuard rewrites + grey-cloud Cloudflare records added in `homelab-network`. Navidrome is the client-facing one; the rest are admin UIs.

## Backups (restic → B2, now)

- `media` repo: back up **`/var/data/media/library`** only (curated; torrents/incomplete are re-downloadable). Add `media` to `debian-k3s` `restic_apps` (paths `["/var/data/media/library"]`).
- Navidrome DB (playlists/stars/play-counts, embedded SQLite): set `ND_BACKUP_PATH` + schedule → restic `/var/data/navidrome`. Add as a second `restic_apps` entry `navidrome` (paths `["/var/data/navidrome"]`).

## Config-as-code layout (Flux)

```
apps/base/media/
  namespace.yml, volumes.yml (shared media PV/PVC + navidrome PV/PVC),
  qbittorrent.yml (Deployment: gluetun+qB, Service), prowlarr.yml, lidarr.yml,
  navidrome.yml, unflac-cronjob.yml, ingress.yml, kustomization.yml
apps/production/media/kustomization.yml  → ../../base/media
apps/hephaestus/media/kustomization.yml  → ../../production/media
# + append `media` to apps/hephaestus/kustomization.yml
```

## Pre-reqs (before enabling the overlay)

1. hostPath dirs on hephaestus: `/var/data/media/{torrents/{music,music-cue},import/music,library/music}` + `/var/data/navidrome`, chown to the linuxserver PUID/PGID (1000) and navidrome's uid.
2. `proton-wg` syncer item in the `k3s@` vault (namespaces: media) — from a dedicated Proton WG config (P2P + port-forwarding).
3. DNS: 4 AdGuard rewrites + Cloudflare A records → 192.168.50.10.

## Verification (before "done")

- gluetun connects; qB's public IP ≠ home WAN IP.
- Kill-switch: stop gluetun → qB has no egress (verify it can't reach the internet).
- Port-forward: gluetun PF port open + wired to qB.
- Chain: add an indexer in Prowlarr → syncs to Lidarr → search/grab → downloads via VPN → unflac splits a test image+cue album → Lidarr imports per-track (hardlinked) → Navidrome scans + plays via Supersonic.
- restic `media` + `navidrome` snapshots land in B2.

## NAS migration (later, Phase 2)

rsync `/var/data/media/library` → NFS on `mnemosyne`; repoint Lidarr root folder + Navidrome music path; switch the PVCs local-path → NFS (Lidarr DB + restic repo come along, no re-download). Add Radarr/Sonarr/Bazarr/Jellyfin then.

## Open items / confirm at build time

- Image pins (qB/gluetun/prowlarr/lidarr/navidrome/unflac base).
- Dedicated Proton WG config: which P2P/PF server; confirm PF works on the chosen server.
- Exact PUID/PGID + navidrome uid for the hostPath chown.
- gluetun→qB port-forward wiring mechanism (up-command vs sidecar updater) — confirm against current gluetun version.
- unflac binary source/version for the CronJob image.
