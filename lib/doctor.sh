#!/usr/bin/env bash
# doctor.sh — Fleet diagnostics and self-healing
#
# Runs checks across the entire fleet, reports issues,
# and auto-fixes what it can. Designed to be run manually
# or from the manager agent's heartbeat.

DOCTOR_ISSUES=0
DOCTOR_FIXED=0
DOCTOR_WARNINGS=0
DOCTOR_CHECKS=0

# --- Reporting helpers ---

doctor_pass() {
  DOCTOR_CHECKS=$((DOCTOR_CHECKS + 1))
  echo -e "  ${GREEN}✓${NC} $*"
}

doctor_fix() {
  DOCTOR_CHECKS=$((DOCTOR_CHECKS + 1))
  DOCTOR_FIXED=$((DOCTOR_FIXED + 1))
  echo -e "  ${CYAN}⚡${NC} $* ${CYAN}(auto-fixed)${NC}"
}

doctor_warn() {
  DOCTOR_CHECKS=$((DOCTOR_CHECKS + 1))
  DOCTOR_WARNINGS=$((DOCTOR_WARNINGS + 1))
  echo -e "  ${YELLOW}!${NC} $*"
}

doctor_fail() {
  DOCTOR_CHECKS=$((DOCTOR_CHECKS + 1))
  DOCTOR_ISSUES=$((DOCTOR_ISSUES + 1))
  echo -e "  ${RED}✗${NC} $*"
}

# --- Check: System dependencies ---

doctor_check_deps() {
  echo ""
  echo -e "${BOLD}System${NC}"

  # Docker
  if command -v docker &>/dev/null; then
    if docker info &>/dev/null 2>&1; then
      doctor_pass "Docker running"
    else
      doctor_fail "Docker installed but not running"
    fi
  else
    doctor_fail "Docker not installed"
  fi

  # jq
  if command -v jq &>/dev/null; then
    doctor_pass "jq available"
  else
    doctor_fail "jq not installed"
  fi

  # bc
  if command -v bc &>/dev/null; then
    doctor_pass "bc available"
  else
    doctor_warn "bc not installed (needed for capacity calculations)"
  fi

  # openssl
  if command -v openssl &>/dev/null; then
    doctor_pass "openssl available"
  else
    doctor_warn "openssl not installed (needed for token generation)"
  fi

  # Disk space
  local available_kb
  available_kb=$(df -k "${FLEET_DIR}" | tail -1 | awk '{print $4}')
  local available_gb=$((available_kb / 1024 / 1024))
  if [[ $available_gb -ge 5 ]]; then
    doctor_pass "Disk space: ${available_gb}GB free"
  elif [[ $available_gb -ge 2 ]]; then
    doctor_warn "Disk space low: ${available_gb}GB free"
  else
    doctor_fail "Disk space critical: ${available_gb}GB free"
  fi
}

# --- Check: Fleet config ---

doctor_check_fleet_config() {
  echo ""
  echo -e "${BOLD}Fleet Config${NC}"

  local fleet_env="${FLEET_DIR}/.env.fleet"

  # .env.fleet exists
  if [[ -f "$fleet_env" ]]; then
    doctor_pass ".env.fleet exists"
  else
    doctor_fail ".env.fleet missing — run: fleet setup"
    return
  fi

  # Permissions
  local perms
  if [[ "$PLATFORM" == "darwin" ]]; then
    perms=$(stat -f %Lp "$fleet_env" 2>/dev/null)
  else
    perms=$(stat -c %a "$fleet_env" 2>/dev/null)
  fi
  if [[ "$perms" == "600" ]]; then
    doctor_pass ".env.fleet permissions: 600"
  else
    chmod 600 "$fleet_env"
    doctor_fix ".env.fleet permissions: $perms -> 600"
  fi

  # Registry exists
  if [[ -f "$REGISTRY_FILE" ]]; then
    if jq empty "$REGISTRY_FILE" 2>/dev/null; then
      doctor_pass "registry.json valid"
    else
      doctor_fail "registry.json is corrupt JSON"
    fi
  else
    doctor_warn "registry.json missing (no agents created yet)"
  fi

  # Providers file
  local providers_file="${FLEET_DIR}/agents/providers.json"
  if [[ -f "$providers_file" ]]; then
    if jq empty "$providers_file" 2>/dev/null; then
      local sub_count
      sub_count=$(jq '.subscriptions | length' "$providers_file" 2>/dev/null || echo 0)
      if [[ "$sub_count" -gt 0 ]]; then
        doctor_pass "providers.json: $sub_count subscription(s)"
      else
        doctor_warn "providers.json: no subscriptions configured"
      fi
    else
      doctor_fail "providers.json is corrupt JSON"
    fi
  else
    doctor_warn "providers.json missing — run: fleet providers add"
  fi

  # Stale lock
  local lock_dir="${FLEET_DIR}/agents/.fleet.lock"
  if [[ -d "$lock_dir" ]]; then
    local lock_pid_file="${lock_dir}/pid"
    if [[ -f "$lock_pid_file" ]]; then
      local lock_pid
      lock_pid=$(cat "$lock_pid_file" 2>/dev/null || echo "")
      if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
        rm -rf "$lock_dir"
        doctor_fix "Removed stale lock (PID $lock_pid dead)"
      else
        doctor_warn "Lock held by PID $lock_pid (running)"
      fi
    else
      # Lock dir exists but no PID file — likely stale
      rm -rf "$lock_dir"
      doctor_fix "Removed stale lock (no PID file)"
    fi
  fi
}

