# Early Music Subset Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Prowlarr · Lidarr · qBittorrent+gluetun(Proton) · unflac cue-split CronJob · Navidrome to the home k3s cluster (hephaestus) on local-path storage, so music acquisition + playback work before the NAS exists.

**Architecture:** Raw manifests + Kustomize overlays (`apps/base/media` → `production` → `hephaestus`), one `media` namespace, a single shared hardlink-capable hostPath volume, qB locked behind a gluetun VPN kill-switch, Navidrome serving the curated library. DNS/restic/Proton bits in `homelab-network`.

**Tech Stack:** k3s, Flux, Kustomize, Traefik (wildcard TLS), linuxserver.io images, gluetun, Navidrome, unflac, Vaultwarden syncer, restic→B2.

**Validation note:** every manifest task ends with `kubectl kustomize apps/hephaestus/media` (must build clean) as its "test". Image tags marked `# verify/bump` — confirm against the registry during execution. Spec: `docs/superpowers/specs/2026-06-15-music-subset-design.md`.

---

## File structure

```
homelab/apps/base/media/
  namespace.yml          # ns: media
  volumes.yml            # shared media PV/PVC + per-app config PV/PVCs + navidrome PV/PVC
  qbittorrent.yml        # Deployment (gluetun+qB) + Service
  prowlarr.yml           # Deployment + Service
  lidarr.yml             # Deployment + Service
  navidrome.yml          # Deployment + Service
  unflac.yml             # ConfigMap (split script) + CronJob
  ingress.yml            # 4 Ingress (navidrome/prowlarr/lidarr/qbittorrent)
  kustomization.yml
homelab/apps/production/media/kustomization.yml   # → ../../base/media
homelab/apps/hephaestus/media/kustomization.yml   # → ../../production/media
homelab/apps/hephaestus/kustomization.yml         # + media
homelab-network/vyos/adguard/AdGuardHome.yaml     # 4 rewrites
homelab-network/debian-k3s/group_vars/all/main.yml # restic_apps + media,navidrome
```

PUID/PGID for linuxserver images = `1000`. Navidrome runs as root by default (writes its own config); hostPath dirs chowned accordingly. k3s pod CIDR `10.42.0.0/16`, svc CIDR `10.43.0.0/16`.

---

## Task 0: Operational pre-reqs (manual/guided — gate the deploy)

**No repo files.** These must exist before the overlay is enabled or pods crashloop. Run on hephaestus / in Vaultwarden / DNS.

- [ ] **Step 1: hostPath dirs** (run on hephaestus, sudo)

```bash
sudo mkdir -p /var/data/media/torrents/music /var/data/media/torrents/music-cue \
              /var/data/media/import/music /var/data/media/library/music /var/data/media/bin \
              /var/data/qbittorrent /var/data/prowlarr /var/data/lidarr /var/data/navidrome
sudo chown -R 1000:1000 /var/data/media /var/data/qbittorrent /var/data/prowlarr /var/data/lidarr
sudo chown -R 0:0 /var/data/navidrome
ls -ld /var/data/media /var/data/navidrome
```

- [ ] **Step 2: dedicated Proton WireGuard config** — in the Proton dashboard, create a NEW WireGuard config on a **P2P server with port-forwarding enabled**. Note the `PrivateKey` and `Address`.

- [ ] **Step 3: `proton-wg` syncer item** — in the `k3s@leotsgo.dev` Vaultwarden vault create item `proton-wg`, custom fields: `namespaces=media`, `secret-name=proton-wg`, `WIREGUARD_PRIVATE_KEY=<key>` (Hidden), `WIREGUARD_ADDRESSES=<addr e.g. 10.2.0.2/32>`. Verify: `kubectl -n media get secret proton-wg` (after the ns exists).

- [ ] **Step 4: DNS** — covered in Task 9 (commit) + live apply (AdGuard UI rewrites + Cloudflare A records, all → 192.168.50.10).

---

## Task 1: Namespace + volumes

**Files:**
- Create: `apps/base/media/namespace.yml`
- Create: `apps/base/media/volumes.yml`

