# Design

## Goal
Self-hosted services on hopper (mfilipe.eu) with HTTPS, security, minimal maintenance.

## Stack
- **Reverse proxy**: Caddy (Docker) - Let's Encrypt wildcard cert via DNS-01 (Gandi plugin)
- **Security**: fail2ban on Caddy logs (401/403/404 → IP ban)
- **DDNS**: Go service updating Gandi DNS every 10min (systemd timer)
- **Monitoring**: VictoriaMetrics, Grafana, Telegraf
- **IoT**: Zigbee2MQTT, Mosquitto, sensors
- **Storage**: ZFS RAID10 with compression/snapshots
- **Secrets**: age-encrypted tar (secrets.tar.age in repo)

## Architecture
```
Internet:443 → Router → hopper:443 → Caddy (Docker)
                                      ├→ tv.mfilipe.eu    → Jellyfin:8096 (systemd)
                                      ├→ img.mfilipe.eu   → Immich:2283 (docker)
                                      └→ graf.mfilipe.eu  → Grafana:3000 (docker) [TODO]

LAN services:
  Metrics: VictoriaMetrics, InfluxDB, Grafana (docker network)
  Host metrics: Telegraf, vmagent (network_mode: host)
  IoT: Mosquitto, Zigbee2MQTT (network_mode: host)
  Sensors: inkbird-monitor (systemd)
  OpenClaw: LXC container at 10.250.85.62 (isolated, NAT outbound)
```

## Security Layers
1. Only port 443 exposed
2. fail2ban: 10 auth failures or 20 404s → 1 day ban
3. Caddy: rate limiting, security headers
4. Services: localhost-only or isolated networks

## Services
| Service | Domain | Tech | User |
|---------|--------|------|------|
| Caddy | *.mfilipe.eu | Docker | nobody:adm |
| Jellyfin | tv.mfilipe.eu | systemd | jellyfin |
| Immich | img.mfilipe.eu | Docker | 1000:1000 |
| Grafana | graf.mfilipe.eu [TODO] | Docker | monitoring network |
| VictoriaMetrics | - | Docker | monitoring network |
| InfluxDB | - | Docker | monitoring network |
| Telegraf | - | Docker | network_mode: host |
| vmagent | - | Docker | network_mode: host |
| Mosquitto | - | Docker | network_mode: host |
| Zigbee2MQTT | - | Docker | network_mode: host |
| inkbird-monitor | - | systemd | nobody |
| OpenClaw | LAN:18789 | LXC | openclaw user |
| DDNS | - | systemd timer | nobody:nogroup |
| fail2ban | - | systemd | root |

## Storage Layout
```
/srv/selfhost/                  # Repo root
/srv/logs/caddy/                # JSON access logs (nobody:adm)
/media/simple/immich/           # ZFS dataset (compression=off)
/media/simple/videos/           # Jellyfin media
/media/simple/victoriametrics/  # Time-series data
/media/simple/influxdb/         # Legacy metrics [TODO: migrate]
/media/simple/grafana/          # Dashboards & datasources
/media/simple/zigbee2mqtt/      # Zigbee coordinator data
```

## Secrets Management
- All env files encrypted in secrets.tar.age (in git)
- Decryption key: ~/.age-key.txt (59 bytes, not in git)
- Deploy script extracts to service dirs

## Design Decisions
- **Docker for services with complex deps**: Caddy, Immich, monitoring stack
- **Systemd for native packages**: Jellyfin, DDNS, fail2ban, inkbird-monitor
- **Wildcard cert**: Single Let's Encrypt cert for all subdomains
- **ZFS compression off for media**: Already compressed (photos/video)
- **ZFS compression on for DB**: Postgres/metrics benefit from zstd-fast
- **LXC for OpenClaw**: Lightweight container, isolated network with NAT
- **network_mode: host for metrics/IoT**: Required for localhost scraping and MQTT
