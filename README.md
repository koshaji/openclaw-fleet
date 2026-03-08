# OpenClaw Fleet Manager

Provision, manage, and monitor multiple isolated OpenClaw AI agent Docker containers on a single machine.

Each agent runs in its own Docker container with:
- Full network isolation (own bridge network, localhost-only ports)
- Own Telegram bot, config, workspace, and gateway token
- Security hardening (non-root, cap_drop ALL, no-new-privileges)
- Log rotation and resource limits
- Health monitoring with auto-restart watchdog

## Prerequisites

- **Docker Desktop** (macOS) or Docker Engine (Linux)
- **jq** — `brew install jq` (macOS) or `apt-get install jq` (Linux)
- **OpenClaw-compatible API key** (zai or other provider)
- **Telegram bot tokens** — one per agent, from [@BotFather](https://t.me/BotFather)

## Quick Start

```bash
# 1. Clone this repo
git clone <repo-url> openclaw-fleet && cd openclaw-fleet

# 2. Create 3 agents (will prompt for API provider and Telegram tokens on first run)
./fleet.sh create 3

# 3. Check status (agent names shown here — auto-assigned from a pool like scout, relay, cipher)
./fleet.sh status --deep

# 4. Pair your Telegram account with each bot (use names from status output)
./fleet.sh pair <AGENT_NAME> <CODE_FROM_TELEGRAM>
```

## Commands

| Command | Description |
|---|---|
| `create <N>` | Create N new agents |
| `status [--deep] [--json]` | Show fleet status table |
| `update [--agent <name>]` | Rolling update to latest image |
| `clone <src> <dst>` | Clone agent config to new agent |
| `destroy <name\|--all>` | Remove agent(s) |
| `restart <name\|--all>` | Restart agent(s) with staggered delay |
| `stop / start <name\|--all>` | Stop or start agent(s) |
| `logs <name> [--follow]` | View agent logs |
| `shell <name>` | Open shell in agent container |
| `reconfigure [--agent <name>]` | Re-propagate fleet config (API key, image tag) |
| `reconcile` | Sync registry with actual Docker state |
| `backup [name\|--all]` | Backup agent configs |
| `restore <file.tar.gz>` | Restore agent from backup |
| `pair <name> <code>` | Approve Telegram pairing code |
| `providers [add\|list\|remove]` | Manage AI provider subscriptions |
| `models [assign\|list]` | Assign models to agents |
| `watchdog install/uninstall` | Manage auto-restart cron job |

## Configuration

On first run, `fleet.sh` creates `.env.fleet` with:

```bash
FLEET_MANAGER_NAME=mini4         # Name of the host agent managing the fleet
FLEET_BASE_PORT=19000            # Port allocation starts here
OPENCLAW_IMAGE_TAG=latest        # Pin to a version for stability
FLEET_CPUS=1.5                   # CPU limit per agent
FLEET_MEMORY=2048M               # Memory limit per agent
```

API keys are managed separately via the provider system:
```bash
./fleet.sh providers add          # Interactive — add API keys for Anthropic, OpenAI, zai, etc.
./fleet.sh providers list         # See all configured providers and available models
./fleet.sh models assign <agent> <provider/model>  # Assign models to agents
```

### Resource Planning

| Agents | CPUs needed | Memory needed | Recommended Docker VM |
|--------|------------|---------------|----------------------|
| 1-3    | 4.5 cores  | 6 GB          | 6 CPU / 8 GB         |
| 4-8    | 12 cores   | 16 GB         | 14 CPU / 20 GB       |
| 8-20   | 30 cores   | 40 GB         | Dedicated Linux host  |

## Architecture

```
openclaw-fleet/
├── fleet.sh              # CLI entrypoint
├── lib/                  # Bash modules
│   ├── common.sh         # Logging, locking, platform detection
│   ├── ports.sh          # Port allocation + registry
│   ├── config.sh         # Config generation (jq-based)
│   ├── docker.sh         # Container lifecycle
│   └── health.sh         # Health checks + watchdog
├── .env.fleet            # Fleet-wide secrets (gitignored)
└── agents/               # Generated at runtime (gitignored)
    ├── registry.json     # Port registry + agent metadata
    └── <agent-name>/     # Per-agent directory
        ├── docker-compose.yml
        ├── .env
        ├── config/       # OpenClaw config (bind-mounted)
        └── workspace/    # Agent workspace (bind-mounted)
```

### Safety Features

- **File locking** — prevents concurrent `fleet.sh` from corrupting registry
- **Atomic JSON writes** — write to tmp, validate, then mv
- **Registry reconciliation** — syncs registry against Docker on every operation
- **Port availability checks** — verifies ports are free before allocation
- **Rolling updates** — one agent at a time with health gate
- **Auto-rollback** — reverts to previous image if update fails health check
- **Staggered restarts** — prevents thundering herd on Telegram/API
- **Log rotation** — 50MB max per agent, 3 files retained
- **Watchdog** — cron-based auto-restart of unhealthy agents

## Security

- Containers run as non-root (uid 1000)
- All capabilities dropped (`cap_drop: ALL`)
- Privilege escalation blocked (`no-new-privileges`)
- Ports bound to `127.0.0.1` only
- Docker socket NOT mounted (agents cannot escape)
- Secrets in `.env.fleet` and per-agent `.env` (both gitignored, chmod 600)
- Each agent on its own Docker bridge network

## License

MIT
