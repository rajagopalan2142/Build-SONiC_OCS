# SONiC VS Setup & Deploy Script

`setup_and_deploy_vs.sh` — One-command setup, build, and deployment of a SONiC Virtual Switch (VS) device using Docker containers.

---

## What It Does

| Phase | Step | Details |
|-------|------|---------|
| **1** | Install dependencies | Docker engine, Compose plugin, Python tools, system packages |
| **2** | Acquire images | Docker cache → `.gz` archives → ZIP extract → build from source |
| **3** | Deploy | Create network, start containers, load CONFIG_DB into Redis |

Each phase is idempotent — safe to re-run at any point.

---

## Quick Start

```bash
# Full setup + deploy (requires sudo)
sudo bash setup_and_deploy_vs.sh

# Deploy only (images already loaded)
sudo bash setup_and_deploy_vs.sh --deploy-only

# Check current state
bash setup_and_deploy_vs.sh --dashboard
```

---

## Commands

| Command | Description | Requires sudo? |
|---------|-------------|----------------|
| *(no arg)* | Full setup: deps → images → deploy | Yes |
| `--deps-only` | Install system dependencies only | Yes |
| `--build-only` | Build or load Docker images only | Yes |
| `--deploy-only` | Deploy containers (images must exist) | Yes |
| `--stop` | Stop all containers | No |
| `--cleanup` | Stop + remove networks + interfaces | No |
| `--status` | Show container & network status | No |
| `--dashboard` | Show progress and next actions | No |
| `--show-build-info` | Preview detected build resources | No |
| `--logs [service]` | Follow container logs | No |
| `--help` | Usage information | No |

---

## Dashboard

Run `bash setup_and_deploy_vs.sh --dashboard` to see a live status overview:

```
============================================================
 SONiC VS SETUP DASHBOARD
============================================================
 Host: myhost
 Time: 2026-08-25 15:24:06 IST

Build resources
  CPUs: 4        RAM: 13 GB    Free disk: 806 GB
  Jobs: 1        Memory limit: 9g

Required images
  [OK]   docker-gbsyncd-vs:latest
  [OK]   docker-database:latest
  [OK]   docker-orchagent:latest
  [OK]   docker-eventd:latest
  [OK]   docker-lldp:latest
Images                 [########################] 5/5

Deployment
Containers running     [##############----------] 3/5
  Redis:              TODO (start database container)
  VS bridge:          READY

Next actions
  1. Check service health and CONFIG_DB
  2. Run: bash setup_and_deploy_vs.sh --logs
============================================================
```

The dashboard shows:

- **Build resources** — CPU, RAM, disk, auto-detected jobs and memory limit
- **Required images** — Which of the 5 images are loaded in Docker
- **Deployment** — Running containers, Redis status, bridge status
- **Next actions** — What to do next based on current state

---

## Image Acquisition (4 Strategies)

The script tries these in order, stopping at the first success:

| Strategy | Source | Speed |
|----------|--------|-------|
| **1** | Docker image cache | Instant |
| **2** | `.gz` archives in `sonic-extracted/` | ~30 sec |
| **3** | Extract from `sonic-buildimage.vs.zip` | ~2 min |
| **4** | Build from source (`make all`) | ~1.5–3 hours |

### Recommended: Pre-extract the ZIP

```bash
# One-time: extract the 5.2 GB ZIP
unzip -q sonic-buildimage.vs.zip -d sonic-extracted/

# Every subsequent run uses the fast .gz load path
sudo bash setup_and_deploy_vs.sh
```

---

## Build Configuration (Auto-Detected)

When building from source, the script auto-tunes `SONIC_BUILD_JOBS` and `SONIC_BUILD_MEMORY` based on your host:

```
JOBS = min(CPUs, floor((RAM - 4) / 6), floor(Disk / 30))
MEMORY = min(RAM - 4, 24) GB
```

| Host | CPUs | RAM | → JOBS | → MEMORY |
|------|------|-----|--------|----------|
| Small VM | 2 | 8 GB | 1 | 4g |
| Your host | 4 | 13 GB | 1 | 9g |
| Workstation | 8 | 32 GB | 4 | 24g |
| Build server | 16 | 64 GB | 8 | 24g |

