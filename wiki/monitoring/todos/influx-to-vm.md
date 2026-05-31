---
title: Migrate legacy InfluxDB to VictoriaMetrics
slug: influx-to-vm
type: todo
domain: monitoring
tags: [monitoring, influxdb, victoriametrics, grafana]
related: [[infrastructure-overview]]
status: done
author: hermes
created: 2026-05-17
updated: 2026-05-31
state: done
owner: miguel
next: Set up graf.mfilipe.eu via Caddy
---

# Migrate legacy InfluxDB to VictoriaMetrics

**Completed 2026-05-31.** VictoriaMetrics is now the sole TSDB. InfluxDB container removed.

## What was done

1. **Telegraf** — removed `influxdb_v2` output, now writes only to VictoriaMetrics via `:8428` (Influx line protocol listener)
2. **kostal2influx** — compiled static binary (`CGO_ENABLED=0`), tested on x99 (NixOS), data confirmed in VM
3. **InfluxDB** — container stopped and removed from `docker-compose.yml`
4. **Grafana** — already only uses VictoriaMetrics datasource; no dashboard migration needed
5. **README.md** — updated to reflect migration

## Remaining

- `graf.mfilipe.eu` Caddy config (password is set, just needs Caddy block)
- systemd service for kostal2influx on x99 (binary works, service file ready)
- `/media/simple/influxdb/` archived — safe to remove after 2026-06-30

## kostal2influx

Binary: `~/bin/kostal2influx-static` on hopper. Compiled with `CGO_ENABLED=0` for NixOS compatibility.

Service config (for x99 `~/.config/systemd/user/kostal2influx.service`):
```ini
[Service]
ExecStart=/home/bolotas/bin/kostal2influx \
  -kostalHost=192.168.0.11 \
  -vmHost=hopper \
  -vmPort=8428 \
  -sleep_secs=5
```

Kostal inverter (PIKO 4.6-2 MP plus) at `192.168.0.11` — only reachable from x99 network. Writes via Tailscale to hopper:8428.

## Links

- [[infrastructure-overview]]
- [[monitoring-stack]]
- Configs: `/srv/selfhost/monitoring/`
- Source: `/srv/selfhost/kostal2influx-review/`
- Legacy data: `/media/simple/influxdb/` (archived)

## Discussion

**2026-05-17 @claude:** the relevant TODOs were scattered across READMEs; aggregated here for a single view.

**2026-05-31 @hermes:** Migration completed. InfluxDB container removed. kostal2influx tested and writing to VM from x99.
