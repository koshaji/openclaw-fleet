---
name: fleet-manager
description: "Manage the OpenClaw Docker agent fleet. Use when: checking fleet health, creating/destroying agents, diagnosing issues, updating agents, managing providers/models, running maintenance, or when the user asks about their agents. This is the primary skill for fleet operations."
metadata: { "openclaw": { "emoji": "🚢", "requires": { "bins": ["docker", "jq", "bc"] } } }
---

# Fleet Manager Skill

You are the fleet commander. You manage a fleet of containerized OpenClaw AI agents using the fleet CLI at `~/openclaw-fleet/fleet.sh`.

## Architecture

```
You (bare-metal manager agent)
  ├── fleet.sh CLI — your primary tool
  └── Container agents (Docker)
       ├── Each runs in isolated Docker container
       ├── Read-only rootfs, non-root, cap_drop ALL
       ├── Own Telegram bot, own ports, own config
       └── Managed via docker-compose per agent
```

**Key files:**
- `~/openclaw-fleet/.env.fleet` — fleet-wide settings (ports, limits, image tag)
- `~/openclaw-fleet/agents/registry.json` — agent registry (state, ports, tokens)
- `~/openclaw-fleet/agents/providers.json` — AI provider subscriptions and model allocations
- `~/openclaw-fleet/agents/<name>/config/openclaw.json` — per-agent OpenClaw config
- `~/openclaw-fleet/agents/<name>/.env` — per-agent Docker env (sensitive, chmod 600)

## When to Use

✅ **USE this skill when:**
- User asks about agent health, status, or fleet state
- Heartbeat check (run `fleet doctor`)
- Creating, destroying, cloning, or restarting agents
- Updating the fleet to a new OpenClaw image
- Managing AI providers or model assignments
- Diagnosing agent issues (unhealthy, stopped, network errors)
- Backup, restore, or maintenance tasks
- Capacity planning ("can I add more agents?")

❌ **DON'T use this skill when:**
- User asks about tasks their agents are doing (that's the agents' business, not fleet ops)
- General questions unrelated to infrastructure

## Command Reference

### Diagnostics (start here for any issue)

```bash
# Full diagnostic + auto-heal (the go-to command)
~/openclaw-fleet/fleet.sh doctor

# Diagnose only, don't fix anything
~/openclaw-fleet/fleet.sh doctor --no-fix

# Quick status table
~/openclaw-fleet/fleet.sh status

# Deep status with Telegram connectivity check
~/openclaw-fleet/fleet.sh status --deep

# Machine-readable status
~/openclaw-fleet/fleet.sh status --json
```

**`fleet doctor` checks 28 points:**
1. System deps (Docker, jq, bc, openssl, disk)
2. Fleet config (env, registry, providers, stale locks)
3. Manager agent (gateway, HTTP health, Telegram, workspace files, tool profile)
4. AI provider connectivity (tests each API with actual auth)
5. Container agents (health, restart dead ones, sync registry, Telegram)
6. Automation (watchdog/maintain cron, backup freshness)
7. Resources (Docker disk, dangling images, capacity)

**Self-healing:** doctor auto-fixes permissions, starts stopped agents, restarts unresponsive ones, removes stale locks, creates missing workspace files, prunes Docker images, and syncs registry state.

### Agent Lifecycle

```bash
# Create agents (interactive — asks for Telegram token and name)
~/openclaw-fleet/fleet.sh create <N>

# Create with specific name and model
~/openclaw-fleet/fleet.sh create 1 --name scout --model zai/glm-5

# Create with pre-supplied Telegram tokens
~/openclaw-fleet/fleet.sh create 3 --telegram-tokens tokens.txt

# Clone an agent (copies config, not sessions)
~/openclaw-fleet/fleet.sh clone <source> <target>
~/openclaw-fleet/fleet.sh clone <source> <target> --config-only

# Destroy
~/openclaw-fleet/fleet.sh destroy <name>
~/openclaw-fleet/fleet.sh destroy --all --force

# Start / stop / restart
~/openclaw-fleet/fleet.sh start <name|--all>
~/openclaw-fleet/fleet.sh stop <name|--all>
~/openclaw-fleet/fleet.sh restart <name|--all>
```

### Updates

```bash
# Rolling update all agents to latest image
~/openclaw-fleet/fleet.sh update

# Update a single agent
~/openclaw-fleet/fleet.sh update --agent <name>
```

The update flow: pull new image → tag old as `:rollback` → stop agent → start with new image → health check → if unhealthy, auto-rollback. If one agent fails during fleet-wide update, remaining agents are NOT updated (safe halt).

### Provider & Model Management

```bash
# List subscriptions and available models
~/openclaw-fleet/fleet.sh providers list

# Add a new provider (interactive)
~/openclaw-fleet/fleet.sh providers add

# Non-interactive add
~/openclaw-fleet/fleet.sh providers add <name> <type> <api_key> [label] [base_url]
# Types: anthropic, openai, google, zai, ollama, openrouter

# Remove a provider
~/openclaw-fleet/fleet.sh providers remove <name>

# Assign models to an agent
~/openclaw-fleet/fleet.sh models assign <agent> <subscription/model>
~/openclaw-fleet/fleet.sh models assign scout zai/glm-5

# List current allocations
~/openclaw-fleet/fleet.sh models list
```

### Operations

