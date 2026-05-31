# Monitoring Stack

Metrics collection, storage, and visualization.

## Services

**Main stack** (docker-compose.yml):
- **VictoriaMetrics** - Time-series database (port 8428, 8089)
- **InfluxDB** - Legacy metrics (port 8086) - TODO: Migrate to VictoriaMetrics
- **Grafana** - Visualization (port 3000) - TODO: Expose as graf.mfilipe.eu after password set

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

Create `env` file:
```bash
cp env.example env
# Edit env: Set strong GRAFANA_PASSWORD
```

## Storage

- VictoriaMetrics: `/media/simple/victoriametrics`
- InfluxDB: `/media/simple/influxdb`
- Grafana: `/media/simple/grafana`

## TODO

- [ ] Migrate kostal2influx to VictoriaMetrics
- [ ] Set strong Grafana password
- [ ] Expose graf.mfilipe.eu via Caddy
- [ ] Remove InfluxDB after migration complete
