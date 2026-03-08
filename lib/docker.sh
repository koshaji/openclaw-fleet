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
  if [[ "${PLATFORM:-}" == "linux" ]]; then
    chown -R 1000:1000 "${agent_dir}/workspace" 2>/dev/null || true
  fi
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

# Parse memory string (e.g., "2048M" or "4G") to MB
parse_mem_mb() {
  local mem_str="$1"
  local num
  num=$(echo "$mem_str" | sed 's/[MmGg]//')
  if echo "$mem_str" | grep -qi 'g'; then
    echo $((num * 1024))
  else
    echo "$num"
  fi
}

# Detect hardware capacity (CPUs and RAM)
detect_hardware() {
  local hw_cpus=0
  local hw_mem_mb=0

  if [[ "${PLATFORM:-}" == "darwin" ]]; then
    hw_cpus=$(sysctl -n hw.ncpu 2>/dev/null || echo 0)
    local hw_mem_bytes
    hw_mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    hw_mem_mb=$((hw_mem_bytes / 1024 / 1024))
  else
    hw_cpus=$(nproc 2>/dev/null || echo 0)
    hw_mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
  fi

  echo "${hw_cpus}:${hw_mem_mb}"
}

# Calculate max agents this machine can run
max_agents() {
  local cpus_per="${FLEET_CPUS:-1.5}"
  local mem_per_mb
  mem_per_mb=$(parse_mem_mb "${FLEET_MEMORY:-2048M}")

  local hw
  hw=$(detect_hardware)
  local hw_cpus="${hw%%:*}"
  local hw_mem_mb="${hw##*:}"

  if [[ "$hw_cpus" -eq 0 ]] || [[ "$hw_mem_mb" -eq 0 ]]; then
    echo "0:0:0"
    return
  fi

  # Use bc for float division, truncate to integer
  local max_by_cpu
  max_by_cpu=$(echo "$hw_cpus / $cpus_per" | bc 2>/dev/null || echo 0)
  max_by_cpu="${max_by_cpu%%.*}"
  local max_by_mem=$((hw_mem_mb / mem_per_mb))

  # Use the smaller limit
  local max=$max_by_cpu
  if [[ $max_by_mem -lt $max ]]; then
    max=$max_by_mem
  fi

  # Reserve ~25% for OS/Docker overhead
  local recommended=$(( (max * 3) / 4 ))
  if [[ $recommended -lt 1 ]] && [[ $max -ge 1 ]]; then
    recommended=1
  fi

  echo "${max}:${recommended}:${hw_cpus}:${hw_mem_mb}"
}

# Show hardware capacity report
show_capacity() {
  local cpus_per="${FLEET_CPUS:-1.5}"
  local mem_per="${FLEET_MEMORY:-2048M}"
  local mem_per_mb
  mem_per_mb=$(parse_mem_mb "$mem_per")

  local result
  result=$(max_agents)
  local max="${result%%:*}"
  local rest="${result#*:}"
  local recommended="${rest%%:*}"
  rest="${rest#*:}"
  local hw_cpus="${rest%%:*}"
  local hw_mem_mb="${rest##*:}"

  local existing_count
  existing_count=$(registry_list_agents 2>/dev/null | wc -l | tr -d ' ')
  local remaining=$((recommended - existing_count))
  if [[ $remaining -lt 0 ]]; then remaining=0; fi

  echo ""
  echo -e "${BOLD}Hardware Capacity${NC}"
  echo "  CPUs:       ${hw_cpus} cores"
  echo "  Memory:     $((hw_mem_mb / 1024)) GB"
  echo ""
  echo -e "${BOLD}Per-Agent Limits${NC}"
  echo "  CPUs:       ${cpus_per} cores"
  echo "  Memory:     ${mem_per}"
  echo ""
  echo -e "${BOLD}Fleet Capacity${NC}"
  echo "  Maximum:    ${max} agents (hardware limit)"
  echo "  Recommended: ${recommended} agents (with 25% OS/Docker headroom)"
  echo "  Running:    ${existing_count} agents"
  echo "  Available:  ${remaining} more agents"

  if [[ "${PLATFORM:-}" == "darwin" ]]; then
    echo ""
    log_info "On macOS, Docker Desktop runs in a VM. Check Docker Desktop > Settings > Resources"
    log_info "to see the actual CPU/memory allocated to Docker."
  fi
  echo ""
}

# Check available Docker resources
check_resources() {
  local requested_agents="$1"
  local cpus_per="${FLEET_CPUS:-1.5}"
  local mem_per_mb
  mem_per_mb=$(parse_mem_mb "${FLEET_MEMORY:-2048M}")

  local existing_count
  existing_count=$(registry_list_agents 2>/dev/null | wc -l | tr -d ' ')
  local total_agents=$((existing_count + requested_agents))

  local total_cpus_needed
  total_cpus_needed=$(echo "$total_agents * $cpus_per" | bc 2>/dev/null || echo "?")
  local total_mem_mb=$((total_agents * mem_per_mb))

  log_info "Resource estimate for $total_agents total agents:"
  log_info "  CPUs: ~${total_cpus_needed} cores"
  log_info "  Memory: ~$((total_mem_mb / 1024))GB (${FLEET_MEMORY:-2048M} per agent)"

  # Check against actual hardware
  local result
  result=$(max_agents)
  local recommended
  recommended=$(echo "$result" | cut -d: -f2)

  if [[ "$recommended" -gt 0 ]] && [[ $total_agents -gt $recommended ]]; then
    log_warn "This machine is recommended for ~${recommended} agents at current settings."
    log_warn "You're requesting ${total_agents} total. Run './fleet.sh capacity' for details."
  fi
}

# Check disk space
check_disk_space() {
  local min_gb="${1:-5}"
  local available_kb
  available_kb=$(df -k "${FLEET_DIR}" | tail -1 | awk '{print $4}')
  local available_gb=$((available_kb / 1024 / 1024))

  if [[ $available_gb -lt $min_gb ]]; then
    log_fatal "Only ${available_gb}GB disk space available. Need at least ${min_gb}GB."
  fi
}
