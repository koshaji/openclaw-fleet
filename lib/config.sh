#!/usr/bin/env bash
# config.sh — Config generation using jq (not sed), secret propagation

# Generate openclaw.json for an agent using jq
generate_openclaw_config() {
  local gateway_port="$1"
  local gateway_token="$2"
  local telegram_token="$3"

  jq -n \
    --argjson port "$gateway_port" \
    --arg token "$gateway_token" \
    --arg tg_token "$telegram_token" \
    '{
      gateway: {
        port: $port,
        mode: "local",
        bind: "lan",
        controlUi: {
          allowedOrigins: [
            ("http://localhost:" + ($port | tostring)),
            ("http://127.0.0.1:" + ($port | tostring))
          ]
        },
        auth: {
          mode: "token",
          token: $token
        }
      },
      models: {
        mode: "merge",
        providers: {
          zai: {
            baseUrl: "https://api.z.ai/api/coding/paas/v4",
            api: "openai-completions",
            models: [
              {
                id: "glm-5",
                name: "GLM-5",
                reasoning: true,
                input: ["text"],
                cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
                contextWindow: 204800,
                maxTokens: 131072
              }
            ]
          }
        }
      },
      auth: {
        profiles: {
          "zai:default": {
            provider: "zai",
            mode: "api_key"
          }
        }
      },
      agents: {
        defaults: {
          model: { primary: "zai/glm-5" },
          workspace: "/home/node/.openclaw/workspace",
          compaction: { mode: "safeguard" },
          maxConcurrent: 4
        }
      },
      channels: {
        telegram: {
          enabled: true,
          dmPolicy: "pairing",
          botToken: $tg_token,
          groupPolicy: "allowlist",
          streaming: "partial"
        }
      },
      browser: {
        headless: true,
        noSandbox: true
      }
    }'
}

# Generate auth-profiles.json
generate_auth_profiles() {
  local api_key="$1"

  jq -n \
    --arg key "$api_key" \
    '{
      version: 1,
      profiles: {
        "zai:default": {
          type: "api_key",
          provider: "zai",
          key: $key
        }
      }
    }'
}

# Generate docker-compose.yml for an agent
generate_compose() {
  local name="$1"
  local gateway_port="$2"
  local bridge_port="$3"
  local cpus="${FLEET_CPUS:-1.5}"
  local memory="${FLEET_MEMORY:-2048M}"
  local image="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:${OPENCLAW_IMAGE_TAG:-latest}}"

  cat <<YAML
services:
  openclaw-gateway:
    image: ${image}
    container_name: openclaw_${name}
    user: "1000:1000"
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    networks:
      - openclaw_net
    environment:
      HOME: /home/node
      TERM: xterm-256color
      OPENCLAW_GATEWAY_TOKEN: \${OPENCLAW_GATEWAY_TOKEN}
    volumes:
      - \${OPENCLAW_CONFIG_DIR}:/home/node/.openclaw
      - \${OPENCLAW_WORKSPACE_DIR}:/home/node/.openclaw/workspace
    ports:
      - "127.0.0.1:\${OPENCLAW_GATEWAY_PORT:-${gateway_port}}:${gateway_port}"
      - "127.0.0.1:\${OPENCLAW_BRIDGE_PORT:-${bridge_port}}:${bridge_port}"
    init: true
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
    deploy:
      resources:
        limits:
          cpus: '${cpus}'
          memory: ${memory}
    command:
      [
        "node",
        "dist/index.js",
        "gateway",
        "--bind",
        "lan",
        "--port",
        "${gateway_port}",
      ]
    healthcheck:
      test:
        [
          "CMD",
          "node",
          "-e",
          "fetch('http://127.0.0.1:${gateway_port}/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))",
        ]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s

  openclaw-cli:
    image: ${image}
    network_mode: "service:openclaw-gateway"
    cap_drop:
      - NET_RAW
      - NET_ADMIN
    security_opt:
      - no-new-privileges:true
    environment:
      HOME: /home/node
      TERM: xterm-256color
      OPENCLAW_GATEWAY_TOKEN: \${OPENCLAW_GATEWAY_TOKEN}
      BROWSER: echo
    volumes:
      - \${OPENCLAW_CONFIG_DIR}:/home/node/.openclaw
      - \${OPENCLAW_WORKSPACE_DIR}:/home/node/.openclaw/workspace
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "2"
    stdin_open: true
    tty: true
    init: true
    entrypoint: ["node", "dist/index.js"]
    depends_on:
      - openclaw-gateway

networks:
  openclaw_net:
    driver: bridge
YAML
}

# Generate per-agent .env file
generate_env() {
  local name="$1"
  local gateway_port="$2"
  local bridge_port="$3"
  local gateway_token="$4"
  local agent_dir="${FLEET_DIR}/agents/${name}"

  cat <<ENV
OPENCLAW_CONFIG_DIR=${agent_dir}/config
OPENCLAW_WORKSPACE_DIR=${agent_dir}/workspace
OPENCLAW_GATEWAY_PORT=${gateway_port}
OPENCLAW_BRIDGE_PORT=${bridge_port}
OPENCLAW_GATEWAY_TOKEN=${gateway_token}
ENV
}

# Create full agent directory structure and config files
create_agent_files() {
  local name="$1"
  local gateway_port="$2"
  local bridge_port="$3"
  local gateway_token="$4"
  local telegram_token="$5"
  local api_key="$6"

  local agent_dir="${FLEET_DIR}/agents/${name}"

  # Create directory structure
  mkdir -p "${agent_dir}"/{config/{identity,agents/main/agent,agents/main/sessions},workspace}

  # Generate all config files using jq
  generate_openclaw_config "$gateway_port" "$gateway_token" "$telegram_token" \
    > "${agent_dir}/config/openclaw.json"

  generate_auth_profiles "$api_key" \
    > "${agent_dir}/config/agents/main/agent/auth-profiles.json"

  generate_compose "$name" "$gateway_port" "$bridge_port" \
    > "${agent_dir}/docker-compose.yml"

  generate_env "$name" "$gateway_port" "$bridge_port" "$gateway_token" \
    > "${agent_dir}/.env"

  chmod 600 "${agent_dir}/.env"

  log_ok "Generated config files for agent '$name'"
}

# Propagate fleet-wide settings to an existing agent
propagate_config() {
  local name="$1"
  local agent_dir="${FLEET_DIR}/agents/${name}"

  if [[ ! -d "$agent_dir" ]]; then
    log_error "Agent '$name' directory not found"
    return 1
  fi

  # Re-read fleet config
  source_fleet_env

  local api_key="${ZAI_API_KEY}"
  if [[ -z "$api_key" ]]; then
    log_error "ZAI_API_KEY not set in .env.fleet"
    return 1
  fi

  # Update auth-profiles with current API key
  generate_auth_profiles "$api_key" \
    > "${agent_dir}/config/agents/main/agent/auth-profiles.json"

  # Update image tag in docker-compose.yml
  local agent_info
  agent_info=$(registry_get_agent "$name")
  local gw_port
  gw_port=$(echo "$agent_info" | jq -r '.gatewayPort')
  local br_port
  br_port=$(echo "$agent_info" | jq -r '.bridgePort')

  generate_compose "$name" "$gw_port" "$br_port" \
    > "${agent_dir}/docker-compose.yml"

  log_ok "Propagated fleet config to agent '$name'"
}

# Source the fleet env file
source_fleet_env() {
  local fleet_env="${FLEET_DIR}/.env.fleet"
  if [[ -f "$fleet_env" ]]; then
    # shellcheck disable=SC1090
    source "$fleet_env"
  fi
}