# --- Check: Manager agent (bare-metal OpenClaw) ---

doctor_check_manager() {
  echo ""
  echo -e "${BOLD}Manager Agent${NC}"

  # OpenClaw CLI
  if command -v openclaw &>/dev/null; then
    local oc_version
    oc_version=$(openclaw --version 2>/dev/null || echo "unknown")
    doctor_pass "OpenClaw CLI: $oc_version"
  else
    doctor_warn "OpenClaw CLI not installed (manager features unavailable)"
    return
  fi

  # Gateway running
  if pgrep -f "openclaw.*gateway" &>/dev/null; then
    doctor_pass "Gateway process running"
  else
    # Try to start it
    if openclaw gateway start &>/dev/null 2>&1; then
      sleep 3
      if pgrep -f "openclaw.*gateway" &>/dev/null; then
        doctor_fix "Gateway was stopped — started it"
      else
        doctor_fail "Gateway failed to start"
      fi
    else
      doctor_fail "Gateway not running and could not start"
    fi
  fi

  # Gateway healthz
  local gw_port
  gw_port=$(jq -r '.gateway.port // 18789' ~/.openclaw/openclaw.json 2>/dev/null || echo 18789)
  if curl -sf --max-time 5 "http://127.0.0.1:${gw_port}/healthz" &>/dev/null; then
    doctor_pass "Gateway HTTP healthy (port $gw_port)"
  else
    # Gateway process may be running but not responding — restart
    if pgrep -f "openclaw.*gateway" &>/dev/null; then
      openclaw gateway restart &>/dev/null 2>&1 || true
      sleep 5
      if curl -sf --max-time 5 "http://127.0.0.1:${gw_port}/healthz" &>/dev/null; then
        doctor_fix "Gateway was unresponsive — restarted"
      else
        doctor_fail "Gateway not responding on port $gw_port after restart"
      fi
    else
      doctor_fail "Gateway not responding on port $gw_port"
    fi
  fi

  # Telegram connectivity
  local tg_token
  tg_token=$(jq -r '.channels.telegram.botToken // empty' ~/.openclaw/openclaw.json 2>/dev/null)
  if [[ -n "$tg_token" ]]; then
    local tg_check
    tg_check=$(curl -sf --max-time 10 "https://api.telegram.org/bot${tg_token}/getMe" 2>/dev/null)
    if [[ -n "$tg_check" ]] && echo "$tg_check" | jq -e '.ok' &>/dev/null; then
      local bot_username
      bot_username=$(echo "$tg_check" | jq -r '.result.username // "unknown"')
      doctor_pass "Telegram bot: @${bot_username}"
    else
      doctor_fail "Telegram bot token invalid or API unreachable"
    fi
  else
    doctor_warn "No Telegram bot configured for manager"
  fi

  # Workspace files
  local ws=~/.openclaw/workspace
  local required_files=("IDENTITY.md" "TOOLS.md" "HEARTBEAT.md" "MEMORY.md")
  for f in "${required_files[@]}"; do
    if [[ -f "${ws}/${f}" ]] && [[ -s "${ws}/${f}" ]]; then
      doctor_pass "Workspace: ${f}"
    else
      # Auto-create MEMORY.md if missing
      if [[ "$f" == "MEMORY.md" ]]; then
        local manager_name
        manager_name=$(get_fleet_manager_name 2>/dev/null || echo "fleet")
        cat > "${ws}/MEMORY.md" <<MEMEOF
# Memory

## Fleet
- Manager: ${manager_name}
- Fleet dir: ${FLEET_DIR}
MEMEOF
        doctor_fix "Created missing ${f}"
      else
        doctor_warn "Workspace: ${f} missing or empty"
      fi
    fi
  done

  # Tool profile should be 'full' for fleet management
  local tool_profile
  tool_profile=$(jq -r '.tools.profile // "messaging"' ~/.openclaw/openclaw.json 2>/dev/null)
  if [[ "$tool_profile" == "full" ]]; then
    doctor_pass "Tool profile: full"
  else
    openclaw config set tools.profile full &>/dev/null 2>&1 || true
    doctor_fix "Tool profile was '$tool_profile' — set to 'full'"
  fi
}

