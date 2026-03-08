#!/usr/bin/env bash
# fleet.sh — OpenClaw Fleet Manager
# Provision, manage, and monitor multiple isolated OpenClaw Docker agents.
#
# Usage:
#   ./fleet.sh create <N> [--telegram-tokens <file|tok1,tok2>] [--prefix <name>]
#   ./fleet.sh status [--deep] [--json]
#   ./fleet.sh update [--agent <name>]
#   ./fleet.sh clone <source> <target> [--config-only]
#   ./fleet.sh destroy <name|--all> [--keep-data] [--force]
#   ./fleet.sh restart <name|--all>
#   ./fleet.sh stop <name|--all>
#   ./fleet.sh start <name|--all>
#   ./fleet.sh logs <name> [--tail <N>] [--follow]
#   ./fleet.sh shell <name>
#   ./fleet.sh reconfigure [--agent <name>]
#   ./fleet.sh reconcile
#   ./fleet.sh backup [<name>|--all]
#   ./fleet.sh restore <backup.tar.gz>
#   ./fleet.sh watchdog [install|uninstall|run]
#   ./fleet.sh pair <name> <code>

set -euo pipefail

# Resolve fleet directory (where this script lives)
FLEET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FLEET_DIR

# Source libraries
source "${FLEET_DIR}/lib/common.sh"
source "${FLEET_DIR}/lib/ports.sh"
source "${FLEET_DIR}/lib/config.sh"
source "${FLEET_DIR}/lib/docker.sh"
source "${FLEET_DIR}/lib/health.sh"
source "${FLEET_DIR}/lib/models.sh"
source "${FLEET_DIR}/lib/naming.sh"
source "${FLEET_DIR}/lib/secrets.sh"
source "${FLEET_DIR}/lib/agentguard.sh"
source "${FLEET_DIR}/lib/maintain.sh"

# --- Fleet env initialization ---

init_fleet_env() {
  local fleet_env="${FLEET_DIR}/.env.fleet"

  if [[ -f "$fleet_env" ]]; then
    source "$fleet_env"
    return
  fi

  log_info "First run — setting up fleet configuration..."
  echo ""

  # Fleet manager name (the host OpenClaw instance overseeing the fleet)
  echo -en "${CYAN}Fleet manager name (the host agent on this machine) [mini4]: ${NC}"
  read -r manager_name
  manager_name="${manager_name:-mini4}"

  # Reject shell metacharacters in all env values
  local bad_chars='[$`"'"'"'\\;|&!(){}]'
  if [[ "$manager_name" =~ $bad_chars ]]; then
    log_fatal "Manager name contains invalid characters"
  fi

  # Defaults
  local base_port="${FLEET_BASE_PORT:-19000}"
  local image_tag="${OPENCLAW_IMAGE_TAG:-latest}"
  local cpus="${FLEET_CPUS:-1.5}"
  local memory="${FLEET_MEMORY:-2048M}"

  echo -en "${CYAN}Base port for fleet [${base_port}]: ${NC}"
  read -r input_port
  base_port="${input_port:-$base_port}"

  echo -en "${CYAN}OpenClaw image tag [${image_tag}]: ${NC}"
  read -r input_tag
  image_tag="${input_tag:-$image_tag}"

  echo -en "${CYAN}CPU limit per agent [${cpus}]: ${NC}"
  read -r input_cpus
  cpus="${input_cpus:-$cpus}"

  echo -en "${CYAN}Memory limit per agent [${memory}]: ${NC}"
  read -r input_mem
  memory="${input_mem:-$memory}"

  # Validate all values
  if [[ ! "$base_port" =~ ^[0-9]+$ ]]; then
    log_fatal "Base port must be a number"
  fi
  for val in "$image_tag" "$cpus" "$memory"; do
    if [[ "$val" =~ $bad_chars ]]; then
      log_fatal "Config value contains invalid characters: $val"
    fi
  done

  cat > "$fleet_env" <<EOF
FLEET_MANAGER_NAME='${manager_name}'
FLEET_BASE_PORT='${base_port}'
OPENCLAW_IMAGE_TAG='${image_tag}'
OPENCLAW_IMAGE='ghcr.io/openclaw/openclaw'
FLEET_CPUS='${cpus}'
FLEET_MEMORY='${memory}'
EOF

  chmod 600 "$fleet_env"
  source "$fleet_env"
  log_ok "Fleet config saved to .env.fleet"

  # Detect 1Password
  if command -v op &>/dev/null; then
    log_info "1Password CLI detected. You can secure API keys with: ./fleet.sh secrets migrate"
  fi
  echo ""
}

# --- Commands ---