- [ ] **Step 1: namespace.yml**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: media
```

- [ ] **Step 2: volumes.yml** (shared media volume + per-app config volumes; hostPath static binds, storageClass = name, matching the calibre/couchdb pattern)

```yaml
# --- shared media library/downloads (hardlink-capable: one volume for qB+unflac+Lidarr) ---
apiVersion: v1
kind: PersistentVolume
metadata: { name: media-data, namespace: media }
spec:
  capacity: { storage: 150Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: media
  hostPath: { path: /var/data/media/ }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: media-data, namespace: media }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 150Gi } }
  storageClassName: media
  volumeName: media-data
---
# --- per-app config volumes (each linuxserver app needs /config; navidrome needs its data dir) ---
apiVersion: v1
kind: PersistentVolume
metadata: { name: qbittorrent-config, namespace: media }
spec:
  capacity: { storage: 1Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: qbittorrent
  hostPath: { path: /var/data/qbittorrent/ }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: qbittorrent-config, namespace: media }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
  storageClassName: qbittorrent
  volumeName: qbittorrent-config
---
apiVersion: v1
kind: PersistentVolume
metadata: { name: prowlarr-config, namespace: media }
spec:
  capacity: { storage: 1Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: prowlarr
  hostPath: { path: /var/data/prowlarr/ }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: prowlarr-config, namespace: media }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
  storageClassName: prowlarr
  volumeName: prowlarr-config
---
apiVersion: v1
kind: PersistentVolume
metadata: { name: lidarr-config, namespace: media }
spec:
  capacity: { storage: 2Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: lidarr
  hostPath: { path: /var/data/lidarr/ }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: lidarr-config, namespace: media }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 2Gi } }
  storageClassName: lidarr
  volumeName: lidarr-config
---
apiVersion: v1
kind: PersistentVolume
metadata: { name: navidrome-data, namespace: media }
spec:
  capacity: { storage: 2Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: navidrome
  hostPath: { path: /var/data/navidrome/ }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: navidrome-data, namespace: media }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 2Gi } }
  storageClassName: navidrome
  volumeName: navidrome-data
```

- [ ] **Step 3: kustomization.yml** (create with what exists so far)

```yaml
resources:
  - namespace.yml
  - volumes.yml
```

- [ ] **Step 4: validate**

Run: `kubectl kustomize apps/base/media`
Expected: clean YAML output (Namespace + PVs/PVCs), no errors.

- [ ] **Step 5: commit**

```bash
git add apps/base/media/{namespace,volumes,kustomization}.yml
git commit -m "media: namespace + local-path volumes (shared library + per-app config)"
```

---

## Task 2: qBittorrent + gluetun (VPN kill-switch)

**Files:**
- Create: `apps/base/media/qbittorrent.yml`
- Modify: `apps/base/media/kustomization.yml` (add `qbittorrent.yml`)

- [ ] **Step 1: qbittorrent.yml** — two containers share the pod netns; gluetun (NET_ADMIN) is the only network path; qB binds WebUI :8080.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: qbittorrent
  namespace: media
  labels: { app: qbittorrent }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector: { matchLabels: { app: qbittorrent } }
  template:
    metadata: { labels: { app: qbittorrent } }
    spec:
      containers:
        - name: gluetun
          image: qmcgaw/gluetun:v3.40.0   # verify/bump
          securityContext:
            capabilities: { add: ["NET_ADMIN"] }
          env:
            - { name: VPN_SERVICE_PROVIDER, value: "protonvpn" }
            - { name: VPN_TYPE, value: "wireguard" }
            - name: WIREGUARD_PRIVATE_KEY
              valueFrom: { secretKeyRef: { name: proton-wg, key: WIREGUARD_PRIVATE_KEY } }
            - name: WIREGUARD_ADDRESSES
              valueFrom: { secretKeyRef: { name: proton-wg, key: WIREGUARD_ADDRESSES } }
            - { name: VPN_PORT_FORWARDING, value: "on" }
            - { name: PORT_FORWARD_ONLY, value: "on" }
            - { name: FIREWALL_INPUT_PORTS, value: "8080" }
            - { name: FIREWALL_OUTBOUND_SUBNETS, value: "10.42.0.0/16,10.43.0.0/16" }
            - { name: TZ, value: "America/Sao_Paulo" }
          volumeMounts:
            - { name: gluetun-tmp, mountPath: /tmp/gluetun }
          resources:
            requests: { memory: "64Mi", cpu: "20m" }
            limits: { memory: "256Mi", cpu: "500m" }
        - name: qbittorrent
          image: lscr.io/linuxserver/qbittorrent:5.1.2   # verify/bump
          env:
            - { name: PUID, value: "1000" }
            - { name: PGID, value: "1000" }
            - { name: TZ, value: "America/Sao_Paulo" }
            - { name: WEBUI_PORT, value: "8080" }
          volumeMounts:
            - { name: config, mountPath: /config }
            - { name: data, mountPath: /data }
          resources:
            requests: { memory: "256Mi", cpu: "50m" }
            limits: { memory: "1Gi", cpu: "1000m" }
      volumes:
        - { name: gluetun-tmp, emptyDir: {} }
        - name: config
          persistentVolumeClaim: { claimName: qbittorrent-config }
        - name: data
          persistentVolumeClaim: { claimName: media-data }
---
apiVersion: v1
kind: Service
metadata:
  name: qbittorrent
  namespace: media
spec:
  selector: { app: qbittorrent }
  ports:
    - { name: webui, port: 8080, targetPort: 8080 }
```

