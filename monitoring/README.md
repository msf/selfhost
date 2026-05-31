# Monitoring Stack

Metrics collection, storage, and visualization.

## Services

**Main stack** (docker-compose.yml):
- **VictoriaMetrics** - Time-series database (port 8428, 8089)
- **Grafana** - Visualization (port 3000)

**Host-network services** (separate composes):
- **Telegraf** - System metrics collection
- **vmagent** - Prometheus scraper + remote writer

## Deploy

```bash
cd /srv/selfhost/monitoring

# Main stack
docker compose up -d

# Host-network services
cd telegraf && docker compose up -d
cd ../vmagent && docker compose up -d
```

## Configuration

Create `.env` file:
```bash
cp env.example .env
# Edit .env: Set strong GRAFANA_PASSWORD
```

## Storage

- VictoriaMetrics: `/media/simple/victoriametrics`
- Grafana: `/media/simple/grafana`
- Legacy InfluxDB: `/media/simple/influxdb` (archived, can be removed after 30 days)

## Migration Notes

- **2026-05-31:** Migrated InfluxDB → VictoriaMetrics. Telegraf writes only to VM.
  kostal2influx compiled as static binary, runs on x99 → writes to VM via Tailscale.
- InfluxDB container removed from docker-compose. Data archived at `/media/simple/influxdb/`.

## TODO

- [ ] Expose graf.mfilipe.eu via Caddy
- [ ] Set up systemd service for kostal2influx on x99
- [ ] Remove `/media/simple/influxdb/` after 30-day grace period (2026-06-30)