cmd_create() {
  local count="${1:-}"
  shift || true

  if [[ -z "$count" ]] || ! [[ "$count" =~ ^[0-9]+$ ]] || [[ "$count" -lt 1 ]]; then
    log_fatal "Usage: fleet.sh create <N> [--telegram-tokens <file|tok1,tok2>] [--name <name>] [--role <role>] [--model <sub/model>] [--fallback <sub/model>]"
  fi

  local telegram_tokens_arg=""
  local prefix=""
  local custom_name=""
  local role=""
  local model_primary=""
  local model_fallbacks; model_fallbacks=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --telegram-tokens) telegram_tokens_arg="$2"; shift 2 ;;
      --prefix)          prefix="$2"; shift 2 ;;
      --name)            custom_name="$2"; shift 2 ;;
      --role)            role="$2"; shift 2 ;;
      --model)           model_primary="$2"; shift 2 ;;
      --fallback)        model_fallbacks+=("$2"); shift 2 ;;
      *)                 log_fatal "Unknown option: $1" ;;
    esac
  done

  # Parse telegram tokens
  local telegram_tokens; telegram_tokens=()
  if [[ -n "$telegram_tokens_arg" ]]; then
    if [[ -f "$telegram_tokens_arg" ]]; then
      while IFS= read -r line; do
        line="$(echo "$line" | tr -d '[:space:]')"
        [[ -n "$line" ]] && telegram_tokens+=("$line")
      done < "$telegram_tokens_arg"
    else
      IFS=',' read -ra telegram_tokens <<< "$telegram_tokens_arg"
    fi

    if [[ ${#telegram_tokens[@]} -lt $count ]]; then
      log_fatal "Provided ${#telegram_tokens[@]} Telegram tokens but need $count"
    fi
  fi

  # Pre-flight checks
  check_dependencies
  detect_platform
  check_disk_space 2
  check_resources "$count"

  # Ensure at least one provider is configured (or legacy ZAI_API_KEY exists)
  init_providers
  local provider_count
  provider_count=$(jq '.subscriptions | length' "$PROVIDERS_FILE" 2>/dev/null || echo 0)
  if [[ "$provider_count" -eq 0 ]] && [[ -z "${ZAI_API_KEY:-}" ]]; then
    echo ""
    log_info "No AI provider configured yet. Let's set one up first."
    log_info "You'll need an API key from your AI provider (Anthropic, OpenAI, zai, etc.)"
    echo ""
    interactive_add_subscription || log_fatal "At least one provider is required to create agents."
    echo ""
  fi

  # Pull image
  pull_image || log_fatal "Failed to pull image"

  # Acquire lock for registry operations
  acquire_lock
  init_registry

  echo ""
  log_info "Creating $count agent(s)..."
  echo ""

  local created=0
  local failed=0
  local created_names; created_names=()
  local failed_names; failed_names=()

  # Initialize providers for model allocation
  init_providers

  for i in $(seq 1 "$count"); do
    local name
    if [[ -n "$custom_name" ]] && [[ "$count" -eq 1 ]]; then
      name="$custom_name"
    elif [[ -n "$role" ]]; then
      name=$(auto_name "$role")
    elif [[ -n "$prefix" ]]; then
      name=$(next_agent_name "$prefix")
    else
      name=$(auto_name)
    fi

    # Validate name
    if ! validate_name "$name"; then
      failed=$((failed + 1))
      failed_names+=("$name")
      continue
    fi

    log_info "--- Agent $i/$count: $name ---"

    # Get Telegram token
    local tg_token=""
    if [[ ${#telegram_tokens[@]} -ge $i ]]; then
      tg_token="${telegram_tokens[$((i-1))]}"
    else
      echo ""
      log_info "Need a Telegram bot token? Create one by messaging @BotFather: https://t.me/BotFather"
      echo -en "${CYAN}Enter Telegram bot token for '$name': ${NC}"
      read -r tg_token
    fi

    if [[ -z "$tg_token" ]]; then
      log_error "Telegram token required for '$name'. Skipping."
      failed=$((failed + 1))
      failed_names+=("$name")
      continue
    fi

    # Validate token format (digits:alphanumeric)
    if ! echo "$tg_token" | grep -qE '^[0-9]+:[A-Za-z0-9_-]+$'; then
      log_error "Invalid Telegram token format for '$name'. Expected format: 123456:ABC-xyz. Skipping."
      failed=$((failed + 1))
      failed_names+=("$name")
      continue
    fi

    # Mark as creating
    local ports
    ports=$(allocate_ports)
    local gw_port="${ports%%:*}"
    local br_port="${ports##*:}"
    local gw_token
    gw_token=$(generate_token)

    # Register agent in creating state
    registry_add_agent "$name" "$gw_port" "$br_port" "" "$gw_token"
    registry_set_state "$name" "creating"

    # Allocate model if specified
    if [[ -n "$model_primary" ]]; then
      allocate_model "$name" "$model_primary" ${model_fallbacks[@]+"${model_fallbacks[@]}"} 2>/dev/null || true
    fi

    # Create config files (uses provider system if available, falls back to legacy)
    if ! create_agent_files_v2 "$name" "$gw_port" "$br_port" "$gw_token" "$tg_token"; then
      log_error "Failed to create config for '$name'"
      registry_remove_agent "$name"
      rm -rf "${FLEET_DIR}/agents/${name}"
      failed=$((failed + 1))
      failed_names+=("$name")
      continue
    fi

    # Start the container
    if ! start_agent "$name"; then
      log_error "Failed to start agent '$name'"
      registry_set_state "$name" "failed"
      failed=$((failed + 1))
      failed_names+=("$name")
      continue
    fi

    # Wait for health
    log_info "Waiting for '$name' to become healthy (may take up to 2 minutes)..."
    local healthy=false
    for attempt in $(seq 1 12); do
      sleep 10
      printf "  Checking health (%d/12)...\r" "$attempt"
      if [[ "$(check_agent_health "$name")" == "healthy" ]]; then
        healthy=true
        break
      fi
    done
    echo ""

    if [[ "$healthy" == "true" ]]; then
      registry_set_state "$name" "running"
      created=$((created + 1))
      created_names+=("$name")
      log_ok "Agent '$name' is healthy on port $gw_port"
    else
      log_warn "Agent '$name' started but not yet healthy. It may still be initializing."
      registry_set_state "$name" "running"
      created=$((created + 1))
      created_names+=("$name")
    fi

    # Register with AgentGuard if enabled
    if agentguard_enabled; then
      register_agent "$name"
    fi

    # Stagger next creation to avoid thundering herd
    if [[ $i -lt $count ]]; then
      stagger_delay 3
    fi

    echo ""
  done

  # Summary
  echo ""
  echo -e "${BOLD}=== Create Summary ===${NC}"
  echo -e "  Created: ${GREEN}${created}${NC}"
  if [[ $failed -gt 0 ]]; then
    echo -e "  Failed:  ${RED}${failed}${NC} (${failed_names[*]})"
  fi
  echo ""

  if [[ $created -gt 0 ]]; then
    log_info "Next: Pair your Telegram account with each bot:"
    log_info "  1. Open Telegram, find the bot by its @username"
    log_info "  2. Send it any message (e.g., 'hello')"
    log_info "  3. The bot replies with a pairing code"
    log_info "  4. Run: ./fleet.sh pair <agent_name> <code>"
    echo ""
    print_status_table
  fi
}

cmd_status() {
  local deep=false
  local json=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --deep) deep=true; shift ;;
      --json) json=true; shift ;;
      *)      log_fatal "Unknown option: $1" ;;
    esac
  done

  detect_platform
  acquire_lock
  init_registry

  # Always reconcile first
  reconcile_registry

  if [[ "$json" == "true" ]]; then
    print_status_json
  else
    print_status_table "$deep"
  fi
}

cmd_update() {
  local target_agent=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent) target_agent="$2"; shift 2 ;;
      *)       log_fatal "Unknown option: $1" ;;
    esac
  done

  check_dependencies
  detect_platform
  acquire_lock
  init_registry

  # Pull new image (with rollback tag)
  pull_image || log_fatal "Failed to pull new image"

  local agents_to_update=()
  if [[ -n "$target_agent" ]]; then
    agents_to_update=("$target_agent")
  else
    while IFS= read -r name; do
      agents_to_update+=("$name")
    done < <(registry_list_agents)
  fi

  if [[ ${#agents_to_update[@]} -eq 0 ]]; then
    log_info "No agents to update."
    return
  fi

  log_info "Rolling update for ${#agents_to_update[@]} agent(s)..."
  echo ""

  local update_failed=false

  for name in "${agents_to_update[@]}"; do
    log_info "Updating agent '$name'..."

    # Propagate any fleet config changes
    propagate_config "$name"

    # Graceful stop
    stop_agent "$name" 30

    # Destroy old containers
    destroy_agent_containers "$name"

    # Start with new image
    if ! start_agent "$name"; then
      log_error "Agent '$name' failed to start after update!"
      update_failed=true
      registry_set_state "$name" "failed"
      continue
    fi

    # Health check gate
    log_info "Waiting for '$name' to become healthy..."
    local healthy=false
    for attempt in $(seq 1 12); do
      sleep 10
      if [[ "$(check_agent_health "$name")" == "healthy" ]]; then
        healthy=true
        break
      fi
      echo -n "."
    done
    echo ""

    if [[ "$healthy" == "true" ]]; then
      registry_set_state "$name" "running"
      log_ok "Agent '$name' updated and healthy"
    else
      log_error "Agent '$name' is not healthy after update. Attempting rollback..."
      stop_agent "$name" 10
      destroy_agent_containers "$name"
      rollback_image
      start_agent "$name"
      registry_set_state "$name" "rolled-back"
      update_failed=true
      log_warn "Agent '$name' rolled back to previous image"

      if [[ -z "$target_agent" ]]; then
        log_error "Stopping rolling update due to failure. Remaining agents not updated."
        break
      fi
    fi

    # Stagger between agents
    if [[ "$name" != "${agents_to_update[${#agents_to_update[@]}-1]}" ]]; then
      stagger_delay 5
    fi
  done

  echo ""
  if [[ "$update_failed" == "true" ]]; then
    log_warn "Update completed with errors. Run './fleet.sh status --deep' to check."
  else
    log_ok "All agents updated successfully."
  fi
  print_status_table
}

cmd_clone() {
  local source="${1:-}"
  local target="${2:-}"
  local config_only=false

  shift 2 || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config-only) config_only=true; shift ;;
      *)             log_fatal "Unknown option: $1" ;;
    esac
  done

  if [[ -z "$source" ]] || [[ -z "$target" ]]; then
    log_fatal "Usage: fleet.sh clone <source> <target> [--config-only]"
  fi

  detect_platform
  check_dependencies
  acquire_lock
  init_registry

  # Validate
  local source_info
  source_info=$(registry_get_agent "$source")
  if [[ "$source_info" == "null" ]]; then
    log_fatal "Source agent '$source' not found in registry."
  fi

  if [[ "$(registry_get_agent "$target")" != "null" ]]; then
    log_fatal "Target agent '$target' already exists."
  fi

  if ! validate_name "$target"; then
    log_fatal "Invalid agent name: '$target'"
  fi

  local source_dir="${FLEET_DIR}/agents/${source}"
  local target_dir="${FLEET_DIR}/agents/${target}"

  # Allocate new ports
  local ports
  ports=$(allocate_ports)
  local gw_port="${ports%%:*}"
  local br_port="${ports##*:}"
  local gw_token
  gw_token=$(generate_token)

  # Prompt for new Telegram token
  echo -en "${CYAN}Enter Telegram bot token for '$target' (must be different from source): ${NC}"
  read -r tg_token
  if [[ -z "$tg_token" ]]; then
    log_fatal "Telegram token required for cloned agent."
  fi

  # Create target directory
  mkdir -p "${target_dir}"

  if [[ "$config_only" == "false" ]] && [[ -d "${source_dir}/workspace" ]]; then
    # Copy workspace
    log_info "Copying workspace from '$source' to '$target'..."
    cp -a "${source_dir}/workspace" "${target_dir}/workspace"
  else
    mkdir -p "${target_dir}/workspace"
  fi

  # Copy config structure
  cp -a "${source_dir}/config" "${target_dir}/config"

  # Strip identity-specific files
  rm -rf "${target_dir}/config/identity"
  rm -rf "${target_dir}/config/telegram"
  rm -rf "${target_dir}/config/credentials"
  rm -rf "${target_dir}/config/devices"
  rm -rf "${target_dir}/config/agents/main/sessions"
  rm -rf "${target_dir}/config/canvas"
  rm -rf "${target_dir}/config/logs"
  mkdir -p "${target_dir}/config/identity"
  mkdir -p "${target_dir}/config/agents/main/sessions"

  # Regenerate config with new values using v2 provider system
  source_fleet_env
  init_providers

  # Copy source model allocation if it exists
  local src_allocation
  src_allocation=$(get_agent_allocation "$source")
  if [[ "$src_allocation" != "null" ]]; then
    local src_primary
    src_primary=$(echo "$src_allocation" | jq -r '.primary')
    local src_fallbacks
    src_fallbacks=$(echo "$src_allocation" | jq -r '.fallbacks[]? // empty')
    allocate_model "$target" "$src_primary" $src_fallbacks 2>/dev/null || true
  fi

  create_agent_files_v2 "$target" "$gw_port" "$br_port" "$gw_token" "$tg_token"

  # Register and start
  registry_add_agent "$target" "$gw_port" "$br_port" "" "$gw_token"
  start_agent "$target"
  registry_set_state "$target" "running"

  log_ok "Cloned '$source' -> '$target' on port $gw_port"
  echo ""
  log_info "Pair Telegram: message the new bot, then run: ./fleet.sh pair $target <code>"
}

cmd_destroy() {
  local target="${1:-}"
  local keep_data=false
  local force=false

  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-data) keep_data=true; shift ;;
      --force)     force=true; shift ;;
      *)           log_fatal "Unknown option: $1" ;;
    esac
  done

  if [[ -z "$target" ]]; then
    log_fatal "Usage: fleet.sh destroy <name|--all> [--keep-data] [--force]"
  fi

  detect_platform
  acquire_lock
  init_registry

  local agents_to_destroy=()

  if [[ "$target" == "--all" ]]; then
    if [[ "$force" != "true" ]]; then
      confirm "Destroy ALL agents? This cannot be undone." || return 0
    fi
    while IFS= read -r name; do
      agents_to_destroy+=("$name")
    done < <(registry_list_agents)
  else
    if [[ "$(registry_get_agent "$target")" == "null" ]]; then
      log_fatal "Agent '$target' not found in registry."
    fi
    if [[ "$force" != "true" ]]; then
      confirm "Destroy agent '$target'?" || return 0
    fi
    agents_to_destroy=("$target")
  fi

  for name in "${agents_to_destroy[@]}"; do
    log_info "Destroying agent '$name'..."

    # Deregister from AgentGuard
    deregister_agent "$name"

    # Stop and remove containers
    destroy_agent_containers "$name"

    # Remove data
    if [[ "$keep_data" == "false" ]]; then
      rm -rf "${FLEET_DIR}/agents/${name}"
      log_info "Removed data for '$name'"
    else
      log_info "Kept data for '$name' at agents/${name}/"
    fi

    # Remove from registry
    registry_remove_agent "$name"
    log_ok "Agent '$name' destroyed"
  done
}

