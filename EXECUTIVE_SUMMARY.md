# OpenClaw Fleet Manager — Executive Summary

## What Is It?

A command-line tool that lets you create, manage, and monitor multiple AI agents on a single machine — each running in its own isolated Docker container with its own Telegram bot.

Think of it as a control panel for a fleet of personal AI assistants: one command to spin up 10 agents, one command to update them all, one command to see who's healthy.

## The Problem It Solves

Running one OpenClaw agent is straightforward. Running several — each needing its own ports, credentials, Telegram bot, config files, and isolation from the others — becomes a manual, error-prone process. If you want agents that can't see each other's data or interfere with each other, the complexity multiplies.

The Fleet Manager reduces this to:

```
./fleet.sh create 5
```

## What It Does

### Core Operations
- **Create** — Spin up N agents with one command. Ports auto-assigned, configs auto-generated, tokens prompted once.
- **Update** — Pull the latest OpenClaw release and roll it out one agent at a time. If an agent fails health checks after update, it automatically rolls back.
- **Clone** — Duplicate an existing agent's setup into a new one (new ports, new bot, same personality/config).
- **Destroy** — Tear down one agent or all of them, with optional data preservation.

### Day-to-Day Management
- **Status** — Live dashboard showing every agent's health, ports, Telegram connection, and uptime.
- **Logs / Shell** — Tail logs or drop into a shell for any agent by name.
- **Start / Stop / Restart** — Control individual agents or the whole fleet.
- **Pair** — Approve Telegram pairing codes for any agent from the command line.

### Operational Safety
- **Watchdog** — Installs a cron job that checks every 5 minutes and auto-restarts agents that have been unhealthy for 15+ minutes.
- **Backup / Restore** — Snapshot agent configs to tarballs. Restore to a new agent with auto-allocated ports.
- **Reconcile** — If something gets out of sync (manual Docker changes, host reboot), one command rebuilds the registry from actual Docker state.
- **Reconfigure** — When you change the shared API key or image version, propagate it to all agents and rolling-restart.

## Security Model

Each agent runs in a hardened Docker container:

| Layer | Protection |
|---|---|
| User | Non-root (uid 1000) |
| Capabilities | All dropped |
| Privileges | Escalation blocked |
| Network | Own bridge network, localhost-only ports |
| Docker socket | NOT mounted — agents cannot escape |
| Secrets | Per-agent .env files, chmod 600, gitignored |
| Logs | Rotated at 50MB, max 3 files per agent |
| Resources | Configurable CPU and memory limits |

Agents cannot see each other's files, config, conversations, or network traffic.

## Technical Architecture

```
fleet.sh (CLI)
    |
    ├── lib/common.sh     Logging, locking, platform detection
    ├── lib/ports.sh      Port registry with atomic writes
    ├── lib/config.sh     jq-based config generation
    ├── lib/docker.sh     Container lifecycle + rollback
    └── lib/health.sh     Health checks + watchdog
         |
         └── agents/
             ├── registry.json   (source of truth, reconciled against Docker)
             ├── agent1/         (docker-compose + config + workspace)
             ├── agent2/
             └── ...
```

Key engineering decisions:
- **jq for all JSON** — no fragile sed/awk templating
- **File locking** — prevents concurrent runs from corrupting the registry
- **Atomic writes** — write to temp file, validate, then mv (crash-safe)
- **Rolling updates** — one agent at a time, health-gated, auto-rollback on failure
- **Staggered restarts** — prevents API rate-limiting when many agents restart together
- **Registry reconciliation** — Docker is the source of truth, not the JSON file

## Requirements

- macOS or Linux
- Docker Desktop (macOS) or Docker Engine (Linux)
- jq (JSON processor)
- One Telegram bot token per agent (from @BotFather)
- An AI model API key (zai, Anthropic, OpenAI, etc.)

## Resource Planning

| Fleet Size | CPU Needed | Memory Needed | Best For |
|---|---|---|---|
| 1–3 agents | 4.5 cores | 6 GB | Personal use, testing |
| 4–8 agents | 12 cores | 16 GB | Small team, multi-purpose |
| 8–20 agents | 30 cores | 40 GB | Dedicated server |

## What's Next

Potential future additions:
- Web dashboard for fleet monitoring
- Per-agent API keys for independent billing/revocation
- Multi-host support (fleet across multiple machines)
- Agent templates/personalities (pre-configured agent types)
- Automated Telegram bot creation via BotFather API
