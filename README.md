# selfhost

Self-hosted infrastructure for mfilipe.eu on **hopper** (Debian / ZFS / Docker).
Architecture and rationale: DESIGN.md.

## Services

| Dir | Service | Endpoint |
|-----|---------|----------|
| `caddy/` | Reverse proxy + TLS for all `*.mfilipe.eu` | — |
| `immich/` | Photos | img.mfilipe.eu |
| `memos/` | Notes | notes.mfilipe.eu |
| `blog/` | Hugo site, served static from `blog/site/` | blog.mfilipe.eu |
| `jellyfin/` | Media (systemd) | tv.mfilipe.eu |
| `monitoring/` | VictoriaMetrics + Grafana + Telegraf + vmagent | graf. / metrics.mfilipe.eu |
| `iot/` | Zigbee2MQTT + Mosquitto | internal |
| `llm/` | Local LLM via llama-swap (systemd); see `llm/AGENTS.md` | internal |
| `ddns/` | Dynamic DNS updater (systemd timer) | — |
| `fail2ban/` | IP banning | — |

## Deploy

```bash
git clone git@github.com:msf/selfhost.git /srv/selfhost && cd /srv/selfhost
./deploy.sh        # decrypt secrets.tar.age → */env  (needs ~/.age-key.txt)
```

- **Docker:** `docker compose up -d` in each dir with a compose file
  (`caddy`, `immich`, `memos`, `monitoring`, `monitoring/telegraf`,
  `monitoring/vmagent`, `iot`).
- **Systemd:** `jellyfin`, `ddns.timer`, `fail2ban`. LLM stack via `llm/install.sh`,
  fail2ban via `fail2ban/install.sh`.

## Update

```bash
git pull && ./deploy.sh
docker compose restart        # in the changed dir
# or: sudo systemctl restart <unit>
```

## Secrets

`env` files are gitignored; the tracked `.env` are symlinks to them. The encrypted
bundle is `secrets.tar.age` (age).

```bash
./encrypt-secrets.sh          # */env → secrets.tar.age
./deploy.sh                   # secrets.tar.age → */env
```

## Status

```bash
docker ps
docker logs <name>
systemctl status jellyfin ddns fail2ban
sudo fail2ban-client status
```
