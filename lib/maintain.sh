#!/usr/bin/env bash
# maintain.sh — Daily fleet maintenance: health, cleanup, backup, security, reporting

MAINTAIN_LOG="${FLEET_DIR}/agents/maintain.log"
MAINTAIN_ISSUES=0
MAINTAIN_REPORT=""

# Append to maintenance log and report
maintain_log() {
  local level="$1"
  local msg="$2"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "${timestamp} [${level}] ${msg}" >> "$MAINTAIN_LOG"
  MAINTAIN_REPORT="${MAINTAIN_REPORT}${level}: ${msg}\n"
  if [[ "$level" == "WARN" ]] || [[ "$level" == "ERROR" ]]; then
    MAINTAIN_ISSUES=$((MAINTAIN_ISSUES + 1))
  fi
}

# Phase 1: Health and Recovery
maintain_health() {
  log_info "Phase 1: Health checks..."
  local total=0
  local healthy_count=0
  local recovered=0
  local still_bad=0

  for name in $(registry_list_agents); do
    total=$((total + 1))
    local health
    health=$(check_agent_health "$name")

    if [[ "$health" == "healthy" ]]; then
      healthy_count=$((healthy_count + 1))
      maintain_log "OK" "Agent '$name' healthy"
    else
      maintain_log "WARN" "Agent '$name' is $health — attempting restart"
      restart_agent "$name" 2>/dev/null || true

      # Wait and recheck
      sleep 15
      health=$(check_agent_health "$name")
      if [[ "$health" == "healthy" ]]; then
        recovered=$((recovered + 1))
        maintain_log "OK" "Agent '$name' recovered after restart"
      else
        still_bad=$((still_bad + 1))
        maintain_log "ERROR" "Agent '$name' still $health after restart"
      fi
    fi
  done

  # Reconcile registry with Docker state
  reconcile_registry 2>/dev/null || true

  maintain_log "INFO" "Health: ${total} agents, ${healthy_count} healthy, ${recovered} recovered, ${still_bad} still unhealthy"
}

# Phase 2: Check for updates (notify only, never auto-update)
maintain_check_updates() {
  log_info "Phase 2: Checking for updates..."
  local image="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw}:${OPENCLAW_IMAGE_TAG:-latest}"

  local local_digest
  local_digest=$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || echo "none")

  if [[ "$local_digest" == "none" ]]; then
    maintain_log "WARN" "OpenClaw image not found locally"
    return
  fi

  # Check registry for newer image (read-only, no pull)
  local remote_digest
  remote_digest=$(docker manifest inspect "$image" 2>/dev/null | jq -r '.config.digest // empty' 2>/dev/null || echo "")

  if [[ -z "$remote_digest" ]]; then
    maintain_log "INFO" "Could not check remote registry (network issue or unsupported)"
  elif [[ "$remote_digest" != "$local_digest" ]]; then
    maintain_log "INFO" "New OpenClaw image available. Run: ./fleet.sh update"
  else
    maintain_log "OK" "OpenClaw image is up to date"
  fi
}