cmd_restart() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    log_fatal "Usage: fleet.sh restart <name|--all>"
  fi

  detect_platform
  acquire_lock
  init_registry

  local agents=()
  if [[ "$target" == "--all" ]]; then
    while IFS= read -r name; do
      agents+=("$name")
    done < <(registry_list_agents)
  else
    agents=("$target")
  fi

  for name in "${agents[@]}"; do
    if [[ "$(registry_get_agent "$name")" == "null" ]]; then
      log_error "Agent '$name' not found in registry"
      continue
    fi
    restart_agent "$name"
    if [[ "$target" == "--all" ]] && [[ "$name" != "${agents[${#agents[@]}-1]}" ]]; then
      stagger_delay 5
    fi
  done
}

cmd_stop() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    log_fatal "Usage: fleet.sh stop <name|--all>"
  fi

  detect_platform
  acquire_lock
  init_registry

  local agents=()
  if [[ "$target" == "--all" ]]; then
    while IFS= read -r name; do
      agents+=("$name")
    done < <(registry_list_agents)
  else
    agents=("$target")
  fi

  for name in "${agents[@]}"; do
    if [[ "$(registry_get_agent "$name")" == "null" ]]; then
      log_error "Agent '$name' not found in registry"
      continue
    fi
    stop_agent "$name"
    registry_set_state "$name" "stopped"
  done
}

