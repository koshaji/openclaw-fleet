# OpenClaw Fleet Manager

[OpenClaw](https://openclaw.dev) is a self-hosted AI agent platform with multi-channel support (Telegram, web, etc.). The **Fleet Manager** lets you provision, manage, and monitor multiple isolated OpenClaw agents as Docker containers on a single machine.

Each agent runs in its own Docker container with:
- Full network isolation (own bridge network, localhost-only ports)
- Own Telegram bot, config, workspace, and gateway token
- Security hardening (non-root, cap_drop ALL, no-new-privileges)
- Log rotation and resource limits
- Health monitoring with auto-restart watchdog

## Prerequisites

- **Docker Desktop** (macOS: `brew install --cask docker`) or Docker Engine (Linux)
- **jq** — `brew install jq` (macOS) or `apt-get install jq` (Linux)
- **curl** and **openssl** (pre-installed on most systems)
- **AI provider API key** (Anthropic, OpenAI, zai, Google, etc.)
- **Telegram bot tokens** — one per agent, from [@BotFather](https://t.me/BotFather)
- *Optional:* [1Password CLI](https://1password.com/downloads/command-line/) for secret management
- *Optional:* [AgentGuard](https://agentguard.tech) for runtime policy enforcement

## Install

**One-line install (no git needed):**

```bash
curl -fsSL https://raw.githubusercontent.com/koshaji/openclaw-fleet/main/install.sh | bash
```

This installs to `~/.openclaw-fleet/`, checks for Docker and jq, and offers to install them. Then add the alias it suggests and you're ready.

To install to a custom directory:

```bash
curl -fsSL https://raw.githubusercontent.com/koshaji/openclaw-fleet/main/install.sh | bash -s -- --dir /opt/fleet
```

**Or clone the repo:**

```bash
git clone https://github.com/koshaji/openclaw-fleet && cd openclaw-fleet
```

## Quick Start

```bash
# 1. Check how many agents your machine can handle
fleet capacity

# 2. Create your first agent (will prompt for API key and Telegram token)
fleet create 1

# 3. Check status
fleet status

# 4. Pair your Telegram account (message the bot, get a code)
fleet pair <AGENT_NAME> <CODE_FROM_TELEGRAM>
```

## Commands

| Command | Description |
|---|---|
| `capacity` | Show max agents this machine can run |
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
├── fleet.sh              # CLI entrypoint (dispatcher + commands)
├── lib/                  # Bash modules
│   ├── common.sh         # Logging, locking, platform detection
│   ├── ports.sh          # Port allocation + registry CRUD
│   ├── config.sh         # Config generation (jq-based, no sed)
│   ├── docker.sh         # Container lifecycle + resource checks
│   ├── health.sh         # Health checks, status table, watchdog
│   ├── models.sh         # Provider subscriptions + model allocation
│   ├── naming.sh         # Auto-naming from pool / role-based
│   ├── secrets.sh        # 1Password integration (optional)
│   ├── agentguard.sh     # AgentGuard policy enforcement (optional)
│   └── maintain.sh       # Daily maintenance (health, backup, cleanup)
├── .env.fleet            # Fleet-wide config (gitignored)
├── agentguard.yaml       # Security policy (created on enable)
└── agents/               # Generated at runtime (gitignored)
    ├── registry.json     # Port registry + agent metadata
    ├── providers.json    # API key subscriptions
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
