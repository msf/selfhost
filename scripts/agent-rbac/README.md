# Agent RBAC System

This directory contains scripts for setting up role-based access control (RBAC) for running agents on the server.

## Overview

Agents need controlled access to the server for monitoring, diagnostics, and deployment tasks. This system provides:

- **Role-based access** via Unix groups
- **Limited sudo access** for specific operations
- **SSH key authentication** for secure login

## Roles

| Role | Group | Capabilities |
|------|-------|-------------|
| **readonly** | `agents` | Read logs, configs, docker ps, curl endpoints |
| **operator** | `ops-agent` | + systemctl restart, docker restart, read /srv |
| **deploy** | `deploy-agent` | + git pull, docker compose, rebuild |

## Usage

### Create an agent user

```bash
# As root
sudo ./setup-agent.sh <username> <role> [ssh_public_key]

# Examples
sudo ./setup-agent.sh bolotas operator ~/.ssh/id_ed25519.pub
sudo ./setup-agent.sh readonly-agent readonly
```

### Login as agent

```bash
ssh agent@hostname
```

### Check what commands are allowed

```bash
# As the agent user
sudo -l
```

## Files

- `setup-agent.sh` - Main setup script

## Security Notes

- Agents use SSH key authentication only (no password)
- Sudo access is limited to specific commands per role
- Filesystem permissions restrict access to sensitive areas
- Review `/etc/sudoers.d/agent-*` for exact permissions