- [ ] **Step 2: add to kustomization.yml** — resources list becomes `namespace.yml, volumes.yml, qbittorrent.yml`.

- [ ] **Step 3: validate**

Run: `kubectl kustomize apps/base/media`
Expected: clean build incl. the Deployment + Service.

- [ ] **Step 4: commit**

```bash
git add apps/base/media/{qbittorrent,kustomization}.yml
git commit -m "media: qBittorrent behind gluetun Proton kill-switch (shared netns, PF on)"
```

---

## Task 3: Prowlarr

**Files:**
- Create: `apps/base/media/prowlarr.yml`
- Modify: `apps/base/media/kustomization.yml`

- [ ] **Step 1: prowlarr.yml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prowlarr
  namespace: media
  labels: { app: prowlarr }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector: { matchLabels: { app: prowlarr } }
  template:
    metadata: { labels: { app: prowlarr } }
    spec:
      containers:
        - name: prowlarr
          image: lscr.io/linuxserver/prowlarr:1.30.2   # verify/bump
          env:
            - { name: PUID, value: "1000" }
            - { name: PGID, value: "1000" }
            - { name: TZ, value: "America/Sao_Paulo" }
          ports: [ { containerPort: 9696 } ]
          volumeMounts:
            - { name: config, mountPath: /config }
          resources:
            requests: { memory: "128Mi", cpu: "20m" }
            limits: { memory: "512Mi", cpu: "500m" }
      volumes:
        - name: config
          persistentVolumeClaim: { claimName: prowlarr-config }
---
apiVersion: v1
kind: Service
metadata:
  name: prowlarr
  namespace: media
spec:
  selector: { app: prowlarr }
  ports: [ { port: 9696, targetPort: 9696 } ]