# Phase 3: Cleanup
maintain_cleanup() {
  log_info "Phase 3: Cleanup..."
  local freed=""

  # Prune dangling Docker images (safe — only untagged/unused)
  freed=$(docker image prune -f --filter "until=48h" 2>/dev/null | grep -o '[0-9.]*[kMG]B' | tail -1 || echo "0B")
  maintain_log "INFO" "Docker image prune freed: ${freed:-0B}"

  # Rotate watchdog log
  local wdog_log="${FLEET_DIR}/agents/watchdog.log"
  if [[ -f "$wdog_log" ]] && [[ $(wc -l < "$wdog_log") -gt 500 ]]; then
    tail -200 "$wdog_log" > "${wdog_log}.tmp.$$"
    mv "${wdog_log}.tmp.$$" "$wdog_log"
    maintain_log "INFO" "Rotated watchdog.log"
  fi

  # Rotate watchdog cron log
  local wdog_cron="${FLEET_DIR}/agents/watchdog-cron.log"
  if [[ -f "$wdog_cron" ]] && [[ $(wc -l < "$wdog_cron") -gt 1000 ]]; then
    tail -200 "$wdog_cron" > "${wdog_cron}.tmp.$$"
    mv "${wdog_cron}.tmp.$$" "$wdog_cron"
    maintain_log "INFO" "Rotated watchdog-cron.log"
  fi

  # Rotate maintain log
  if [[ -f "$MAINTAIN_LOG" ]] && [[ $(wc -l < "$MAINTAIN_LOG") -gt 2000 ]]; then
    tail -500 "$MAINTAIN_LOG" > "${MAINTAIN_LOG}.tmp.$$"
    mv "${MAINTAIN_LOG}.tmp.$$" "$MAINTAIN_LOG"
    maintain_log "INFO" "Rotated maintain.log"
  fi

  # Rotate maintain cron log
  local maintain_cron="${FLEET_DIR}/agents/maintain-cron.log"
  if [[ -f "$maintain_cron" ]] && [[ $(wc -l < "$maintain_cron") -gt 1000 ]]; then
    tail -200 "$maintain_cron" > "${maintain_cron}.tmp.$$"
    mv "${maintain_cron}.tmp.$$" "$maintain_cron"
    maintain_log "INFO" "Rotated maintain-cron.log"
  fi

  # Clean old backups (keep last 7 days, but never delete if fewer than 2 remain)
  local backup_dir="${FLEET_DIR}/backups"
  if [[ -d "$backup_dir" ]]; then
    local backup_count
    backup_count=$(find "$backup_dir" -name "*.tar.gz" 2>/dev/null | wc -l | tr -d ' ')
    local old_backups
    old_backups=$(find "$backup_dir" -name "*.tar.gz" -mtime +7 2>/dev/null || true)
    local deleted=0

    for f in $old_backups; do
      if [[ $backup_count -le 2 ]]; then
        break
      fi
      rm -f "$f"
      deleted=$((deleted + 1))
      backup_count=$((backup_count - 1))
    done

    if [[ $deleted -gt 0 ]]; then
      maintain_log "INFO" "Removed $deleted old backup(s)"
    fi
  fi
}

# Phase 4: Backup
maintain_backup() {
  log_info "Phase 4: Backup..."
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_dir="${FLEET_DIR}/backups"
  mkdir -p "$backup_dir"

  # Fleet-level backup
  tar -czf "${backup_dir}/fleet_${timestamp}.tar.gz" \
    -C "$FLEET_DIR" \
    .env.fleet \
    agents/registry.json \
    agents/providers.json \
    2>/dev/null || true

  # Per-agent backup
  local backed_up=0
  for name in $(registry_list_agents); do
    local agent_dir="${FLEET_DIR}/agents/${name}"
    if [[ -d "$agent_dir" ]]; then
      tar -czf "${backup_dir}/${name}_${timestamp}.tar.gz" \
        -C "${FLEET_DIR}/agents" \
        "${name}/config" \
        "${name}/.env" \
        "${name}/docker-compose.yml" \
        2>/dev/null || true
      backed_up=$((backed_up + 1))
    fi
  done

  maintain_log "OK" "Backed up fleet config + $backed_up agent(s)"
}

