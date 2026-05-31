# Immich — Operations

Self-hosted Immich on hopper. Reachable at `https://img.mfilipe.eu` via Caddy → `127.0.0.1:2283`.

## Layout

```
/srv/selfhost/immich/
├── docker-compose.yml         # 4 services: server, ML, valkey, postgres
├── env                        # secrets + paths (NOT in git)
├── env.example                # template
└── hwaccel.transcoding.yml    # VAAPI accel for immich-server
```

Data on ZFS pool `simple`:

```
/media/simple/immich/
├── library/    # UPLOAD_LOCATION → container /data
├── postgres/   # DB_DATA_LOCATION → container /var/lib/postgresql/data
└── uploads/    # legacy, unused by current compose
```

Plus read-only bind: host `/media/simple` → container `/mnt/simple:ro` (for external library imports).

## Critical UID/GID

The postgres container runs as **uid 999 / gid 999**. On hopper, uid 999 happens to be the host `plex` user. Files in `/media/simple/immich/postgres/` MUST be owned by uid 999 (and the directory itself must be enterable by uid 999, mode 700 owned by 999:999). If the parent dir is owned by another user (e.g. `miguel:staff` 700), postgres fails with `could not open file "global/pg_filenode.map": Permission denied` and `immich_server` enters a restart loop.

Fix:

```bash
sudo chown -R 999:999 /media/simple/immich/postgres
sudo chmod 700 /media/simple/immich/postgres
docker compose -f /srv/selfhost/immich/docker-compose.yml restart database
docker compose -f /srv/selfhost/immich/docker-compose.yml restart immich-server
```

## Version Pinning — Current Footgun

`docker-compose.yml` references `ghcr.io/immich-app/immich-server:release` (literal `:release` tag) instead of `${IMMICH_VERSION}`. The `IMMICH_VERSION` value in `env` is **decorative only** — any `docker compose pull` jumps straight to upstream latest. To get reproducible upgrades, change the two image lines to:

```yaml
image: ghcr.io/immich-app/immich-server:${IMMICH_VERSION}
image: ghcr.io/immich-app/immich-machine-learning:${IMMICH_VERSION}
```

Then bump `IMMICH_VERSION=v2.7.5` (or whatever) in `env` to upgrade. Always pin to a concrete tag, never `release`.

## Backup (before any upgrade)

```bash
cd /srv/selfhost/immich
mkdir -p /media/simple/backup/immich
# 1. stop server (DB stays up)
docker compose stop immich-server immich-machine-learning
# 2. dump DB
docker exec -t immich_postgres pg_dump --clean --if-exists \
  --dbname=immich --username=immich \
  | gzip > /media/simple/backup/immich/dump-$(date +%F).sql.gz
# 3. snapshot library (ZFS)
sudo zfs snapshot simple/<dataset>@immich-pre-upgrade-$(date +%F)
```

Restore: `gunzip -c dump.sql.gz | docker exec -i immich_postgres psql --dbname=immich --username=immich --single-transaction --set ON_ERROR_STOP=on`.

## Upgrade Procedure

1. Read release notes between current and target: <https://github.com/immich-app/immich/releases>. Look for breaking changes, DB migration notes, postgres image bumps.
2. Backup (above).
3. Edit `env`: `IMMICH_VERSION=vX.Y.Z`. Confirm compose uses `${IMMICH_VERSION}`.
4. Compare `docker-compose.yml` against upstream <https://github.com/immich-app/immich/blob/vX.Y.Z/docker/docker-compose.yml> — pick up postgres/valkey image changes.
5. Pull and restart:
   ```bash
   cd /srv/selfhost/immich
   docker compose pull
   docker compose up -d
   docker compose logs -f immich-server
   ```
6. Verify: `curl -fsS http://127.0.0.1:2283/api/server/ping`, then web UI at <https://img.mfilipe.eu>. Trigger a small upload + thumbnail.
7. `docker image prune` once stable.

**No downgrade path.** Switching back even within a minor is unsupported. Restore from backup if rollback needed.

## v2.4.1 → v2.7.5 Specifics

- No documented breaking changes.
- Postgres image stays `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0` (unchanged in v2.7.5 upstream compose). Don't touch it.
- ML now requires `x86-64-v2` microarch on amd64 (hopper meets this). Hard requirement only in v3.0.
- Optional: set `IMMICH_HELMET_FILE=true` in `env` for default CSP.
- Old timeline deprecated; will be removed in v3.0 — migrate accounts in the UI before next major.
- Reindex on first start can be slow on large libraries; logs may look stuck — only worry if errors appear.

## Hardware Acceleration

`hwaccel.transcoding.yml` provides the `vaapi` profile, extended into `immich-server`. Verify `/dev/dri/renderD128` is readable inside the container:

```bash
docker exec immich_server ls -la /dev/dri 2>&1
```

If transcoding fails, fall back by removing the `extends:` block from `immich-server`.

## Reverse Proxy

Caddy (`/srv/selfhost/caddy/Caddyfile`) terminates TLS for `img.mfilipe.eu` and proxies to `127.0.0.1:2283`. Immich binds to loopback only — never expose `2283` on a public interface.

## Health Checks

```bash
docker compose ps                          # all 4 healthy?
docker compose logs --tail 50 immich-server
docker exec immich_postgres pg_isready -U immich
curl -fsS http://127.0.0.1:2283/api/server/ping
curl -fsS http://127.0.0.1:2283/api/server/version
```

## Common Failure Modes

| Symptom | Likely Cause | Fix |
|---|---|---|
| `immich_server` restart loop, postgres logs `Permission denied` on `pg_filenode.map` / `postmaster.pid` | parent dir of postgres data owned by wrong uid | `chown -R 999:999 /media/simple/immich/postgres` |
| `:release` pulled an unexpected new version | compose pinned to `:release` not `${IMMICH_VERSION}` | switch to `${IMMICH_VERSION}` and pin |
| ML fails to load model | first-run download or arch unsupported | check `/cache` volume; verify CPU has `x86-64-v2` |
| Slow reindex after upgrade | normal on large libraries | wait, watch logs for actual errors |
| Web UI 502 via Caddy | server unhealthy | `docker compose logs immich-server` |