```

- [ ] **Step 2: add `prowlarr.yml` to kustomization.yml resources.**
- [ ] **Step 3: validate** — `kubectl kustomize apps/base/media` builds clean.
- [ ] **Step 4: commit**

```bash
git add apps/base/media/{prowlarr,kustomization}.yml
git commit -m "media: Prowlarr indexer manager"
```

---

## Task 4: Lidarr

**Files:**
- Create: `apps/base/media/lidarr.yml`
- Modify: `apps/base/media/kustomization.yml`

- [ ] **Step 1: lidarr.yml** — mounts the SHARED media volume at `/data` (so it can hardlink from `/data/torrents` & `/data/import` into `/data/library`).

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lidarr
  namespace: media
  labels: { app: lidarr }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector: { matchLabels: { app: lidarr } }
  template:
    metadata: { labels: { app: lidarr } }
    spec:
      containers:
        - name: lidarr
          image: lscr.io/linuxserver/lidarr:2.9.6   # verify/bump
          env:
            - { name: PUID, value: "1000" }
            - { name: PGID, value: "1000" }
            - { name: TZ, value: "America/Sao_Paulo" }
          ports: [ { containerPort: 8686 } ]
          volumeMounts:
            - { name: config, mountPath: /config }
            - { name: data, mountPath: /data }
          resources:
            requests: { memory: "256Mi", cpu: "50m" }
            limits: { memory: "1Gi", cpu: "1000m" }
      volumes:
        - name: config
          persistentVolumeClaim: { claimName: lidarr-config }
        - name: data
          persistentVolumeClaim: { claimName: media-data }
---
apiVersion: v1
kind: Service
metadata:
  name: lidarr
  namespace: media
spec:
  selector: { app: lidarr }
  ports: [ { port: 8686, targetPort: 8686 } ]
```

- [ ] **Step 2: add `lidarr.yml` to kustomization.yml.**
- [ ] **Step 3: validate** — builds clean.
- [ ] **Step 4: commit**

```bash
git add apps/base/media/{lidarr,kustomization}.yml
git commit -m "media: Lidarr (shared media volume for hardlink imports)"
```

---

## Task 5: Navidrome

**Files:**
- Create: `apps/base/media/navidrome.yml`
- Modify: `apps/base/media/kustomization.yml`

- [ ] **Step 1: navidrome.yml** — reads the library RO; built-in DB backup to its data dir (restic-backed in Task 9).

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: navidrome
  namespace: media
  labels: { app: navidrome }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector: { matchLabels: { app: navidrome } }
  template:
    metadata: { labels: { app: navidrome } }
    spec:
      containers:
        - name: navidrome
          image: deluan/navidrome:0.54.5   # verify/bump
          env:
            - { name: ND_MUSICFOLDER, value: "/music" }
            - { name: ND_DATAFOLDER, value: "/data" }
            - { name: ND_BACKUP_PATH, value: "/data/backup" }
            - { name: ND_BACKUP_SCHEDULE, value: "0 4 * * *" }
            - { name: ND_BACKUP_COUNT, value: "7" }
            - { name: ND_SCANSCHEDULE, value: "1h" }
            - { name: ND_LOGLEVEL, value: "info" }
            - { name: TZ, value: "America/Sao_Paulo" }
          ports: [ { containerPort: 4533 } ]
          volumeMounts:
            - { name: data, mountPath: /data }
            - { name: music, mountPath: /music, readOnly: true }
          resources:
            requests: { memory: "128Mi", cpu: "50m" }
            limits: { memory: "1Gi", cpu: "1000m" }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: navidrome-data }
        - name: music
          persistentVolumeClaim: { claimName: media-data }
          # NOTE: subPath the library so Navidrome only sees /data/library/music
---
apiVersion: v1
kind: Service
metadata:
  name: navidrome
  namespace: media
spec:
  selector: { app: navidrome }
  ports: [ { port: 4533, targetPort: 4533 } ]