cmd_start() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    log_fatal "Usage: fleet.sh start <name|--all>"
  fi

  detect_platform
  acquire_lock
  init_registry

  local agents=()
  if [[ "$target" == "--all" ]]; then
    while IFS= read -r name; do
      agents+=("$name")
    done < <(registry_list_agents)
  else
    agents=("$target")
  fi

  for name in "${agents[@]}"; do
    if [[ "$(registry_get_agent "$name")" == "null" ]]; then
      log_error "Agent '$name' not found in registry"
      continue
    fi
    start_agent "$name"
    registry_set_state "$name" "running"
    if [[ "$target" == "--all" ]] && [[ "$name" != "${agents[${#agents[@]}-1]}" ]]; then
      stagger_delay 5
    fi
  done
}

cmd_logs() {
  local name="${1:-}"
  shift || true

  if [[ -z "$name" ]]; then
    log_fatal "Usage: fleet.sh logs <name> [--tail <N>] [--follow]"
  fi

  local tail_n="100"
  local follow=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tail|-n) tail_n="$2"; shift 2 ;;
      --follow|-f) follow="--follow"; shift ;;
      *)         log_fatal "Unknown option: $1" ;;
    esac
  done

  local agent_dir="${FLEET_DIR}/agents/${name}"
  docker compose -f "${agent_dir}/docker-compose.yml" \
    --env-file "${agent_dir}/.env" \
    -p "openclaw-${name}" \
    logs --tail "$tail_n" $follow openclaw-gateway
}