### Preview Before Building

```bash
bash setup_and_deploy_vs.sh --show-build-info
```

### Override Defaults

```bash
# Force 2 jobs (may OOM on 13 GB RAM)
SONIC_BUILD_JOBS=2 sudo bash setup_and_deploy_vs.sh --build-only

# Set custom memory limit
SONIC_BUILD_MEMORY=16g sudo bash setup_and_deploy_vs.sh --build-only

# Both
SONIC_BUILD_JOBS=4 SONIC_BUILD_MEMORY=24g sudo bash setup_and_deploy_vs.sh
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SONIC_BRANCH` | `master` | Git branch to clone |
| `SONIC_BUILD_JOBS` | auto-detect | Parallel build jobs |
| `SONIC_BUILD_MEMORY` | auto-detect | Container memory limit |
| `PLATFORM` | `vs` | ASIC platform |
| `BUILD_SKIP_TEST` | `y` | Skip tests during build |

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│                   Host                           │
│  ┌──────────┐  ┌──────────┐  ┌───────────────┐ │
│  │ sonic-vs │  │ sonic-   │  │sonic-database │ │
│  │ (gbsyncd)│  │orchagent │  │ (redis:6379)  │ │
│  └────┬─────┘  └────┬─────┘  └───────┬───────┘ │
│       │             │                │          │
│       └─────────────┴────────────────┘          │
│                    │                             │
│          ┌─────────┴─────────┐                  │
│          │  sonic-eventd     │                  │
│          │  sonic-lldp       │                  │
│          └───────────────────┘                  │
│                                                 │
│  Veth pairs (Ethernet0-12) → bridge (br-sonic) │
└─────────────────────────────────────────────────┘
```

### Containers

| Container | Image | Purpose |
|-----------|-------|---------|
| `sonic-vs` | `docker-gbsyncd-vs:latest` | Main VS daemon (supervisord, syncd, gbsyncd) |
| `sonic-database` | `docker-database:latest` | Redis database (8+ DBs) |
| `sonic-orchagent` | `docker-orchagent:latest` | Switch orchestration agent |
| `sonic-eventd` | `docker-eventd:latest` | Event daemon |
| `sonic-lldp` | `docker-lldp:latest` | LLDP daemon |

### Network

```
sonic-vs-br (bridge, 10.0.0.1/24)
   ├── host-veth0 ── veth0  → Ethernet0
   ├── host-veth4 ── veth4  → Ethernet4
   ├── host-veth8 ── veth8  → Ethernet8
   └── host-veth12 ── veth12 → Ethernet12
```

---

## Configuration Files

The script generates these files if they don't already exist:

| File | Purpose |
|------|---------|
| `deployment/config/database_config.json` | Redis instances + database definitions |
| `deployment/config/config_db.json` | Device metadata, ports, features |
| `deployment/config/constants.yml` | ASIC platform constants |
| `deployment/hwsku/port_config.ini` | Lane-to-port mapping |

**Existing files are never overwritten.** Edit them manually and restart:

```bash
vim deployment/config/config_db.json
docker compose -f deployment/docker-compose.yml restart sonic-vs
```

---

## Day-to-Day Operations

### Start / Stop / Status

```bash
sudo bash setup_and_deploy_vs.sh --deploy-only   # Start all containers
bash setup_and_deploy_vs.sh --stop               # Stop all containers
bash setup_and_deploy_vs.sh --status             # Show status
bash setup_and_deploy_vs.sh --dashboard          # Full dashboard
bash setup_and_deploy_vs.sh --logs               # Follow logs
```

### Read Configuration

```bash
# Using sonic-db-cli (reliable)
docker exec sonic-vs sonic-db-cli CONFIG_DB keys "*"
docker exec sonic-vs sonic-db-cli CONFIG_DB hgetall "DEVICE_METADATA|localhost"

