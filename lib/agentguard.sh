#!/usr/bin/env bash
# agentguard.sh — Optional AgentGuard security policy enforcement

AGENTGUARD_API="https://api.agentguard.tech"
AGENTGUARD_CONFIG="${FLEET_DIR}/agentguard.yaml"

# Check if AgentGuard is configured for the fleet
agentguard_enabled() {
  [[ -f "$AGENTGUARD_CONFIG" ]] && [[ -n "${AGENTGUARD_API_KEY:-}" ]]
}

# Initialize AgentGuard default policy
init_agentguard() {
  if [[ -f "$AGENTGUARD_CONFIG" ]]; then
    return 0
  fi

  cat > "$AGENTGUARD_CONFIG" <<'YAML'
# AgentGuard Security Policy for OpenClaw Fleet
# https://docs.agentguard.tech

version: "1.0"
tenant: "openclaw-fleet"

defaults:
  action: monitor
  log: true

rules:
  # Block access to sensitive files
  - id: block-sensitive-files
    match:
      tool: "file_*"
      params:
        path: ["*.env", "*.pem", "*.key", "*credentials*", "*secrets*"]
    action: block
    reason: "Access to sensitive files blocked by policy"

  # Monitor all web requests
  - id: monitor-web
    match:
      tool: "web_*"
    action: monitor

  # Require approval for destructive operations
  - id: approve-destructive
    match:
      tool: ["shell_exec", "file_delete", "git_push"]
    action: require_approval
    reason: "Destructive operation requires approval"

  # Rate limit API calls
  - id: rate-limit-apis
    match:
      tool: "api_*"
    rate_limit:
      max: 100
      window: 60

  # PII detection on outputs
  - id: pii-scan
    match:
      direction: output
    pii_detection:
      enabled: true
      redact: true
      types: [ssn, credit_card, email, phone]
YAML

  log_ok "Created default AgentGuard policy at agentguard.yaml"
}

# Register an agent with AgentGuard
register_agent() {
  local name="$1"

  if ! agentguard_enabled; then
    return 0
  fi

  local agent_key
  local resolved_key
  resolved_key=$(resolve_secret "${AGENTGUARD_API_KEY}") || return 1
  agent_key=$(curl -sf -X POST "${AGENTGUARD_API}/api/v1/agents" \
    -H @<(echo "X-API-Key: ${resolved_key}") \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg n "$name" '{name: $n, tenant: "openclaw-fleet"}')" \
    | jq -r '.agentKey // empty' 2>/dev/null)

  if [[ -n "$agent_key" ]]; then
    local registry="${FLEET_DIR}/agents/registry.json"
    local updated
    updated=$(jq --arg name "$name" --arg key "$agent_key" \
      '.agents[$name].agentguardKey = $key' "$registry")
    atomic_json_write "$registry" "$updated"
    log_ok "Registered agent '$name' with AgentGuard"
    echo "$agent_key"
  else
    log_warn "Could not register '$name' with AgentGuard (API may be unavailable)"
  fi
}

# Deregister an agent from AgentGuard
deregister_agent() {
  local name="$1"

  if ! agentguard_enabled; then
    return 0
  fi

  local agent_key
  agent_key=$(jq -r --arg name "$name" '.agents[$name].agentguardKey // empty' \
    "${FLEET_DIR}/agents/registry.json" 2>/dev/null)

  if [[ -n "$agent_key" ]]; then
    local resolved_key
    resolved_key=$(resolve_secret "${AGENTGUARD_API_KEY}") || return 1
    curl -sf -X DELETE "${AGENTGUARD_API}/api/v1/agents/${agent_key}" \
      -H @<(echo "X-API-Key: ${resolved_key}") &>/dev/null || true
    log_info "Deregistered agent '$name' from AgentGuard"
  fi
}

# Kill switch — immediately halt an agent
kill_agent() {
  local name="$1"
  local reason="${2:-Manual kill switch activated}"

  if ! agentguard_enabled; then
    log_error "AgentGuard not configured. Use './fleet.sh stop $name' instead."
    return 1
  fi

  local agent_key
  agent_key=$(jq -r --arg name "$name" '.agents[$name].agentguardKey // empty' \
    "${FLEET_DIR}/agents/registry.json" 2>/dev/null)

  if [[ -z "$agent_key" ]]; then
    log_error "Agent '$name' not registered with AgentGuard"
    return 1
  fi

  log_warn "Activating kill switch for agent '$name'..."

  local resolved_key
  resolved_key=$(resolve_secret "${AGENTGUARD_API_KEY}") || return 1
  curl -sf -X POST "${AGENTGUARD_API}/api/v1/agents/${agent_key}/kill" \
    -H @<(echo "X-API-Key: ${resolved_key}") \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg r "$reason" '{reason: $r}')" &>/dev/null

  # Also stop the Docker container
  stop_agent "$name" 10
  registry_set_state "$name" "killed"

  log_ok "Agent '$name' killed. Reason: $reason"
}

# Get AgentGuard status for an agent
agent_security_status() {
  local name="$1"

  if ! agentguard_enabled; then
    echo "not-configured"
    return
  fi

  local agent_key
  agent_key=$(jq -r --arg name "$name" '.agents[$name].agentguardKey // empty' \
    "${FLEET_DIR}/agents/registry.json" 2>/dev/null)

  if [[ -z "$agent_key" ]]; then
    echo "not-registered"
    return
  fi

  local status
  local resolved_key
  resolved_key=$(resolve_secret "${AGENTGUARD_API_KEY}") || return 0
  status=$(curl -sf "${AGENTGUARD_API}/api/v1/agents/${agent_key}/status" \
    -H @<(echo "X-API-Key: ${resolved_key}") \
    | jq -r '.status // "unknown"' 2>/dev/null)

  echo "${status:-unknown}"
}

# Generate AgentGuard environment variables for a Docker agent
agentguard_env_vars() {
  local agent_key="$1"

  if [[ -z "$agent_key" ]]; then
    return
  fi

  cat <<ENV
AGENTGUARD_AGENT_KEY=${agent_key}
AGENTGUARD_API_URL=${AGENTGUARD_API}
AGENTGUARD_POLICY_MODE=${AGENTGUARD_POLICY_MODE:-monitor}
ENV
}
