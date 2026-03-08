#!/usr/bin/env bash
# docker.sh — Docker image management, container lifecycle

# Pull the OpenClaw image, tag current as rollback before pulling new
pull_image() {
  local image="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw}"
  local tag="${OPENCLAW_IMAGE_TAG:-latest}"
  local full="${image}:${tag}"

  # Tag current image as rollback before pulling
  if docker image inspect "$full" &>/dev/null; then
    log_info "Tagging current image as rollback..."
    docker tag "$full" "${image}:rollback" 2>/dev/null || true
  fi

  log_info "Pulling image: $full"
  if ! docker pull "$full" 2>&1; then
    log_error "Failed to pull $full"
    return 1
  fi

  # Verify image digest if pinned
  local expected_digest="${OPENCLAW_IMAGE_DIGEST:-}"
  if [[ -n "$expected_digest" ]]; then
    local actual_digest
    actual_digest=$(docker image inspect "$full" --format '{{index .RepoDigests 0}}' 2>/dev/null | grep -o 'sha256:[a-f0-9]*' || true)
    if [[ -z "$actual_digest" ]]; then
      log_warn "Could not retrieve image digest for verification"
    elif [[ "$actual_digest" != "$expected_digest" ]]; then
      log_error "Image digest mismatch!"
      log_error "  Expected: $expected_digest"
      log_error "  Got:      $actual_digest"
      log_error "Rolling back to previous image..."
      rollback_image
      return 1
    else
      log_ok "Image digest verified: ${actual_digest:0:19}..."
    fi
  fi

  log_ok "Image pulled: $full"
}

# Rollback to previous image
rollback_image() {
  local image="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw}"
  local tag="${OPENCLAW_IMAGE_TAG:-latest}"
  local full="${image}:${tag}"
  local rollback="${image}:rollback"

  if docker image inspect "$rollback" &>/dev/null; then
    log_info "Rolling back to previous image..."
    docker tag "$rollback" "$full"
    log_ok "Rolled back to previous image"
  else
    log_error "No rollback image available"
    return 1
  fi
}

# Start an agent's containers
start_agent() {
  local name="$1"
  local agent_dir="${FLEET_DIR}/agents/${name}"

  if [[ ! -f "${agent_dir}/docker-compose.yml" ]]; then
    log_error "No docker-compose.yml found for agent '$name'"
    return 1
  fi

  log_info "Starting agent '$name'..."

  # Ensure workspace is writable by container user (uid 1000)
  # Config dir is mounted read-only so no chown needed there
  chmod -R u+rw "${agent_dir}/workspace" 2>/dev/null || true

  docker compose -f "${agent_dir}/docker-compose.yml" \
    --env-file "${agent_dir}/.env" \
    -p "openclaw-${name}" \
    up -d openclaw-gateway 2>&1

  log_ok "Agent '$name' started"
}

# Stop an agent gracefully
stop_agent() {
  local name="$1"
  local timeout="${2:-30}"
  local agent_dir="${FLEET_DIR}/agents/${name}"

  if [[ ! -f "${agent_dir}/docker-compose.yml" ]]; then
    log_warn "No compose file for agent '$name', trying direct container stop"
    docker stop --time "$timeout" "openclaw_${name}" 2>/dev/null || true
    return
  fi

  log_info "Stopping agent '$name' (timeout: ${timeout}s)..."
  docker compose -f "${agent_dir}/docker-compose.yml" \
    --env-file "${agent_dir}/.env" \
    -p "openclaw-${name}" \
    stop --timeout "$timeout" 2>&1 || true

  log_ok "Agent '$name' stopped"
}

# Destroy an agent's containers and network
destroy_agent_containers() {
  local name="$1"
  local agent_dir="${FLEET_DIR}/agents/${name}"

  if [[ -f "${agent_dir}/docker-compose.yml" ]]; then
    docker compose -f "${agent_dir}/docker-compose.yml" \
      --env-file "${agent_dir}/.env" \
      -p "openclaw-${name}" \
      down --remove-orphans 2>&1 || true
  else
    docker rm -f "openclaw_${name}" 2>/dev/null || true
  fi
}

# Restart an agent
restart_agent() {
  local name="$1"
  local agent_dir="${FLEET_DIR}/agents/${name}"

  if [[ ! -f "${agent_dir}/docker-compose.yml" ]]; then
    log_error "No docker-compose.yml found for agent '$name'"
    return 1
  fi

  docker compose -f "${agent_dir}/docker-compose.yml" \
    --env-file "${agent_dir}/.env" \
    -p "openclaw-${name}" \
    restart 2>&1

  log_ok "Agent '$name' restarted"
}

# Run a CLI command inside an agent's container
agent_cli() {
  local name="$1"
  shift
  local agent_dir="${FLEET_DIR}/agents/${name}"

  docker compose -f "${agent_dir}/docker-compose.yml" \
    --env-file "${agent_dir}/.env" \
    -p "openclaw-${name}" \
    run --rm openclaw-cli "$@" 2>&1
}

# Run a CLI command via exec on running gateway
agent_exec() {
  local name="$1"
  shift
  local agent_dir="${FLEET_DIR}/agents/${name}"

  docker compose -f "${agent_dir}/docker-compose.yml" \
    --env-file "${agent_dir}/.env" \
    -p "openclaw-${name}" \
    exec openclaw-gateway node dist/index.js "$@" 2>&1
}

# Check available Docker resources
check_resources() {
  local requested_agents="$1"
  local cpus_per="${FLEET_CPUS:-1.5}"
  local mem_per="${FLEET_MEMORY:-2048M}"

  # Strip M/G suffix for calculation
  local mem_mb
  mem_mb=$(echo "$mem_per" | sed 's/[MmGg]//;s/$//')
  if echo "$mem_per" | grep -qi 'g'; then
    mem_mb=$((mem_mb * 1024))
  fi

  local total_cpus_needed
  total_cpus_needed=$(echo "$requested_agents * $cpus_per" | bc 2>/dev/null || echo "?")
  local total_mem_needed
  total_mem_needed=$((requested_agents * mem_mb))

  local existing_count
  existing_count=$(registry_list_agents 2>/dev/null | wc -l | tr -d ' ')

  local total_agents=$((existing_count + requested_agents))
  local total_mem=$((total_agents * mem_mb))

  log_info "Resource estimate for $total_agents total agents:"
  log_info "  CPUs: ~${total_cpus_needed} cores needed"
  log_info "  Memory: ~$((total_mem / 1024))GB needed (${mem_per} per agent)"

  if [[ $total_mem -gt 16384 ]]; then
    log_warn "Total memory exceeds 16GB. Ensure Docker Desktop VM has sufficient allocation."
  fi
}

# Check disk space
check_disk_space() {
  local min_gb="${1:-5}"
  local available_kb
  if [[ "$PLATFORM" == "darwin" ]]; then
    available_kb=$(df -k "${FLEET_DIR}" | tail -1 | awk '{print $4}')
  else
    available_kb=$(df -k "${FLEET_DIR}" | tail -1 | awk '{print $4}')
  fi
  local available_gb=$((available_kb / 1024 / 1024))

  if [[ $available_gb -lt $min_gb ]]; then
    log_fatal "Only ${available_gb}GB disk space available. Need at least ${min_gb}GB."
  fi
}