cmd_shell() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    log_fatal "Usage: fleet.sh shell <name>"
  fi

  log_info "Opening shell in agent '$name'..."
  docker exec -it "openclaw_${name}" /bin/sh
}

cmd_reconfigure() {
  local target_agent=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent) target_agent="$2"; shift 2 ;;
      *)       log_fatal "Unknown option: $1" ;;
    esac
  done

  detect_platform
  acquire_lock
  init_registry
  source_fleet_env

  local agents=()
  if [[ -n "$target_agent" ]]; then
    agents=("$target_agent")
  else
    while IFS= read -r name; do
      agents+=("$name")
    done < <(registry_list_agents)
  fi

  for name in "${agents[@]}"; do
    log_info "Reconfiguring agent '$name'..."
    propagate_config "$name"
    restart_agent "$name"
    log_ok "Agent '$name' reconfigured and restarted"

    if [[ "$name" != "${agents[${#agents[@]}-1]}" ]]; then
      stagger_delay 3
    fi
  done
}

cmd_reconcile() {
  detect_platform
  acquire_lock
  init_registry
  reconcile_registry
}

cmd_backup() {
  local target="${1:---all}"
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_dir="${FLEET_DIR}/backups"
  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"

  detect_platform
  init_registry

  local agents=()
  if [[ "$target" == "--all" ]]; then
    while IFS= read -r name; do
      agents+=("$name")
    done < <(registry_list_agents)

    # Also backup fleet-level files
    local fleet_backup="${backup_dir}/fleet_${timestamp}.tar.gz"
    tar -czf "$fleet_backup" \
      -C "$FLEET_DIR" \
      .env.fleet \
      agents/registry.json \
      agents/providers.json \
      2>/dev/null || true
    chmod 600 "$fleet_backup"
    log_ok "Fleet config backed up to $fleet_backup"
  else
    agents=("$target")
  fi

  for name in "${agents[@]}"; do
    local agent_dir="${FLEET_DIR}/agents/${name}"
    if [[ ! -d "$agent_dir" ]]; then
      log_warn "Agent '$name' directory not found, skipping"
      continue
    fi

    local backup_file="${backup_dir}/${name}_${timestamp}.tar.gz"

    # Backup config only (not workspace, as it can be huge)
    tar -czf "$backup_file" \
      -C "${FLEET_DIR}/agents" \
      "${name}/config" \
      "${name}/.env" \
      "${name}/docker-compose.yml" \
      2>/dev/null
    chmod 600 "$backup_file"

    log_ok "Agent '$name' backed up to $backup_file"
  done
}

