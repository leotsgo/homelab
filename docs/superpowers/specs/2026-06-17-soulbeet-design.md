# Soulbeet — Soulseek + beets acquisition pipeline

**Status:** design approved 2026-06-17, ready for implementation plan.

## Goal

Add a second music-acquisition source to the homelab alongside the existing
qBittorrent/RuTracker flow. Specifically: deploy [Soulbeet](https://github.com/terry90/soulbeet)
(which orchestrates [slskd](https://github.com/slskd/slskd) + [beets](https://beets.io/))
to handle searches against Soulseek, auto-tag via beets-against-MusicBrainz,
and drop the organized output into a dedicated sibling library that Navidrome
picks up.

Replaces the previously-deferred "tiddl (Tidal FLAC) manual-import path" item
from the music-subset Phase-1 leftovers (Soulseek covers the same "stuff
RuTracker doesn't have" gap without the Tidal API drama).

## Why two acquisition sources

- **RuTracker / qBittorrent** — best for mainstream catalogues (Beatles
  discography, Specials lossless boxes, vinyl rips, etc.). Ratio mechanics,
  swarm-dependent, structured cue files.
- **Soulseek / Soulbeet** — best for obscure, regional, out-of-print,
  bootleg, or single-user-uploaded material that doesn't make it onto
  trackers. P2P direct, no ratio mechanics, often higher tagging quality
  because users seed already-tagged files.

The two sources are complementary, not redundant.

## Why beets in the loop (independent of Soulseek)

beets fixes two recurring problems with the current Lidarr-centric flow:

1. **Cover-art lag.** Lidarr depends on `api.lidarr.audio` (SkyHook), which
   polls MusicBrainz on its own clock (1–24h lag). beets hits MusicBrainz +
   Cover Art Archive directly at tag time, so a freshly-uploaded cover is in
   your FLACs immediately.
2. **Malformed cue / mismatched filename rips.** unflac's parser rejects
   several common EAC patterns (FILE-mid-TRACK for pregaps, etc.) and
   filename mismatches surface as "missing audio file" errors. beets uses
   AcoustID/Chromaprint fingerprinting — recognises the track from the audio
   itself and tags accordingly.

For this spec, beets is bundled inside the Soulbeet image (`:full` tier) and
operates only on Soulseek-acquired files. It is **not** wired as a
post-processor for the existing qBittorrent flow (could be added later).

## Architecture

### Two pods, distinct concerns

```
namespace: media

┌──────────────┐         ┌─────────────────────────────────┐
│ soulbeet pod │         │ slskd pod                       │
│              │         │  ┌────────────────────────────┐ │
│  soulbeet    │ ──HTTP─▶│  │ gluetun sidecar           │ │
│  :9765 UI    │         │  │  ProtonVPN tunnel #2      │ │
│              │ ──HTTP─▶│  │  PF on, port-update script│ │
│              │   ▲     │  └─────────┬──────────────────┘ │
│              │   │     │            │ (netns shared)     │
│              │   │     │  ┌─────────▼──────────────────┐ │
└──────────────┘   │     │  │ slskd container            │ │
       │           │     │  │  :5030 UI                  │ │
       │ HTTP      │     │  │  Soulseek listen port      │ │
       ▼           │     │  └────────────────────────────┘ │
┌──────────────┐   │     │  initContainer:                 │
│  navidrome   │   │     │   clear stale gluetun ip rules  │
│  (existing)  │   │     └─────────────────────────────────┘
└──────────────┘   │
                   └── slskd Service (cluster-internal)
```

- **soulbeet** has no VPN need — it never talks to Soulseek directly. It only
  hits slskd's HTTP API (cluster-internal) and Navidrome's HTTP API, and
  reads slskd's downloaded files via a shared hostPath PVC (the diagram
  omits the volume mount for clarity, but the storage table below shows it).
- **slskd** is wrapped in a gluetun sidecar because that's where Soulseek
  peer-to-peer connections originate. Same architectural pattern as
  qBittorrent.
- The gluetun sidecar must use a **second Proton WireGuard config**, not the
  qBittorrent one — same private key from two clients = tunnel fight.

### Why not one pod with both containers

Tempting (saves one gluetun instance), but:
- A pod restart of either takes down both.
- slskd's port-forwarding needs differ from qBittorrent's (different listen
  port, different up-command target).
- Pod-level resource limits become trickier (slskd's RAM doesn't have to be
  reserved alongside qBittorrent's WebUI).

Cost of a second gluetun: one extra WireGuard tunnel to Proton. Proton has
no per-device limit; bandwidth overhead at the WG layer is negligible.

## Storage

All hostPath PVCs on hephaestus (same pattern as the rest of the media
stack).

| Path on hephaestus | Mounted into | Purpose |
|---|---|---|
| `/data/soulseek/downloads/` | slskd (`/downloads`) + soulbeet (`/downloads`) | raw slskd downloads, read by soulbeet for the beets import step |
| `/data/soulseek/config/` | slskd (`/app`) | slskd config + sqlite |
| `/data/soulbeet/data/` | soulbeet (`/data`) | soulbeet sqlite db (jobs, library refs) |
| `/data/library/music/soulbeet/` | soulbeet (`/music/soulbeet`) | beets-organized library output; **already visible to Navidrome** via the existing `/music ← library/music` subpath mount |

The `/data/library/music/soulbeet/` location means Navidrome serves it
without any deployment change — Navidrome's current mount is the entire
`library/music/` subpath read-only, and `soulbeet/` is a child of it. The
existing hourly `ND_SCANSCHEDULE` will pick up new albums automatically.

beets config (mounted from ConfigMap at `/config/config.yaml`) is bundled
in the manifest and version-controlled. A per-folder beets database
(`.beets_library.db`) lives at the root of `/data/library/music/soulbeet/`
and is created automatically on first import.

## Network and VPN

### gluetun sidecar configuration

Mostly identical to qBittorrent's gluetun, with three differences:
- `WIREGUARD_PRIVATE_KEY` / `WIREGUARD_ADDRESSES` from `proton-wg-slskd`
  Secret (not `proton-wg`).
- `FIREWALL_INPUT_PORTS=5030` (slskd UI; no proxy needed since soulbeet
  talks to it via cluster service, not via gluetun's HTTP proxy).
- `VPN_PORT_FORWARDING_UP_COMMAND=/bin/sh /slskd-scripts/slskd-pf-up.sh`
  — points at a new script that updates slskd's listen port instead of
  qBittorrent's.

`FIREWALL_OUTBOUND_SUBNETS=10.42.0.0/16,10.43.0.0/16` (pod + service CIDRs)
stays the same so cluster-internal traffic still works.

`HTTPPROXY` is **off** — soulbeet doesn't need to egress through Proton, and
exposing another HTTP proxy with no consumer is just attack surface.

### slskd port-forward script

When Proton rotates the PF port, gluetun fires the up-command. The new
script reads `/tmp/gluetun/forwarded_port` and PATCHes slskd's API:

```sh
#!/bin/sh
PORT="$(cat /tmp/gluetun/forwarded_port 2>/dev/null)"
[ -n "$PORT" ] || exit 0
API_KEY="$(cat /run/secrets/slskd-api-key)"
i=0
while [ "$i" -lt 12 ]; do
  if wget -q --header="X-API-Key: $API_KEY" \
       --header='Content-Type: application/json' \
       --post-data="{\"soulseek\":{\"listen_port\":$PORT}}" \
       --method=PATCH \
       http://127.0.0.1:5030/api/v0/options -O- >/dev/null 2>&1; then
    echo "pf-up: set slskd listen_port=$PORT"; exit 0
  fi
  i=$((i+1)); sleep 5
done
echo "pf-up: failed to set port $PORT after retries"; exit 0
```

Same structure as qBittorrent's `pf-up.sh`. slskd's API requires the
API key — it doesn't have a localhost-auth bypass like qBittorrent does.
API key is mounted from the `slskd-secrets` Secret as a file.

### initContainer (stale rules)

Same fix as commit `ce4902c` for qBittorrent's gluetun. Trivial alpine
container with NET_ADMIN that runs:

```sh
ip -6 rule del from all to all table 51820 2>/dev/null || true
ip -4 rule del from all to all table 51820 2>/dev/null || true
```

Prevents the 4h16m gluetun backoff death-spiral when the gluetun
container restarts in place inside a preserved pod netns.

## Secrets (Vaultwarden entries)

Three new entries to add to Vaultwarden. The existing
`antoniolago/vaultwarden-kubernetes-secrets` syncer materialises each into
a k8s Secret in the `media` namespace (tagged via the syncer's `namespaces`
mechanism).

| Vaultwarden entry name | k8s Secret name | Keys |
|---|---|---|
| `Proton WG - slskd (CNPG-style cluster secret)` | `proton-wg-slskd` | `WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES` (from a fresh Proton WG config you generate in the dashboard with NAT-PMP/PF on, P2P server) |
| `slskd (admin + API)` | `slskd-secrets` | `SLSKD_USERNAME`, `SLSKD_PASSWORD` (web UI admin), `SLSKD_API_KEY` (generated random, passed to soulbeet) |
| `soulbeet` | `soulbeet-secrets` | `SECRET_KEY` (random 64-char string, encrypts soulbeet's stored tokens like the slskd API key it stores) |

No Soulseek credentials in Kubernetes — those are set inside slskd's web UI
on first run and persisted to `/data/soulseek/config/`.

## Ingress

Two new hosts, both reverse-proxied by Traefik with the existing
`*.leotsgo.dev` wildcard cert:

| Host | Service | Purpose |
|---|---|---|
| `soulbeet.leotsgo.dev` | `soulbeet:9765` | the main UI you'll use day-to-day |
| `slskd.leotsgo.dev` | `slskd:5030` | slskd's own UI for browsing peers, reviewing transfers, debugging |

Both AdGuard-rewritten to `192.168.50.10` (the hephaestus IP) for split-horizon
just like the other media-stack hosts.

## beets configuration

Mounted from ConfigMap at `/config/config.yaml`, baked into the manifest.
Key choices:

```yaml
import:
  copy: yes               # copy from /downloads to /music/soulbeet, don't move
  write: yes              # write tags to files
  timid: no               # auto-accept confident matches

match:
  strong_rec_thresh: 0.10
  distance_weights:
    missing_tracks: 0.1   # less penalty for incomplete albums

fetchart:
  auto: yes
  cover_format: jpg

embedart:
  auto: yes

replaygain:
  auto: yes
  backend: ffmpeg

plugins: fetchart embedart replaygain chroma lyrics info

paths:
  default: $albumartist/$album%aunique{}/$track $title
  singleton: Non-Album/$artist/$title
  comp: Compilations/$album%aunique{}/$track $title
```

Soulbeet env: `BEETS_ALBUM_MODE=true` (group multi-track downloads as
albums; without this beets defaults to per-track-singleton mode).

Lower `strong_rec_thresh` and the `missing_tracks` weight adjustment are
explicitly recommended by Soulbeet's README for album-mode imports — beets
otherwise skips imports needing user intervention (quiet mode), which kills
the fully-automated path.

## Repo layout

New files under `apps/base/media/`:

```
apps/base/media/
  soulbeet.yml         # Deployment + Service + Ingress for soulbeet
  slskd.yml            # Deployment (gluetun + slskd + initContainer) + Service + Ingress
  slskd-scripts.yml    # ConfigMap: slskd-pf-up.sh
  beets-config.yml     # ConfigMap: /config/config.yaml for soulbeet
  volumes.yml          # MODIFIED: add the 3 new hostPath PVCs
  kustomization.yml    # MODIFIED: add the 4 new resource files
```

The existing media-stack convention is flat-in-one-dir; no per-app
subdirectory.

## Bootstrap order

```
1. Create hostPath dirs on hephaestus:
   ssh hephaestus 'sudo mkdir -p /data/soulseek/{downloads,config} \
                                 /data/soulbeet/data \
                                 /data/library/music/soulbeet && \
                   sudo chown -R 1000:1000 /data/soulseek /data/soulbeet \
                                           /data/library/music/soulbeet'

2. Proton dashboard → generate 2nd WireGuard config:
   - Platform: Router
   - NAT-PMP/PF: ON
   - Server: any P2P-allowed server (different from qB's preferred to spread load)
   - Save the private key + addresses

3. Add the 3 Vaultwarden entries (above)

4. git add + commit + push the new manifests → Flux reconciles

5. Once pods are Ready:
   - https://slskd.leotsgo.dev → log in (SLSKD_USERNAME/SLSKD_PASSWORD)
     → Settings → connect to Soulseek with your Soulseek username/password
   - https://soulbeet.leotsgo.dev → log in with Navidrome credentials
     → Settings → Config → connect slskd (URL: http://slskd:5030, API key)
     → Settings → Library → add /music/soulbeet as a folder

6. Smoke test: search for a known album → download → verify it lands at
   /data/library/music/soulbeet/<Artist>/<Album>/<tracks>.flac with
   embedded cover art

7. Wait for Navidrome hourly scan OR force:
   kubectl -n media exec deploy/navidrome -- /app/navidrome scan
   → confirm album appears in Navidrome UI
```

## Resource sizing (initial)

| Container | requests | limits |
|---|---|---|
| gluetun (slskd pod) | 64Mi / 20m | 256Mi / 500m |
| slskd | 128Mi / 50m | 512Mi / 1000m |
| soulbeet | 256Mi / 50m | 1Gi / 1500m |

soulbeet's limit is the highest because beets fingerprinting (chroma plugin)
and cover-art fetching happen during import — short bursts of CPU and RAM.
At idle soulbeet is much smaller.

Disk: `/data/soulseek/downloads/` is the variable. 50Gi starting size,
manually purge or beets-import-then-delete pattern keeps it bounded.

## Out of scope

- **Last.fm / ListenBrainz discovery** — Soulbeet's auto-recommendation
  engine. Skipped for now; we want manual control over what enters the
  library. Trivial to enable later (just settings in the UI, no infra
  change).
- **AcoustID API key** — `:full` image works without one for basic
  fingerprinting; only matters under high query volume which a single user
  won't hit.
- **Multi-user** — single user (the owner).
- **beets as a post-processor for the qBittorrent/unflac flow** — could
  rescue the EAC-style rips that unflac can't parse, but adds coupling
  between the two pipelines. Defer until the Soulbeet flow is proven and
  we have a clearer view of what beets adds.

## Risks and known gotchas

- **slskd's port-forward might race on cold boot** — same race we saw with
  qBittorrent. The retry loop in `slskd-pf-up.sh` handles it (12 × 5s).
- **Proton's PF rotation** — every few hours / on reconnect. Without the
  up-command running, slskd would advertise a stale port → no incoming peer
  connections → all transfers go through DERP-like relays (slow). The
  up-command keeps it current.
- **slskd's first-run is interactive** — you must log into the UI and
  supply Soulseek credentials. Cannot be fully GitOps-bootstrapped without
  also storing the Soulseek password in Vaultwarden (worth doing as a
  follow-up so DR is hands-off).
- **beets is destructive when wrong** — bad confidence thresholds can lead
  to mis-tagged or mis-organized files. Lower threshold (0.10) is per the
  Soulbeet README's album-mode guidance, but worth watching the first few
  imports manually before fully trusting the auto path.
- **No connection from Lidarr to Soulbeet** — Lidarr's wishlist /
  RSS-monitoring still only covers RuTracker. If you wishlist something in
  Lidarr that's only on Soulseek, you'd need to search Soulbeet manually.
  Acceptable for now; cross-source automation is a deferred topic.