# --- Check: AI provider connectivity ---

doctor_check_providers() {
  echo ""
  echo -e "${BOLD}AI Providers${NC}"

  local providers_file="${FLEET_DIR}/agents/providers.json"
  if [[ ! -f "$providers_file" ]]; then
    doctor_warn "No providers configured"
    return
  fi

  local names
  names=$(jq -r '.subscriptions | keys[]' "$providers_file" 2>/dev/null)
  if [[ -z "$names" ]]; then
    doctor_warn "No subscriptions in providers.json"
    return
  fi

  for name in $names; do
    local ptype
    ptype=$(jq -r --arg n "$name" '.subscriptions[$n].type' "$providers_file")
    local api_key
    api_key=$(jq -r --arg n "$name" '.subscriptions[$n].apiKey' "$providers_file")
    local base_url
    base_url=$(jq -r --arg n "$name" '.subscriptions[$n].baseUrl // empty' "$providers_file")

    # Resolve secret
    local resolved_key
    resolved_key=$(resolve_secret "$api_key" 2>/dev/null)
    if [[ $? -ne 0 ]] || [[ -z "$resolved_key" ]]; then
      doctor_fail "Provider '$name': cannot resolve API key"
      continue
    fi

    # Test connectivity based on provider type
    local test_url=""
    local auth_header=""
    case "$ptype" in
      anthropic)
        test_url="https://api.anthropic.com/v1/models"
        auth_header="x-api-key: ${resolved_key}"
        ;;
      openai)
        test_url="https://api.openai.com/v1/models"
        auth_header="Authorization: Bearer ${resolved_key}"
        ;;
      google)
        test_url="https://generativelanguage.googleapis.com/v1beta/models?key=${resolved_key}"
        ;;
      zai)
        test_url="${base_url:-https://api.z.ai/api/coding/paas/v4}/models"
        auth_header="Authorization: Bearer ${resolved_key}"
        ;;
      openrouter)
        test_url="https://openrouter.ai/api/v1/models"
        auth_header="Authorization: Bearer ${resolved_key}"
        ;;
      ollama)
        test_url="${base_url:-http://localhost:11434}/api/tags"
        ;;
      *)
        if [[ -n "$base_url" ]]; then
          test_url="${base_url}/models"
          auth_header="Authorization: Bearer ${resolved_key}"
        fi
        ;;
    esac

    if [[ -n "$test_url" ]]; then
      local http_code
      if [[ -n "$auth_header" ]]; then
        http_code=$(curl -sf --max-time 10 -o /dev/null -w "%{http_code}" \
          "$test_url" -H @<(echo "$auth_header") 2>/dev/null || echo "000")
      else
        http_code=$(curl -sf --max-time 10 -o /dev/null -w "%{http_code}" \
          "$test_url" 2>/dev/null || echo "000")
      fi

      case "$http_code" in
        200) doctor_pass "Provider '$name' ($ptype): connected" ;;
        401) doctor_fail "Provider '$name' ($ptype): invalid API key (401)" ;;
        403) doctor_fail "Provider '$name' ($ptype): access denied (403)" ;;
        429) doctor_warn "Provider '$name' ($ptype): rate limited (429)" ;;
        000) doctor_fail "Provider '$name' ($ptype): unreachable (network error)" ;;
        *)   doctor_warn "Provider '$name' ($ptype): HTTP $http_code" ;;
      esac
    else
      doctor_warn "Provider '$name' ($ptype): no test URL available"
    fi
  done
}