cmd_restore() {
  local backup_file="${1:-}"
  if [[ -z "$backup_file" ]] || [[ ! -f "$backup_file" ]]; then
    log_fatal "Usage: fleet.sh restore <backup.tar.gz>"
  fi

  detect_platform
  check_dependencies
  acquire_lock
  init_registry

  # Validate backup tarball for path traversal before extracting
  if tar -tzf "$backup_file" 2>/dev/null | grep -qE '(^/|\.\./)'; then
    log_fatal "Malicious backup detected: contains absolute or traversal paths"
  fi

  # Extract to temp dir to inspect
  local tmp_dir
  tmp_dir=$(mktemp -d)
  tar -xzf "$backup_file" -C "$tmp_dir"

  # Find agent name from extracted files
  local agent_name
  agent_name=$(ls "$tmp_dir" | head -1)

  if [[ -z "$agent_name" ]]; then
    rm -rf "$tmp_dir"
    log_fatal "Could not determine agent name from backup"
  fi

  if ! validate_name "$agent_name" 2>/dev/null; then
    rm -rf "$tmp_dir"
    log_fatal "Invalid agent name in backup: '$agent_name'"
  fi

  if [[ "$(registry_get_agent "$agent_name")" != "null" ]]; then
    rm -rf "$tmp_dir"
    log_fatal "Agent '$agent_name' already exists. Destroy it first or use a different name."
  fi

  # Allocate new ports (original ports may be taken)
  local ports
  ports=$(allocate_ports)
  local gw_port="${ports%%:*}"
  local br_port="${ports##*:}"
  local gw_token
  gw_token=$(generate_token)

  local agent_dir="${FLEET_DIR}/agents/${agent_name}"
  mkdir -p "${agent_dir}/workspace"

  # Copy config from backup
  cp -a "${tmp_dir}/${agent_name}/config" "${agent_dir}/config"

  # Read telegram token from restored config
  local tg_token
  tg_token=$(jq -r '.channels.telegram.botToken // ""' "${agent_dir}/config/openclaw.json" 2>/dev/null)

  # Validate telegram token was extracted
  if [[ -z "$tg_token" ]]; then
    echo -en "${CYAN}Telegram token not found in backup. Enter token: ${NC}"
    read -r tg_token
    if [[ -z "$tg_token" ]]; then
      rm -rf "$tmp_dir"
      log_fatal "Telegram token is required."
    fi
  fi

  # Regenerate with new ports/token using v2 provider system
  source_fleet_env
  init_providers
  create_agent_files_v2 "$agent_name" "$gw_port" "$br_port" "$gw_token" "$tg_token"

  # Clean identity files (will be regenerated)
  rm -rf "${agent_dir}/config/identity"
  mkdir -p "${agent_dir}/config/identity"

  # Register and start
  registry_add_agent "$agent_name" "$gw_port" "$br_port" "" "$gw_token"
  start_agent "$agent_name"
  registry_set_state "$agent_name" "running"

  rm -rf "$tmp_dir"
  log_ok "Restored agent '$agent_name' on port $gw_port"
}

cmd_watchdog() {
  local action="${1:-run}"

  case "$action" in
    install)
      local cron_cmd="*/5 * * * * ${FLEET_DIR}/fleet.sh watchdog run >> ${FLEET_DIR}/agents/watchdog-cron.log 2>&1"
      (crontab -l 2>/dev/null | grep -v "fleet.sh watchdog"; echo "$cron_cmd") | crontab -
      log_ok "Watchdog cron job installed (every 5 minutes)"
      ;;
    uninstall)
      (crontab -l 2>/dev/null | grep -v "fleet.sh watchdog") | crontab -
      log_ok "Watchdog cron job removed"
      ;;
    run)
      detect_platform
      acquire_lock
      init_registry
      watchdog_check 3
      ;;
    *)
      log_fatal "Usage: fleet.sh watchdog [install|uninstall|run]"
      ;;
  esac
}