```

> During execution, set the `music` mount to `subPath: library/music` so Navidrome sees only the curated library, not torrents/import. (PVC subPath on the shared volume.)

- [ ] **Step 2: add `navidrome.yml` to kustomization.yml.**
- [ ] **Step 3: validate** — builds clean.
- [ ] **Step 4: commit**

```bash
git add apps/base/media/{navidrome,kustomization}.yml
git commit -m "media: Navidrome (RO library, built-in nightly DB backup)"
```

---

## Task 6: unflac cue-split CronJob (Option A)

**Files:**
- Create: `apps/base/media/unflac.yml` (ConfigMap script + CronJob)
- Modify: `apps/base/media/kustomization.yml`

- [ ] **Step 1: unflac.yml** — CronJob every 5 min; image has ffmpeg; the `unflac` binary is cached on the shared volume (`/data/bin/unflac`) so it's downloaded once. Splits new image+cue albums in `/data/torrents/music-cue` into `/data/import/music`, marking done via a `.unflac-done` sentinel; leaves the torrent seeding.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: unflac-script
  namespace: media
data:
  split.sh: |
    #!/bin/sh
    set -eu
    BIN=/data/bin/unflac
    SRC=/data/torrents/music-cue
    OUT=/data/import/music
    UNFLAC_URL="https://git.sr.ht/~ft/unflac/refs/download/v1.0.0/unflac-linux-amd64"  # verify/pin
    mkdir -p "$OUT" /data/bin
    if [ ! -x "$BIN" ]; then
      echo "fetching unflac…"; wget -qO "$BIN" "$UNFLAC_URL"; chmod +x "$BIN"
    fi
    find "$SRC" -name '*.cue' | while read -r cue; do
      dir=$(dirname "$cue")
      [ -f "$dir/.unflac-done" ] && continue
      echo "splitting: $cue"
      # RuTracker cues are usually CP-1251 → normalize to UTF-8 in a temp copy
      tmpcue=$(mktemp); iconv -f WINDOWS-1251 -t UTF-8 "$cue" > "$tmpcue" 2>/dev/null || cp "$cue" "$tmpcue"
      album=$(basename "$dir")
      mkdir -p "$OUT/$album"
      if "$BIN" -c "$tmpcue" -o "$OUT/$album" "$dir"/*.flac "$dir"/*.ape "$dir"/*.wv 2>/dev/null; then
        touch "$dir/.unflac-done"; echo "done: $album"
      else
        echo "FAILED (left for retry): $album"
      fi
      rm -f "$tmpcue"
    done
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: unflac
  namespace: media
spec:
  schedule: "*/5 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          securityContext: { runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000 }
          containers:
            - name: unflac
              image: jrottenberg/ffmpeg:7-alpine   # has ffmpeg; verify/bump
              command: ["/bin/sh", "/script/split.sh"]
              volumeMounts:
                - { name: data, mountPath: /data }
                - { name: script, mountPath: /script }
              resources:
                requests: { memory: "128Mi", cpu: "100m" }
                limits: { memory: "512Mi", cpu: "1000m" }
          volumes:
            - name: data
              persistentVolumeClaim: { claimName: media-data }
            - name: script
              configMap: { name: unflac-script }
```

> Execution checks: confirm the unflac release URL/version (binary may need building if no static release); confirm `jrottenberg/ffmpeg:7-alpine` ships `iconv`/`wget` (busybox `wget` yes; `iconv` may need `apk add musl-locales` — if absent, `apk add --no-cache gnu-libiconv` at script start, cached layer not persisted, so add to the script with a guard).

- [ ] **Step 2: add `unflac.yml` to kustomization.yml.**
- [ ] **Step 3: validate** — `kubectl kustomize apps/base/media` builds clean; `sh -n` the script content mentally (no syntax errors).
- [ ] **Step 4: commit**

```bash
git add apps/base/media/{unflac,kustomization}.yml
git commit -m "media: unflac cue-split CronJob (image+cue -> per-track FLAC)"
```

---

## Task 7: Ingress (4 hosts)

**Files:**
- Create: `apps/base/media/ingress.yml`
- Modify: `apps/base/media/kustomization.yml`

- [ ] **Step 1: ingress.yml** — one Ingress per app, house headers block, wildcard TLS (no secretName), `<app>.leotsgo.dev`.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: navidrome
  namespace: media
  annotations:
    traefik.ingress.kubernetes.io/headers: |
      browserXssFilter: true
      contentTypeNosniff: true
      forceSTSHeader: true
      stsIncludeSubdomains: true
      stsPreload: true
      stsSeconds: 31536000
      customFrameOptionsValue: "SAMEORIGIN"
      referrerPolicy: "strict-origin-when-cross-origin"
spec:
  rules:
    - host: "navidrome.leotsgo.dev"
      http:
        paths:
          - { path: /, pathType: Prefix, backend: { service: { name: navidrome, port: { number: 4533 } } } }
  tls:
    - hosts: [ "navidrome.leotsgo.dev" ]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: { name: prowlarr, namespace: media }
