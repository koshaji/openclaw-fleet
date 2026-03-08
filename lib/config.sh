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
      AGENTGUARD_AGENT_KEY: \${AGENTGUARD_AGENT_KEY:-}
      AGENTGUARD_API_URL: \${AGENTGUARD_API_URL:-}
    read_only: true
    tmpfs:
      - /tmp:size=100M
      - /home/node/.cache:size=50M
    volumes:
      - \${OPENCLAW_CONFIG_DIR}:/home/node/.openclaw:ro
      - \${OPENCLAW_WORKSPACE_DIR}:/home/node/.openclaw/workspace
    ports:
      - "127.0.0.1:\${OPENCLAW_GATEWAY_PORT:-${gateway_port}}:${gateway_port}"
      - "127.0.0.1:\${OPENCLAW_BRIDGE_PORT:-${bridge_port}}:${bridge_port}"
    init: true
    restart: unless-stopped
    cpus: '${cpus}'
    mem_limit: ${memory}
    pids_limit: 256
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
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

  # Add AgentGuard env if configured
  if [[ -n "${AGENTGUARD_API_KEY:-}" ]]; then
    local agent_key
    agent_key=$(jq -r --arg name "$name" '.agents[$name].agentguardKey // empty' \
      "${FLEET_DIR}/agents/registry.json" 2>/dev/null)
    cat <<ENV2
AGENTGUARD_AGENT_KEY=${agent_key}
AGENTGUARD_API_URL=${AGENTGUARD_API:-https://api.agentguard.tech}
ENV2
  fi
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

# Create agent files using provider system (v2)
# Falls back to legacy create_agent_files if no providers are configured
create_agent_files_v2() {
  local name="$1"
  local gateway_port="$2"
  local bridge_port="$3"
  local gateway_token="$4"
  local telegram_token="$5"

  local agent_dir="${FLEET_DIR}/agents/${name}"

  # Create directory structure
  mkdir -p "${agent_dir}"/{config/{identity,agents/main/agent,agents/main/sessions},workspace}

  # Check if providers.json exists and has subscriptions
  local providers_file="${FLEET_DIR}/agents/providers.json"
  if [[ -f "$providers_file" ]] && [[ "$(jq '.subscriptions | length' "$providers_file" 2>/dev/null)" -gt 0 ]]; then
    # Use provider system for model config and auth profiles
    local models_section
    models_section=$(generate_model_config "$name")

    local primary_model
    primary_model=$(get_primary_model_string "$name")

    local auth_section
    auth_section=$(generate_agent_auth_profiles "$name")

    # Build openclaw.json with provider-based models
    jq -n \
      --argjson port "$gateway_port" \
      --arg token "$gateway_token" \
      --arg tg_token "$telegram_token" \
      --argjson models "$models_section" \
      --arg primary "$primary_model" \
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
        models: $models,
        agents: {
          defaults: {
            model: { primary: $primary },
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
      }' > "${agent_dir}/config/openclaw.json"

    # Write auth profiles from provider system
    echo "$auth_section" > "${agent_dir}/config/agents/main/agent/auth-profiles.json"
  else
    # Legacy fallback: use ZAI_API_KEY from .env.fleet
    local api_key="${ZAI_API_KEY:-}"
    if [[ -z "$api_key" ]]; then
      log_error "No providers configured and ZAI_API_KEY not set. Run: ./fleet.sh providers add"
      return 1
    fi
    generate_openclaw_config "$gateway_port" "$gateway_token" "$telegram_token" \
      > "${agent_dir}/config/openclaw.json"
    local resolved_key
    resolved_key=$(resolve_secret "$api_key") || return 1
    generate_auth_profiles "$resolved_key" \
      > "${agent_dir}/config/agents/main/agent/auth-profiles.json"
  fi

  # Generate docker-compose and env (same for both paths)
  generate_compose "$name" "$gateway_port" "$bridge_port" \
    > "${agent_dir}/docker-compose.yml"

  generate_env "$name" "$gateway_port" "$bridge_port" "$gateway_token" \
    > "${agent_dir}/.env"

  chmod 600 "${agent_dir}/.env"

  log_ok "Generated config files for agent '$name'"
}

# Apply model config to a running agent (rewrites openclaw.json models + auth-profiles)
apply_model_config() {
  local name="$1"
  local agent_dir="${FLEET_DIR}/agents/${name}"

  if [[ ! -d "$agent_dir" ]]; then
    log_error "Agent '$name' directory not found"
    return 1
  fi

  local providers_file="${FLEET_DIR}/agents/providers.json"
  if [[ ! -f "$providers_file" ]] || [[ "$(jq '.subscriptions | length' "$providers_file" 2>/dev/null)" -eq 0 ]]; then
    log_error "No providers configured. Run: ./fleet.sh providers add"
    return 1
  fi

  # Generate new model config
  local models_section
  models_section=$(generate_model_config "$name")

  local primary_model
  primary_model=$(get_primary_model_string "$name")

  # Update openclaw.json — merge new models and primary model into existing config
  local config_file="${agent_dir}/config/openclaw.json"
  if [[ -f "$config_file" ]]; then
    local updated
    updated=$(jq \
      --argjson models "$models_section" \
      --arg primary "$primary_model" \
      '.models = $models | .agents.defaults.model.primary = $primary' \
      "$config_file")
    atomic_json_write "$config_file" "$updated"
  else
    log_error "Config file not found for agent '$name'"
    return 1
  fi

  # Update auth-profiles.json
  local auth_section
  auth_section=$(generate_agent_auth_profiles "$name")
  atomic_json_write "${agent_dir}/config/agents/main/agent/auth-profiles.json" "$auth_section"

  log_ok "Applied model config to agent '$name'"
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

  # Update auth profiles using provider system or legacy
  local providers_file="${FLEET_DIR}/agents/providers.json"
  if [[ -f "$providers_file" ]] && [[ "$(jq '.subscriptions | length' "$providers_file" 2>/dev/null)" -gt 0 ]]; then
    apply_model_config "$name"
  else
    local api_key="${ZAI_API_KEY:-}"
    if [[ -z "$api_key" ]]; then
      log_error "No providers configured and ZAI_API_KEY not set"
      return 1
    fi
    local resolved_key
    resolved_key=$(resolve_secret "$api_key") || return 1
    generate_auth_profiles "$resolved_key" \
      > "${agent_dir}/config/agents/main/agent/auth-profiles.json"
  fi

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