cmd_maintain() {
  local action="${1:-run}"

  case "$action" in
    install)
      maintain_install_cron
      ;;
    uninstall)
      maintain_uninstall_cron
      ;;
    run)
      source_fleet_env
      detect_platform
      acquire_lock
      init_registry
      maintain_run
      ;;
    *)
      log_fatal "Usage: fleet.sh maintain [install|uninstall|run]"
      ;;
  esac
}

cmd_pair() {
  local name="${1:-}"
  local code="${2:-}"

  if [[ -z "$name" ]] || [[ -z "$code" ]]; then
    log_fatal "Usage: fleet.sh pair <agent_name> <pairing_code>"
  fi

  agent_cli "$name" pairing approve --channel telegram --notify "$code"
  log_ok "Pairing code '$code' approved for agent '$name'"
}

cmd_providers() {
  local action="${1:-list}"
  shift || true

  init_providers

  case "$action" in
    add)
      if [[ $# -ge 3 ]]; then
        # Non-interactive: providers add <name> <type> <api_key> [label] [base_url]
        add_subscription "$@"
      else
        interactive_add_subscription
      fi
      ;;
    remove)
      local name="${1:-}"
      if [[ -z "$name" ]]; then
        log_fatal "Usage: fleet.sh providers remove <name>"
      fi
      remove_subscription "$name"
      ;;
    list)
      list_subscriptions
      ;;
    *)
      log_fatal "Usage: fleet.sh providers [add|remove|list]"
      ;;
  esac
}

cmd_models() {
  local action="${1:-list}"
  shift || true

  init_providers
  init_registry

  case "$action" in
    assign)
      local agent="${1:-}"
      local primary="${2:-}"
      if [[ -z "$agent" ]] || [[ -z "$primary" ]]; then
        interactive_allocate_model "$agent"
      else
        # Verify agent exists
        if [[ "$(registry_get_agent "$agent")" == "null" ]]; then
          log_fatal "Agent '$agent' not found in registry. Run: ./fleet.sh status"
        fi
        shift 2
        allocate_model "$agent" "$primary" "$@"
      fi

      # Apply the allocation to the running agent
      local agent_dir="${FLEET_DIR}/agents/${agent}"
      if [[ -d "$agent_dir" ]]; then
        log_info "Applying model config to agent '$agent'..."
        apply_model_config "$agent"
        restart_agent "$agent" 2>/dev/null || log_warn "Agent '$agent' not running. Config saved for next start."
      fi
      ;;
    list)
      print_allocations
      ;;
    *)
      log_fatal "Usage: fleet.sh models [assign|list]"
      ;;
  esac
}

cmd_secrets() {
  local action="${1:-status}"
  shift || true

  case "$action" in
    migrate)
      migrate_to_op
      ;;
    status)
      if op_available; then
        log_ok "1Password CLI: connected"
        local vault="OpenClaw-Fleet"
        if op vault get "$vault" &>/dev/null 2>&1; then
          local count
          count=$(op item list --vault "$vault" --format json 2>/dev/null | jq length)
          log_ok "Vault '$vault': $count item(s)"
        else
          log_info "Vault '$vault': not created yet. Run: ./fleet.sh secrets migrate"
        fi
      else
        log_info "1Password CLI: not available (secrets stored in plaintext)"
        log_info "To enable: brew install 1password-cli && op signin"
      fi
      ;;
    *)
      log_fatal "Usage: fleet.sh secrets [status|migrate]"
      ;;
  esac
}

cmd_agentguard() {
  local action="${1:-status}"
  shift || true

  case "$action" in
    enable)
      local api_key="${1:-}"
      if [[ -z "$api_key" ]]; then
        echo -en "${CYAN}Enter AgentGuard API key (ag_live_...): ${NC}"
        read -rs api_key
        echo ""
      fi
      if [[ -z "$api_key" ]]; then
        log_fatal "API key required. Get one at https://agentguard.tech"
      fi
      export AGENTGUARD_API_KEY="$api_key"

      # Save to .env.fleet
      if grep -q "AGENTGUARD_API_KEY" "${FLEET_DIR}/.env.fleet" 2>/dev/null; then
        sed -i.bak "s|^AGENTGUARD_API_KEY=.*|AGENTGUARD_API_KEY='${api_key}'|" "${FLEET_DIR}/.env.fleet"
        rm -f "${FLEET_DIR}/.env.fleet.bak"
      else
        echo "AGENTGUARD_API_KEY='${api_key}'" >> "${FLEET_DIR}/.env.fleet"
      fi

      init_agentguard
      log_ok "AgentGuard enabled for this fleet"

      # Register existing agents
      init_registry
      while IFS= read -r name; do
        register_agent "$name"
      done < <(registry_list_agents)
      ;;

    disable)
      sed -i.bak '/^AGENTGUARD_/d' "${FLEET_DIR}/.env.fleet" 2>/dev/null
      rm -f "${FLEET_DIR}/.env.fleet.bak"
      log_ok "AgentGuard disabled"
      ;;

    status)
      if agentguard_enabled; then
        log_ok "AgentGuard: enabled"
        init_registry
        echo ""
        printf "  ${BOLD}%-12s %-20s${NC}\n" "AGENT" "SECURITY STATUS"
        printf "  %-12s %-20s\n" "------------" "--------------------"
        while IFS= read -r name; do
          local sec_status
          sec_status=$(agent_security_status "$name")
          printf "  %-12s %-20s\n" "$name" "$sec_status"
        done < <(registry_list_agents)
      else
        log_info "AgentGuard: not configured"
        log_info "Enable with: ./fleet.sh agentguard enable"
      fi
      ;;

    kill)
      local agent="${1:-}"
      local reason="${2:-Manual kill via fleet CLI}"
      if [[ -z "$agent" ]]; then
        log_fatal "Usage: fleet.sh agentguard kill <agent_name> [reason]"
      fi
      kill_agent "$agent" "$reason"
      ;;

    policy)
      init_agentguard
      log_info "Policy file: ${AGENTGUARD_CONFIG}"
      if command -v "${EDITOR:-vi}" &>/dev/null; then
        "${EDITOR:-vi}" "$AGENTGUARD_CONFIG"
      fi
      ;;

    *)
      log_fatal "Usage: fleet.sh agentguard [enable|disable|status|kill|policy]"
      ;;
  esac
}