spec:
  rules:
    - host: "prowlarr.leotsgo.dev"
      http:
        paths:
          - { path: /, pathType: Prefix, backend: { service: { name: prowlarr, port: { number: 9696 } } } }
  tls:
    - hosts: [ "prowlarr.leotsgo.dev" ]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: { name: lidarr, namespace: media }
spec:
  rules:
    - host: "lidarr.leotsgo.dev"
      http:
        paths:
          - { path: /, pathType: Prefix, backend: { service: { name: lidarr, port: { number: 8686 } } } }
  tls:
    - hosts: [ "lidarr.leotsgo.dev" ]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: { name: qbittorrent, namespace: media }
spec:
  rules:
    - host: "qbittorrent.leotsgo.dev"
      http:
        paths:
          - { path: /, pathType: Prefix, backend: { service: { name: qbittorrent, port: { number: 8080 } } } }
  tls:
    - hosts: [ "qbittorrent.leotsgo.dev" ]
```

- [ ] **Step 2: add `ingress.yml` to kustomization.yml** (final base resources: namespace, volumes, qbittorrent, prowlarr, lidarr, navidrome, unflac, ingress).
- [ ] **Step 3: validate** — builds clean.
- [ ] **Step 4: commit**

```bash
git add apps/base/media/{ingress,kustomization}.yml
git commit -m "media: ingress for navidrome/prowlarr/lidarr/qbittorrent (wildcard TLS)"
```

---

## Task 8: Overlays + wire into the cluster

**Files:**
- Create: `apps/production/media/kustomization.yml`
- Create: `apps/hephaestus/media/kustomization.yml`
- Modify: `apps/hephaestus/kustomization.yml`

- [ ] **Step 1: production overlay**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/media
```

- [ ] **Step 2: hephaestus overlay**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# media subset: local-path hostPath PVs (/var/data/media + per-app config) bind once the
# dirs exist on hephaestus (Task 0); proton-wg syncer item must exist before qB starts.
resources:
  - ../../production/media
```

- [ ] **Step 3: append `media` to `apps/hephaestus/kustomization.yml`** resources (after `couchdb`).

- [ ] **Step 4: validate the full overlay chain**

Run: `kubectl kustomize apps/hephaestus/media`
Expected: clean full render (ns + all PVs/PVCs + 4 Deployments + 4 Services + CronJob + ConfigMap + 4 Ingress).

- [ ] **Step 5: commit**

```bash
git add apps/production/media apps/hephaestus/media apps/hephaestus/kustomization.yml
git commit -m "media: production+hephaestus overlays; enable on home cluster"
```

---

## Task 9: homelab-network — DNS + restic

**Files (in `homelab-network` repo):**
- Modify: `vyos/adguard/AdGuardHome.yaml`
- Modify: `debian-k3s/group_vars/all/main.yml`

- [ ] **Step 1: AdGuard rewrites** — add 4 entries (after the existing `couchdb` rewrite), each `answer: 192.168.50.10`, `enabled: true`: `navidrome.leotsgo.dev`, `prowlarr.leotsgo.dev`, `lidarr.leotsgo.dev`, `qbittorrent.leotsgo.dev`.

- [ ] **Step 2: restic_apps** — append to `debian-k3s/group_vars/all/main.yml`:

```yaml
  - name: media
    paths: ["/var/data/media/library"]   # curated library only; torrents/incomplete re-downloadable
  - name: navidrome
    paths: ["/var/data/navidrome"]        # playlists/stars/play-counts (Navidrome DB + backups)
