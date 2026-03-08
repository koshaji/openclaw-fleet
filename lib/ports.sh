#!/usr/bin/env bash
# ports.sh — Port allocation with registry, availability checks, and reconciliation

# Registry file path
REGISTRY_FILE="${FLEET_DIR}/agents/registry.json"

# Initialize registry if it doesn't exist
init_registry() {
  if [[ ! -f "$REGISTRY_FILE" ]]; then
    atomic_json_write "$REGISTRY_FILE" '{
      "version": 1,
      "basePort": '"${FLEET_BASE_PORT:-19000}"',
      "imageTag": "'"${OPENCLAW_IMAGE_TAG:-latest}"'",
      "agents": {}
    }'
    log_info "Created new registry at $REGISTRY_FILE"
  fi
}

# Read a value from registry
registry_get() {
  jq -r "$1" "$REGISTRY_FILE" 2>/dev/null
}

# Get list of agent names from registry
registry_list_agents() {
  jq -r '.agents | keys[]' "$REGISTRY_FILE" 2>/dev/null
}

# Get agent info from registry
registry_get_agent() {
  local name="$1"
  jq -r ".agents[\"$name\"]" "$REGISTRY_FILE" 2>/dev/null
}

# Allocate the next available port pair
allocate_ports() {
  local base_port
  base_port=$(registry_get '.basePort')
  local gateway_port=""
  local bridge_port=""

  # Collect all ports currently in use by the fleet
  local used_ports
  used_ports=$(jq -r '.agents[].gatewayPort, .agents[].bridgePort' "$REGISTRY_FILE" 2>/dev/null | sort -n)

  # Find next available pair starting from base
  local candidate=$base_port
  while true; do
    gateway_port=$candidate
    bridge_port=$((candidate + 1))

    # Check not in registry
    local in_registry=false
    for p in $used_ports; do
      if [[ "$p" == "$gateway_port" ]] || [[ "$p" == "$bridge_port" ]]; then
        in_registry=true
        break
      fi
    done

    if [[ "$in_registry" == "false" ]]; then
      # Check actually free on the host
      if port_is_free "$gateway_port" && port_is_free "$bridge_port"; then
        break
      else
        log_warn "Ports $gateway_port/$bridge_port in use on host, skipping..."
      fi
    fi

    candidate=$((candidate + 2))

    # Safety: don't scan forever
    if [[ $candidate -gt $((base_port + 1000)) ]]; then
      log_fatal "Could not find free port pair in range ${base_port}-$((base_port + 1000))"
    fi
  done

  echo "${gateway_port}:${bridge_port}"
}

# Add agent to registry
registry_add_agent() {
  local name="$1"
  local gateway_port="$2"
  local bridge_port="$3"
  local telegram_bot="${4:-}"
  local gateway_token="$5"

  local updated
  updated=$(jq \
    --arg name "$name" \
    --argjson gp "$gateway_port" \
    --argjson bp "$bridge_port" \
    --arg bot "$telegram_bot" \
    --arg token "$gateway_token" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg state "running" \
    '.agents[$name] = {
      gatewayPort: $gp,
      bridgePort: $bp,
      telegramBot: $bot,
      gatewayToken: $token,
      created: $created,
      state: $state
    }' "$REGISTRY_FILE")

  atomic_json_write "$REGISTRY_FILE" "$updated"
}

# Remove agent from registry
registry_remove_agent() {
  local name="$1"
  local updated
  updated=$(jq --arg name "$name" 'del(.agents[$name])' "$REGISTRY_FILE")
  atomic_json_write "$REGISTRY_FILE" "$updated"
}

# Update agent state in registry
registry_set_state() {
  local name="$1"
  local state="$2"
  local updated
  updated=$(jq --arg name "$name" --arg state "$state" \
    '.agents[$name].state = $state' "$REGISTRY_FILE")
  atomic_json_write "$REGISTRY_FILE" "$updated"
}

# Get next available agent name with given prefix
next_agent_name() {
  local prefix="${1:-agent}"
  local i=1
  while true; do
    local candidate="${prefix}${i}"
    if [[ "$(registry_get_agent "$candidate")" == "null" ]]; then
      echo "$candidate"
      return
    fi
    i=$((i + 1))
  done
}

# Reconcile registry against actual Docker state
reconcile_registry() {
  log_info "Reconciling registry against Docker state..."
  local changes=0

  for name in $(registry_list_agents); do
    local container="openclaw_${name}"
    local docker_state
    docker_state=$(docker inspect "$container" --format '{{.State.Status}}' 2>/dev/null || echo "missing")

    local registry_state
    registry_state=$(jq -r ".agents[\"$name\"].state" "$REGISTRY_FILE")

    if [[ "$docker_state" == "missing" ]] && [[ "$registry_state" == "running" ]]; then
      log_warn "Agent '$name' in registry as 'running' but container not found. Marking as stopped."
      registry_set_state "$name" "stopped"
      changes=$((changes + 1))
    elif [[ "$docker_state" == "running" ]] && [[ "$registry_state" != "running" ]]; then
      log_info "Agent '$name' container is running but registry says '$registry_state'. Updating."
      registry_set_state "$name" "running"
      changes=$((changes + 1))
    elif [[ "$docker_state" == "exited" ]] && [[ "$registry_state" == "running" ]]; then
      log_warn "Agent '$name' container exited. Marking as stopped."
      registry_set_state "$name" "stopped"
      changes=$((changes + 1))
    fi
  done

  # Discover orphan containers (fleet containers not in registry)
  local fleet_containers
  fleet_containers=$(docker ps -a --filter "name=openclaw_" --format '{{.Names}}' 2>/dev/null || true)
  for container in $fleet_containers; do
    local agent_name="${container#openclaw_}"
    if [[ "$(registry_get_agent "$agent_name")" == "null" ]]; then
      log_warn "Orphan container '$container' found (not in registry). Run 'fleet.sh destroy $agent_name' to clean up."
    fi
  done

  if [[ $changes -eq 0 ]]; then
    log_ok "Registry is in sync with Docker."
  else
    log_info "Reconciled $changes agent(s)."
  fi
}