# Using redis-cli directly
docker exec sonic-vs redis-cli -h 127.0.0.1 -p 6379 -n 4 hgetall "DEVICE_METADATA|localhost"
```

### Access Container Shell

```bash
docker exec -it sonic-vs bash
docker exec -it sonic-orchagent bash
docker exec -it sonic-database bash
```

### Modify Configuration

```bash
# 1. Edit config file on host
vim deployment/config/config_db.json

# 2. Reload into CONFIG_DB (redis db4)
docker exec sonic-vs python3 -c "
import redis, json
with open('/etc/sonic/config_db.json') as f:
    config = json.load(f)
r = redis.Redis(host='127.0.0.1', port=6379, db=4)
r.flushdb()
for table, entries in config.items():
    if isinstance(entries, dict):
        for key, fields in entries.items():
            if isinstance(fields, dict):
                cleaned = {k: json.dumps(v) if not isinstance(v, (str,int,float)) else str(v) for k,v in fields.items()}
                r.hset(f'{table}|{key}', mapping=cleaned)
print(f'Loaded {r.dbsize()} keys')
"

# 3. Restart services
docker compose -f deployment/docker-compose.yml restart sonic-orchagent
```

---

## Troubleshooting

| Problem | Check |
|---------|-------|
| Containers restarting | `docker logs <container>` for errors |
| `hostname` not found error | Verify `database_config.json` uses `hostname` key |
| Supervisor log missing | Ensure `./logs/supervisor` directory exists |
| `sonic-cfggen` hangs | Use `sonic-db-cli` instead |
| Config not applied | Verify keys: `sonic-db-cli CONFIG_DB keys "*"` |
| Port not showing up | Check `PORT` and `PORT_CONFIG` tables in CONFIG_DB |
| Orchagent crashing | Check STATE_DB for switch port errors |
| Redis unreachable | `redis-cli -h 127.0.0.1 -p 6379 ping` |
| Build OOM | Run `--show-build-info` to check resource limits |
| Build too slow | Increase `SONIC_BUILD_JOBS` on a larger host |

### Known Issues

1. **`sonic-cfggen -w` hangs** — The script bypasses this by loading config directly into Redis via Python
2. **`sonic-cfggen -d` hangs** — Use `sonic-db-cli` instead
3. **Missing `/var/log/supervisor`** — The script creates this directory and mounts it as a volume
4. **`database_config.json` format** — Uses `hostname` (not `addr`) in the `INSTANCES.redis` section
5. **Read-only volume mounts** — Edit the host file and restart the container

---

## Prerequisites

- Ubuntu 22.04+ or Debian (other distros may work with manual adjustments)
- Root/sudo privileges for dependency installation
- ~20 GB free disk space (for images + deployment)
- Docker 29.x+ with Compose plugin (auto-installed if missing)

### For Building from Source

- 100+ GB free disk space
- 10+ GB RAM (more for parallel builds)
- Multiple CPU cores
- KVM virtualization support

---

## File Structure

```
SONIC_OCS_VS_Online/
├── setup_and_deploy_vs.sh          # This script
├── deploy_vs.sh                    # Legacy deployment script
├── README.md                       # Project README
├── sonic-buildimage.vs.zip         # Pre-built image archive (5.2 GB)
├── sonic-extracted/                # Extracted build contents
│   └── sonic-buildimage.vs/
│       └── target/
│           ├── docker-gbsyncd-vs.gz
│           ├── docker-database.gz
│           ├── docker-orchagent.gz
│           ├── docker-eventd.gz
│           ├── docker-lldp.gz
│           └── ... (more images)
└── deployment/
    ├── docker-compose.yml          # Container orchestration
    ├── config/
    │   ├── config_db.json          # Device configuration
    │   ├── database_config.json    # Redis configuration
    │   └── constants.yml           # ASIC platform constants
    ├── hwsku/
    │   └── port_config.ini         # Port mapping
    └── logs/
        ├── supervisor/             # Supervisor logs
        └── redis/                  # Redis logs
```

---

## License

This script is provided as-is for SONiC VS development and testing.