cmd_help() {
  local manager
  manager=$(get_fleet_manager_name)
  cat <<HELP
OpenClaw Fleet Manager (managed by: ${manager})

Usage:
  fleet.sh <command> [options]

Agent Lifecycle:
  create <N>          Create N new agents
    --name <name>       Custom name (single agent only)
    --role <role>       Role-based naming (e.g., researcher, coder)
    --model <sub/model> Primary model (e.g., anthropic-max1/claude-opus-4-6)
    --fallback <s/m>    Fallback model (repeatable)
    --telegram-tokens   File or comma-separated list of bot tokens

  destroy <name>      Destroy an agent (or --all)
  clone <src> <dst>   Clone an agent's config to a new agent
  status [--deep]     Show fleet status (--json for scripting)

Provider & Model Management:
  providers add       Add an AI provider subscription (interactive)
  providers list      List all subscriptions and available models
  providers remove    Remove a subscription

  models assign       Assign primary + fallback models to an agent
  models list         Show current model allocations

Security:
  secrets status      Show 1Password integration status
  secrets migrate     Migrate plaintext secrets to 1Password
  agentguard enable   Enable AgentGuard policy enforcement
  agentguard disable  Disable AgentGuard
  agentguard status   Show security status for all agents
  agentguard kill <n> Emergency kill switch for an agent
  agentguard policy   Edit the security policy file

Fleet Operations:
  update              Rolling update to latest OpenClaw image
  restart <name>      Restart agent (or --all)
  stop / start        Stop or start agents
  reconfigure         Re-propagate fleet config to all agents

Tools:
  logs <name>         View agent logs (--tail N, --follow)
  shell <name>        Open shell in agent container
  pair <name> <code>  Approve Telegram pairing code
  reconcile           Sync registry with Docker state
  backup / restore    Backup and restore agent configs
  watchdog            Health watchdog (install/uninstall/run)
  maintain            Daily maintenance (install/uninstall/run)

HELP
}

# --- Main dispatcher ---

main() {
  local command="${1:-help}"
  shift || true

  # Ensure agents dir exists
  mkdir -p "${FLEET_DIR}/agents"

  case "$command" in
    create)       init_fleet_env; cmd_create "$@" ;;
    status)       source_fleet_env; cmd_status "$@" ;;
    update)       init_fleet_env; cmd_update "$@" ;;
    clone)        init_fleet_env; cmd_clone "$@" ;;
    destroy)      cmd_destroy "$@" ;;
    restart)      cmd_restart "$@" ;;
    stop)         cmd_stop "$@" ;;
    start)        cmd_start "$@" ;;
    logs)         cmd_logs "$@" ;;
    shell)        cmd_shell "$@" ;;
    reconfigure)  init_fleet_env; cmd_reconfigure "$@" ;;
    reconcile)    cmd_reconcile "$@" ;;
    backup)       cmd_backup "$@" ;;
    restore)      init_fleet_env; cmd_restore "$@" ;;
    watchdog)     cmd_watchdog "$@" ;;
    maintain)     cmd_maintain "$@" ;;
    pair)         cmd_pair "$@" ;;
    providers)    source_fleet_env; cmd_providers "$@" ;;
    models)       source_fleet_env; cmd_models "$@" ;;
    secrets)      cmd_secrets "$@" ;;
    agentguard)   source_fleet_env; cmd_agentguard "$@" ;;
    help|--help|-h) cmd_help ;;
    *)            log_error "Unknown command: $command"; cmd_help; exit 1 ;;
  esac
}

main "$@"
