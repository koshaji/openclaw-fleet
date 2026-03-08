#!/usr/bin/env bash
# health.sh — Health checks, status reporting, monitoring

# Check a single agent's health
check_agent_health() {
  local name="$1"
  local agent_info
  agent_info=$(registry_get_agent "$name")

  if [[ "$agent_info" == "null" ]]; then
    echo "unknown"
    return
  fi

  local gateway_port
  gateway_port=$(echo "$agent_info" | jq -r '.gatewayPort')

  # Check container status
  local container_state
  container_state=$(docker inspect "openclaw_${name}" --format '{{.State.Status}}' 2>/dev/null || echo "missing")

  if [[ "$container_state" != "running" ]]; then
    echo "stopped"
    return
  fi

  # Check HTTP health
  if curl -sf --max-time 5 "http://127.0.0.1:${gateway_port}/healthz" &>/dev/null; then
    echo "healthy"
  else
    echo "unhealthy"
  fi
}

# Deep health check — includes Telegram connectivity
deep_health_check() {
  local name="$1"
  local agent_dir="${FLEET_DIR}/agents/${name}"

  local basic_health
  basic_health=$(check_agent_health "$name")

  if [[ "$basic_health" != "healthy" ]]; then
    echo "$basic_health"
    return
  fi

  # Check Telegram via agent CLI
  local health_output
  health_output=$(agent_exec "$name" health 2>&1 || true)

  if echo "$health_output" | grep -q "Telegram: ok"; then
    echo "healthy+telegram"
  elif echo "$health_output" | grep -q "Telegram:"; then
    echo "healthy-telegram_disconnected"
  else
    echo "healthy"
  fi
}

# Get container uptime
get_uptime() {
  local name="$1"
  local started
  started=$(docker inspect "openclaw_${name}" --format '{{.State.StartedAt}}' 2>/dev/null || echo "")

  if [[ -z "$started" ]] || [[ "$started" == "0001-01-01T00:00:00Z" ]]; then
    echo "-"
    return
  fi

  local now
  now=$(date +%s)
  local start_epoch

  if [[ "$PLATFORM" == "darwin" ]]; then
    start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${started%%.*}" +%s 2>/dev/null || echo "0")
  else
    start_epoch=$(date -d "$started" +%s 2>/dev/null || echo "0")
  fi

  if [[ "$start_epoch" == "0" ]]; then
    echo "?"
    return
  fi

  local diff=$((now - start_epoch))
  if [[ $diff -lt 60 ]]; then
    echo "${diff}s"
  elif [[ $diff -lt 3600 ]]; then
    echo "$((diff / 60))m"
  elif [[ $diff -lt 86400 ]]; then
    echo "$((diff / 3600))h"
  else
    echo "$((diff / 86400))d $((diff % 86400 / 3600))h"
  fi
}

# Print status table for all agents
print_status_table() {
  local deep="${1:-false}"

  echo ""
  echo -e "${BOLD}OpenClaw Fleet Status${NC}"
  echo -e "${BOLD}$(printf '=%.0s' {1..78})${NC}"
  table_row "AGENT" "STATUS" "GW PORT" "BR PORT" "TELEGRAM" "UPTIME"
  echo "  $(printf -- '-%.0s' {1..76})"

  for name in $(registry_list_agents); do
    local agent_info
    agent_info=$(registry_get_agent "$name")
    local gw_port
    gw_port=$(echo "$agent_info" | jq -r '.gatewayPort')
    local br_port
    br_port=$(echo "$agent_info" | jq -r '.bridgePort')
    local bot
    bot=$(echo "$agent_info" | jq -r '.telegramBot // "-"')

    local health
    if [[ "$deep" == "true" ]]; then
      health=$(deep_health_check "$name")
    else
      health=$(check_agent_health "$name")
    fi

    local uptime
    uptime=$(get_uptime "$name")

    # Colorize status
    local status_display
    case "$health" in
      healthy|healthy+telegram)
        status_display="${GREEN}healthy${NC}" ;;
      healthy-telegram_disconnected)
        status_display="${YELLOW}tg-disc${NC}" ;;
      unhealthy)
        status_display="${RED}unhealthy${NC}" ;;
      stopped)
        status_display="${RED}stopped${NC}" ;;
      *)
        status_display="${YELLOW}${health}${NC}" ;;
    esac

    # Telegram status
    local tg_display
    case "$health" in
      healthy+telegram)       tg_display="${GREEN}connected${NC}" ;;
      healthy-telegram_disconnected) tg_display="${RED}disconnected${NC}" ;;
      *)                      tg_display="-" ;;
    esac

    printf "  ${BOLD}%-12s${NC} %-20b %-8s %-8s %-24b %-20s\n" \
      "$name" "$status_display" "$gw_port" "$br_port" "$tg_display" "$uptime"
  done

  echo ""

  # Fleet summary
  local total
  total=$(registry_list_agents | wc -l | tr -d ' ')
  local running=0
  for name in $(registry_list_agents); do
    local h
    h=$(check_agent_health "$name")
    [[ "$h" == "healthy" || "$h" == "healthy+telegram" ]] && running=$((running + 1))
  done
  echo -e "  Total: ${BOLD}${total}${NC}  Running: ${GREEN}${running}${NC}  Stopped: ${RED}$((total - running))${NC}"
  echo ""
}

# Print status as JSON (for scripting/watchdog)
print_status_json() {
  local result='{"agents":{},"timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}'

  for name in $(registry_list_agents); do
    local health
    health=$(check_agent_health "$name")
    local uptime
    uptime=$(get_uptime "$name")
    local agent_info
    agent_info=$(registry_get_agent "$name")

    result=$(echo "$result" | jq \
      --arg name "$name" \
      --arg health "$health" \
      --arg uptime "$uptime" \
      --argjson info "$agent_info" \
      '.agents[$name] = ($info + {health: $health, uptime: $uptime})')
  done

  echo "$result" | jq .
}

# Watchdog: check all agents, restart unhealthy ones
watchdog_check() {
  local log_file="${FLEET_DIR}/agents/watchdog.log"
  local max_unhealthy="${1:-3}"

  for name in $(registry_list_agents); do
    local health
    health=$(check_agent_health "$name")
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    echo "${timestamp} ${name} ${health}" >> "$log_file"

    if [[ "$health" == "unhealthy" ]] || [[ "$health" == "stopped" ]]; then
      # Count recent unhealthy checks
      local recent_failures
      recent_failures=$(tail -20 "$log_file" 2>/dev/null | grep "$name" | grep -c -E "unhealthy|stopped" || echo 0)

      if [[ $recent_failures -ge $max_unhealthy ]]; then
        log_warn "Agent '$name' has been unhealthy for $recent_failures checks. Attempting restart..."
        restart_agent "$name" 2>/dev/null || log_error "Failed to restart agent '$name'"
        echo "${timestamp} ${name} auto-restart-attempted" >> "$log_file"
      fi
    fi
  done

  # Rotate watchdog log (keep last 1000 lines)
  if [[ -f "$log_file" ]] && [[ $(wc -l < "$log_file") -gt 1000 ]]; then
    tail -500 "$log_file" > "${log_file}.tmp"
    mv "${log_file}.tmp" "$log_file"
  fi
}