```

- [ ] **Step 3: commit + push homelab-network**

```bash
cd ~/personal/homelab-network
git add vyos/adguard/AdGuardHome.yaml debian-k3s/group_vars/all/main.yml
git commit -m "media: AdGuard rewrites (4 apps ->.10) + restic media+navidrome -> B2"
git push origin main
```

- [ ] **Step 4: apply live** — add the 4 rewrites in the AdGuard UI (→192.168.50.10); add 4 grey-cloud Cloudflare A records (→192.168.50.10); deploy restic: `cd ~/personal/homelab-network/debian-k3s && ansible-playbook site.yml --tags restic --limit hephaestus`.

---

## Task 10: Deploy + verify (the integration tests)

**No new files.** Push the Flux repo, then verify end-to-end. Pre-reqs (Task 0) + DNS (Task 9.4) must be done first.

- [ ] **Step 1: push + reconcile**

```bash
cd ~/personal/homelab && git push origin main
ssh hephaestus 'kubectl -n media get deploy,pod,pvc,cronjob,ingress'
```
Expected: 4 deployments Available, PVCs Bound, CronJob scheduled, 4 ingresses with ADDRESS 192.168.50.10.

- [ ] **Step 2: VPN kill-switch verification**

```bash
# qB's public IP must be the Proton IP, NOT home WAN:
ssh hephaestus 'kubectl -n media exec deploy/qbittorrent -c qbittorrent -- curl -s ifconfig.me; echo'
# kill-switch: stop gluetun, confirm qB has NO egress, then let it restart:
ssh hephaestus 'kubectl -n media exec deploy/qbittorrent -c gluetun -- wget -qO- ifconfig.me'  # gluetun's view
```
Expected: a Proton exit IP (not your home IP). If gluetun is unhealthy, qB curl times out (kill-switch holds).

- [ ] **Step 3: port-forward → qB** — in gluetun logs find the forwarded port (`kubectl -n media logs deploy/qbittorrent -c gluetun | grep -i 'port forward'`); set qB's listen port (WebUI → Connection → Port) to that value. (Operational; the spec flags auto-wiring as a future improvement.)

- [ ] **Step 4: acquisition chain** — Prowlarr UI: add an indexer; add Lidarr as an "App" (sync). Lidarr: connect Prowlarr (indexers) + qBittorrent (download client, host `qbittorrent`, port 8080, category `music`; second category `music-cue` for image+cue). Add an artist, grab a release → confirm it downloads through the VPN and Lidarr imports (hardlinked into `/data/library/music`).

- [ ] **Step 5: unflac chain** — drop/grab an image+cue album into category `music-cue` → within 5 min the CronJob splits it into `/data/import/music`; point Lidarr Manual Import there → per-track FLACs import.

- [ ] **Step 6: Navidrome** — browse `https://navidrome.leotsgo.dev`, confirm it scanned the library and plays; connect Supersonic (desktop) / Symfonium (mobile).

- [ ] **Step 7: backups** — trigger restic once and confirm snapshots:

```bash
ssh hephaestus 'sudo systemctl start restic-backup.service
sudo bash -c "set -a; . /etc/restic/b2.env; set +a; restic -r s3:https://s3.us-east-005.backblazeb2.com/leotsgo-data/media snapshots; restic -r s3:https://s3.us-east-005.backblazeb2.com/leotsgo-data/navidrome snapshots"'
```
Expected: a snapshot in each repo.

- [ ] **Step 8: mark done** — update `homelab-plan.md` (Media stack § — music subset deployed) + memory; note the deferred tiddl path + NAS migration as the remaining media items.

---

## Self-review

- **Spec coverage:** components (T2–T6), VPN kill-switch+PF (T2,T10.2-3), shared hardlink volume (T1,T4), unflac CronJob Option A (T6), secrets via syncer (T0.3), ingress/DNS (T7,T9), restic media+navidrome (T9,T10.7), config-as-code layout (T1–T8), pre-reqs (T0), verification (T10) — all covered.
- **Placeholder scan:** image tags marked `# verify/bump` (explicit build-time confirm, per spec open-items); unflac URL + ffmpeg-image `iconv` availability flagged as execution checks (genuine external unknowns, not hand-waving) — acceptable, called out explicitly.
- **Consistency:** shared PVC `media-data` mounted `/data` in qB+Lidarr+unflac, `subPath library/music` RO in Navidrome; categories `music`/`music-cue` consistent T6/T10; ports consistent (qB 8080, prowlarr 9696, lidarr 8686, navidrome 4533); CIDRs `10.42/16`,`10.43/16` consistent.