# --- Check: Container agents ---

doctor_check_agents() {
  echo ""
  echo -e "${BOLD}Container Agents${NC}"

  local agent_count
  agent_count=$(registry_list_agents 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$agent_count" -eq 0 ]]; then
    doctor_pass "No agents registered (fleet is empty)"
    return
  fi

  for name in $(registry_list_agents); do
    local agent_info
    agent_info=$(registry_get_agent "$name")
    local reg_state
    reg_state=$(echo "$agent_info" | jq -r '.state // "unknown"')
    local gw_port
    gw_port=$(echo "$agent_info" | jq -r '.gatewayPort')
    local agent_dir="${FLEET_DIR}/agents/${name}"

    echo ""
    echo -e "  ${BOLD}${name}${NC} (port $gw_port, registry: $reg_state)"

    # --- Files ---

    if [[ ! -d "$agent_dir" ]]; then
      doctor_fail "  Agent directory missing: $agent_dir"
      continue
    fi

    if [[ ! -f "${agent_dir}/docker-compose.yml" ]]; then
      doctor_fail "  docker-compose.yml missing"
      continue
    fi

    if [[ ! -f "${agent_dir}/.env" ]]; then
      doctor_fail "  .env file missing"
    else
      local env_perms
      if [[ "$PLATFORM" == "darwin" ]]; then
        env_perms=$(stat -f %Lp "${agent_dir}/.env" 2>/dev/null)
      else
        env_perms=$(stat -c %a "${agent_dir}/.env" 2>/dev/null)
      fi
      if [[ "$env_perms" != "600" ]]; then
        chmod 600 "${agent_dir}/.env"
        doctor_fix "  .env permissions: $env_perms -> 600"
      fi
    fi

    if [[ ! -f "${agent_dir}/config/openclaw.json" ]]; then
      doctor_fail "  openclaw.json missing"
      continue
    else
      if ! jq empty "${agent_dir}/config/openclaw.json" 2>/dev/null; then
        doctor_fail "  openclaw.json is corrupt JSON"
        continue
      fi
    fi

    # --- Skip health checks if agent should be stopped ---
    if [[ "$reg_state" == "stopped" ]] || [[ "$reg_state" == "killed" ]]; then
      doctor_pass "  Intentionally $reg_state"
      continue
    fi

    # --- Container state ---

    local container="openclaw_${name}"
    local docker_state
    docker_state=$(docker inspect "$container" --format '{{.State.Status}}' 2>/dev/null || echo "missing")

    if [[ "$docker_state" == "running" ]]; then
      # HTTP healthz
      if curl -sf --max-time 5 "http://127.0.0.1:${gw_port}/healthz" &>/dev/null; then
        doctor_pass "  Healthy (container running, HTTP ok)"
      else
        # Container running but HTTP failing — restart
        docker compose -f "${agent_dir}/docker-compose.yml" \
          --env-file "${agent_dir}/.env" \
          -p "openclaw-${name}" \
          restart 2>/dev/null || true

        # Wait and recheck
        sleep 10
        if curl -sf --max-time 5 "http://127.0.0.1:${gw_port}/healthz" &>/dev/null; then
          doctor_fix "  Was unresponsive — restarted and now healthy"
          registry_set_state "$name" "running" 2>/dev/null || true
        else
          doctor_fail "  Container running but HTTP unhealthy after restart"
          registry_set_state "$name" "unhealthy" 2>/dev/null || true
        fi
      fi

    elif [[ "$docker_state" == "exited" ]] || [[ "$docker_state" == "missing" ]]; then
      # Agent should be running but isn't — start it
      if start_agent "$name" 2>/dev/null; then
        # Wait for health
        local became_healthy=false
        for attempt in $(seq 1 6); do
          sleep 10
          if curl -sf --max-time 5 "http://127.0.0.1:${gw_port}/healthz" &>/dev/null; then
            became_healthy=true
            break
          fi
        done

        if [[ "$became_healthy" == "true" ]]; then
          doctor_fix "  Was $docker_state — started and now healthy"
          registry_set_state "$name" "running" 2>/dev/null || true
        else
          doctor_warn "  Started but not yet healthy (may still be initializing)"
          registry_set_state "$name" "running" 2>/dev/null || true
        fi
      else
        doctor_fail "  Container $docker_state and failed to start"
        registry_set_state "$name" "failed" 2>/dev/null || true
      fi

    else
      doctor_warn "  Container in unexpected state: $docker_state"
    fi

    # --- Registry sync ---
    if [[ "$docker_state" == "running" ]] && [[ "$reg_state" != "running" ]]; then
      registry_set_state "$name" "running" 2>/dev/null || true
      doctor_fix "  Registry state synced: $reg_state -> running"
    elif [[ "$docker_state" != "running" ]] && [[ "$reg_state" == "running" ]]; then
      # Only update if we didn't already fix it above
      local current_state
      current_state=$(docker inspect "$container" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
      if [[ "$current_state" != "running" ]]; then
        registry_set_state "$name" "stopped" 2>/dev/null || true
        doctor_fix "  Registry state synced: running -> stopped"
      fi
    fi

    # --- Telegram bot token validity ---
    local tg_token
    tg_token=$(jq -r '.channels.telegram.botToken // empty' "${agent_dir}/config/openclaw.json" 2>/dev/null)
    if [[ -n "$tg_token" ]]; then
      local tg_check
      tg_check=$(curl -sf --max-time 5 "https://api.telegram.org/bot${tg_token}/getMe" 2>/dev/null)
      if [[ -n "$tg_check" ]] && echo "$tg_check" | jq -e '.ok' &>/dev/null; then
        local bot_user
        bot_user=$(echo "$tg_check" | jq -r '.result.username // "?"')
        doctor_pass "  Telegram: @${bot_user}"

        # Update bot name in registry if missing
        local reg_bot
        reg_bot=$(echo "$agent_info" | jq -r '.telegramBot // ""')
        if [[ -z "$reg_bot" ]] || [[ "$reg_bot" == "-" ]]; then
          local updated
          updated=$(jq --arg name "$name" --arg bot "@${bot_user}" \
            '.agents[$name].telegramBot = $bot' "$REGISTRY_FILE")
          atomic_json_write "$REGISTRY_FILE" "$updated" 2>/dev/null || true
          doctor_fix "  Registry: saved bot name @${bot_user}"
        fi
      else
        doctor_warn "  Telegram: bot token invalid or API unreachable"
      fi
    fi
  done

  # --- Orphan containers ---
  echo ""
  local fleet_containers
  fleet_containers=$(docker ps -a --filter "name=openclaw_" --format '{{.Names}}' 2>/dev/null || true)
  local orphans=0
  for container in $fleet_containers; do
    local agent_name="${container#openclaw_}"
    if [[ "$(registry_get_agent "$agent_name")" == "null" ]]; then
      doctor_warn "Orphan container: $container (not in registry)"
      orphans=$((orphans + 1))
    fi
  done
  if [[ $orphans -eq 0 ]]; then
    doctor_pass "No orphan containers"
  fi
}

# --- Check: Cron jobs ---

doctor_check_cron() {
  echo ""
  echo -e "${BOLD}Automation${NC}"

  local crontab_content
  crontab_content=$(crontab -l 2>/dev/null || echo "")

  # Watchdog
  if echo "$crontab_content" | grep -q "fleet.sh watchdog"; then
    doctor_pass "Watchdog cron installed"
  else
    doctor_warn "Watchdog cron not installed — run: fleet watchdog install"
  fi

  # Maintenance
  if echo "$crontab_content" | grep -q "fleet.sh maintain"; then
    doctor_pass "Maintenance cron installed"
  else
    doctor_warn "Maintenance cron not installed — run: fleet maintain install"
  fi

  # Backup freshness
  local backup_dir="${FLEET_DIR}/backups"
  if [[ -d "$backup_dir" ]]; then
    local latest_backup
    latest_backup=$(ls -t "$backup_dir"/fleet_*.tar.gz 2>/dev/null | head -1)
    if [[ -n "$latest_backup" ]]; then
      local backup_age_days
      if [[ "$PLATFORM" == "darwin" ]]; then
        local backup_epoch
        backup_epoch=$(stat -f %m "$latest_backup" 2>/dev/null || echo 0)
        local now_epoch
        now_epoch=$(date +%s)
        backup_age_days=$(( (now_epoch - backup_epoch) / 86400 ))
      else
        backup_age_days=$(( ( $(date +%s) - $(stat -c %Y "$latest_backup" 2>/dev/null || echo 0) ) / 86400 ))
      fi

      if [[ $backup_age_days -le 1 ]]; then
        doctor_pass "Latest backup: today"
      elif [[ $backup_age_days -le 7 ]]; then
        doctor_pass "Latest backup: ${backup_age_days}d ago"
      else
        doctor_warn "Latest backup is ${backup_age_days}d old"
      fi
    else
      doctor_warn "No fleet backups found"
    fi
  else
    doctor_warn "No backups directory"
  fi
}

# --- Check: Docker resources ---

doctor_check_resources() {
  echo ""
  echo -e "${BOLD}Resources${NC}"

  # Docker disk usage
  local docker_usage
  docker_usage=$(docker system df --format '{{.Type}}\t{{.Size}}\t{{.Reclaimable}}' 2>/dev/null)
  if [[ -n "$docker_usage" ]]; then
    local images_size
    images_size=$(echo "$docker_usage" | grep "Images" | awk '{print $2}')
    local containers_size
    containers_size=$(echo "$docker_usage" | grep "Containers" | awk '{print $2}')
    doctor_pass "Docker images: ${images_size:-?}, containers: ${containers_size:-?}"
  fi

  # Dangling images
  local dangling
  dangling=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$dangling" -gt 5 ]]; then
    docker image prune -f --filter "until=48h" &>/dev/null
    doctor_fix "Pruned $dangling dangling Docker images"
  elif [[ "$dangling" -gt 0 ]]; then
    doctor_pass "Dangling images: $dangling (low, skipping prune)"
  else
    doctor_pass "No dangling images"
  fi

  # Capacity
  if command -v bc &>/dev/null; then
    local result
    result=$(max_agents 2>/dev/null)
    local recommended
    recommended=$(echo "$result" | cut -d: -f2)
    local agent_count
    agent_count=$(registry_list_agents 2>/dev/null | wc -l | tr -d ' ')
    local remaining=$((recommended - agent_count))

    if [[ $remaining -ge 1 ]]; then
      doctor_pass "Capacity: ${agent_count}/${recommended} agents (${remaining} slots free)"
    elif [[ $remaining -eq 0 ]]; then
      doctor_warn "Capacity: at recommended limit (${agent_count}/${recommended})"
    else
      doctor_warn "Capacity: over recommended limit (${agent_count}/${recommended})"
    fi
  fi
}

# --- Main orchestrator ---

doctor_run() {
  local heal="${1:-true}"

  echo ""
  echo -e "${BOLD}Fleet Doctor${NC}"
  echo -e "${BOLD}$(printf '=%.0s' {1..40})${NC}"

  if [[ "$heal" == "false" ]]; then
    echo -e "  Mode: ${YELLOW}diagnose only${NC} (no auto-fix)"
  else
    echo -e "  Mode: ${GREEN}diagnose + heal${NC}"
  fi

  doctor_check_deps
  doctor_check_fleet_config
  doctor_check_manager
  doctor_check_providers
  doctor_check_agents
  doctor_check_cron
  doctor_check_resources

  # --- Summary ---
  echo ""
  echo -e "${BOLD}$(printf '=%.0s' {1..40})${NC}"
  echo -e "${BOLD}Summary${NC}"
  echo "  Checks:   $DOCTOR_CHECKS"
  echo -e "  Passed:   ${GREEN}$((DOCTOR_CHECKS - DOCTOR_ISSUES - DOCTOR_WARNINGS - DOCTOR_FIXED))${NC}"
  echo -e "  Fixed:    ${CYAN}${DOCTOR_FIXED}${NC}"
  echo -e "  Warnings: ${YELLOW}${DOCTOR_WARNINGS}${NC}"
  echo -e "  Issues:   ${RED}${DOCTOR_ISSUES}${NC}"

  if [[ $DOCTOR_ISSUES -eq 0 ]] && [[ $DOCTOR_WARNINGS -eq 0 ]]; then
    echo ""
    echo -e "  ${GREEN}Fleet is healthy.${NC}"
  elif [[ $DOCTOR_ISSUES -eq 0 ]]; then
    echo ""
    echo -e "  ${YELLOW}Fleet is operational with minor warnings.${NC}"
  else
    echo ""
    echo -e "  ${RED}Fleet has issues that need attention.${NC}"
  fi
  echo ""

  return $( [[ $DOCTOR_ISSUES -eq 0 ]] && echo 0 || echo 1 )
}