# Phase 5: Security checks
maintain_security() {
  log_info "Phase 5: Security checks..."

  # Check 1Password connectivity if op:// refs are in use
  local providers_file="${FLEET_DIR}/agents/providers.json"
  if [[ -f "$providers_file" ]] && grep -q 'op://' "$providers_file" 2>/dev/null; then
    if op_available; then
      # Try resolving one reference to test access
      local test_ref
      test_ref=$(grep -o 'op://[^"]*' "$providers_file" | head -1)
      if [[ -n "$test_ref" ]] && resolve_secret "$test_ref" &>/dev/null; then
        maintain_log "OK" "1Password vault accessible"
      else
        maintain_log "ERROR" "1Password access failed — secrets may not resolve"
      fi
    else
      maintain_log "ERROR" "providers.json has op:// refs but 1Password CLI unavailable"
    fi
  else
    maintain_log "INFO" "1Password: not in use"
  fi

  # Check AgentGuard connectivity
  if agentguard_enabled; then
    if curl -sf --max-time 10 "${AGENTGUARD_API}/api/v1/health" \
        -H "X-API-Key: ${AGENTGUARD_API_KEY}" &>/dev/null; then
      maintain_log "OK" "AgentGuard API reachable"
    else
      maintain_log "WARN" "AgentGuard API unreachable"
    fi
  else
    maintain_log "INFO" "AgentGuard: not configured"
  fi

  # Check .env file permissions
  for name in $(registry_list_agents); do
    local env_file="${FLEET_DIR}/agents/${name}/.env"
    if [[ -f "$env_file" ]]; then
      local perms
      if [[ "$PLATFORM" == "darwin" ]]; then
        perms=$(stat -f %Lp "$env_file" 2>/dev/null)
      else
        perms=$(stat -c %a "$env_file" 2>/dev/null)
      fi
      if [[ "$perms" != "600" ]]; then
        maintain_log "WARN" "Agent '$name' .env has permissions $perms (expected 600)"
        chmod 600 "$env_file"
        maintain_log "INFO" "Fixed permissions on $name/.env"
      fi
    fi
  done
}

# Phase 6: Generate report
maintain_report() {
  local end_time
  end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  echo ""
  echo -e "${BOLD}=============================${NC}"
  echo -e "${BOLD}Fleet Maintenance Report${NC}"
  echo -e "${BOLD}=============================${NC}"
  echo "  Date: $end_time"
  echo "  Manager: $(get_fleet_manager_name)"

  # Agent summary
  local total=0
  local running=0
  for name in $(registry_list_agents); do
    total=$((total + 1))
    local state
    state=$(registry_get_agent "$name" | jq -r '.state // "unknown"')
    if [[ "$state" == "running" ]]; then
      running=$((running + 1))
    fi
  done
  echo "  Agents: $total total, $running running"

  # Issues
  if [[ $MAINTAIN_ISSUES -eq 0 ]]; then
    echo -e "  Issues: ${GREEN}0${NC}"
  else
    echo -e "  Issues: ${RED}${MAINTAIN_ISSUES}${NC}"
  fi

  echo -e "${BOLD}=============================${NC}"

  # Show issues if any
  if [[ $MAINTAIN_ISSUES -gt 0 ]]; then
    echo ""
    echo "Issues found:"
    echo -e "$MAINTAIN_REPORT" | grep -E "^(WARN|ERROR):" | while read -r line; do
      echo "  - $line"
    done
  fi

  echo ""
  echo "Full log: $MAINTAIN_LOG"

  # Log the report summary
  maintain_log "INFO" "Maintenance complete: $total agents, $MAINTAIN_ISSUES issues"

  return $( [[ $MAINTAIN_ISSUES -eq 0 ]] && echo 0 || echo 1 )
}

# Main orchestrator
maintain_run() {
  mkdir -p "$(dirname "$MAINTAIN_LOG")"
  maintain_log "INFO" "=== Maintenance run started ==="

  # Each phase is error-isolated
  maintain_health || maintain_log "ERROR" "Health phase failed unexpectedly"
  maintain_check_updates || maintain_log "ERROR" "Update check phase failed unexpectedly"
  maintain_cleanup || maintain_log "ERROR" "Cleanup phase failed unexpectedly"
  maintain_backup || maintain_log "ERROR" "Backup phase failed unexpectedly"
  maintain_security || maintain_log "ERROR" "Security check phase failed unexpectedly"

  maintain_report
}

# Cron management
maintain_install_cron() {
  local cron_cmd="0 4 * * * ${FLEET_DIR}/fleet.sh maintain run >> ${FLEET_DIR}/agents/maintain-cron.log 2>&1"
  (crontab -l 2>/dev/null | grep -v "fleet.sh maintain"; echo "$cron_cmd") | crontab -
  log_ok "Daily maintenance cron installed (runs at 04:00)"
}

maintain_uninstall_cron() {
  (crontab -l 2>/dev/null | grep -v "fleet.sh maintain") | crontab -
  log_ok "Daily maintenance cron removed"
}