```bash
# View logs
~/openclaw-fleet/fleet.sh logs <name> --tail 100
~/openclaw-fleet/fleet.sh logs <name> --follow

# Shell into a container
~/openclaw-fleet/fleet.sh shell <name>

# Re-propagate fleet config to all agents
~/openclaw-fleet/fleet.sh reconfigure

# Sync registry with Docker state
~/openclaw-fleet/fleet.sh reconcile

# Pair Telegram
~/openclaw-fleet/fleet.sh pair <name> <code>

# Capacity
~/openclaw-fleet/fleet.sh capacity
```

### Backup & Maintenance

```bash
# Manual backup
~/openclaw-fleet/fleet.sh backup --all
~/openclaw-fleet/fleet.sh backup <name>

# Restore from backup
~/openclaw-fleet/fleet.sh restore <backup.tar.gz>

# Run full maintenance (health + updates check + cleanup + backup + security)
~/openclaw-fleet/fleet.sh maintain run

# Install/uninstall cron jobs
~/openclaw-fleet/fleet.sh watchdog install    # health checks every 5 min
~/openclaw-fleet/fleet.sh maintain install    # daily maintenance at 4 AM
```

### Security

```bash
# 1Password integration
~/openclaw-fleet/fleet.sh secrets status
~/openclaw-fleet/fleet.sh secrets migrate    # move plaintext keys to 1Password

# AgentGuard policy enforcement
~/openclaw-fleet/fleet.sh agentguard enable
~/openclaw-fleet/fleet.sh agentguard status
~/openclaw-fleet/fleet.sh agentguard kill <name> "reason"
```

## Decision Guide

### Heartbeat Flow

On every heartbeat, run:
```bash
~/openclaw-fleet/fleet.sh doctor
```

- If all checks pass → reply `HEARTBEAT_OK`
- If auto-fixed items exist (⚡) → reply `HEARTBEAT_OK` and briefly mention what was fixed
- If unfixed issues (✗) remain → notify the user with the specific issue

### Agent is unhealthy

1. `fleet doctor` (auto-restarts unhealthy agents)
2. If still unhealthy: `fleet logs <name> --tail 50` to check errors
3. Common causes:
   - **network_error** → AI provider API is down or rate limited. Check: `fleet doctor` tests providers. Usually transient — wait and retry.
   - **OOM killed** → agent needs more memory. Edit `.env.fleet`, increase `FLEET_MEMORY`, then `fleet reconfigure`
   - **Telegram disconnected** → bot token may be revoked. Check with BotFather.
   - **Container exited** → `fleet logs <name> --tail 20` for crash reason, then `fleet restart <name>`

### Agent won't start

1. Check `fleet logs <name> --tail 20`
2. Check port conflict: `lsof -i :<port>` (port shown in `fleet status`)
3. Check disk space: `df -h`
4. Check Docker: `docker info`
5. If config is corrupt: destroy and recreate, or restore from backup

### Provider API errors

1. `fleet doctor` tests each provider's API connectivity
2. If 401 → API key is wrong or expired. Update with `fleet providers remove <name>` then `fleet providers add`
3. If 429 → rate limited. Wait, or add a second provider as fallback
4. If 000 (unreachable) → network issue. Check DNS, firewall, VPN

### Scaling up

1. `fleet capacity` — shows how many more agents fit
2. If at capacity, options:
   - Reduce per-agent resources: edit `FLEET_CPUS` / `FLEET_MEMORY` in `.env.fleet`
   - Remove unused agents: `fleet destroy <name>`
   - Use a bigger machine

### Scaling down

1. `fleet stop <name>` — keeps config, just stops container
2. `fleet destroy <name>` — removes everything
3. `fleet destroy <name> --keep-data` — removes container but keeps config for later

## Security Notes

- All containers: read-only rootfs, non-root (uid 1000), `cap_drop: ALL`, `no-new-privileges`
- Config mounted read-only inside containers
- Ports bound to 127.0.0.1 only (not exposed to network)
- API keys in `providers.json` (chmod 600). Migrate to 1Password with `fleet secrets migrate`
- `.env` files per agent are chmod 600
- `umask 077` enforced globally in fleet CLI

## Troubleshooting Quick Reference

| Symptom | Command | Fix |
|---------|---------|-----|
| Agent unhealthy | `fleet doctor` | Auto-restarts |
| Agent stopped | `fleet doctor` | Auto-starts |
| network_error | `fleet doctor` | Check provider section, usually transient |
| Telegram disconnected | `fleet status --deep` | Check bot token with BotFather |
| Stale lock | `fleet doctor` | Auto-removes stale locks |
| Missing MEMORY.md | `fleet doctor` | Auto-creates |
| Gateway down | `fleet doctor` | Auto-starts/restarts gateway |
| Disk full | `fleet maintain run` | Prunes images, rotates logs |
| Out of capacity | `fleet capacity` | Scale down or adjust limits |
| Config drift | `fleet reconfigure` | Re-propagates fleet config |
| Corrupt registry | `fleet reconcile` | Syncs with Docker state |
| Provider down | `fleet doctor` | Tests each provider, reports status |

## Emergency Procedures

### Kill switch (AgentGuard)
```bash
~/openclaw-fleet/fleet.sh agentguard kill <name> "reason"
```
Immediately stops the agent and marks it as killed. Requires AgentGuard to be enabled.

### Emergency stop all
```bash
~/openclaw-fleet/fleet.sh stop --all
```

### Full fleet reset
```bash
# Backup first!
~/openclaw-fleet/fleet.sh backup --all
# Then destroy
~/openclaw-fleet/fleet.sh destroy --all --force
```
