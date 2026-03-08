#!/usr/bin/env bash
# naming.sh — Agent naming system
#
# The fleet manager agent (the host OpenClaw instance overseeing the fleet)
# is identified by FLEET_MANAGER_NAME in .env.fleet. On this machine it's
# "mini4", but on other machines it can be anything.
#
# Docker agents can be named:
#   1. Explicitly: --name research-bot
#   2. By role: --role researcher (generates a name like "researcher-1")
#   3. Auto-generated: picks from a pool of meaningful names

# Name pool — short, memorable, distinct names for agents
# Inspired by team roles / archetypes
NAME_POOL=(
  scout relay cipher pulse drift
  ember forge spark flint anvil
  sage oracle herald scribe warden
  hawk falcon raven swift talon
  nexus core prism echo node
  atlas titan apex vega nova
  bolt surge flux arc beam
  reef coral tide crest wave
)

# Get next available name from pool
auto_name() {
  local prefix="${1:-}"

  if [[ -n "$prefix" ]]; then
    # Role-based: find next available number
    local i=1
    while true; do
      local candidate="${prefix}-${i}"
      if [[ "$(registry_get_agent "$candidate")" == "null" ]]; then
        echo "$candidate"
        return
      fi
      i=$((i + 1))
    done
  fi

  # Pick from name pool
  local existing
  existing=$(registry_list_agents 2>/dev/null)

  for name in "${NAME_POOL[@]}"; do
    if ! echo "$existing" | grep -qx "$name"; then
      echo "$name"
      return
    fi
  done

  # Fallback: agent + number
  auto_name "agent"
}

# Validate agent name
validate_name() {
  local name="$1"
  if [[ ! "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
    log_error "Invalid agent name '$name'. Must start with a letter, contain only letters, numbers, hyphens, underscores."
    return 1
  fi
  if [[ ${#name} -gt 30 ]]; then
    log_error "Agent name '$name' too long (max 30 chars)."
    return 1
  fi
  if [[ "$(registry_get_agent "$name")" != "null" ]]; then
    log_error "Agent name '$name' already exists."
    return 1
  fi
  return 0
}

# Get available names from the pool (not yet in use)
get_available_names() {
  local existing
  existing=$(registry_list_agents 2>/dev/null)
  local available; available=()

  for name in "${NAME_POOL[@]}"; do
    if ! echo "$existing" | grep -qx "$name"; then
      available+=("$name")
    fi
  done

  echo "${available[*]}"
}

# Interactive name picker — shows available names and lets user choose
# Usage: interactive_name_pick <agent_number> <total_count>
interactive_name_pick() {
  local agent_num="$1"
  local total="$2"
  local default
  default=$(auto_name)

  # Non-interactive mode: just return the default
  if [[ ! -t 0 ]]; then
    echo "$default"
    return
  fi

  local available
  available=$(get_available_names)

  # Show up to 12 available names
  local display_names
  display_names=$(echo "$available" | tr ' ' '\n' | head -12 | tr '\n' ' ')
  local total_available
  total_available=$(echo "$available" | wc -w | tr -d ' ')

  echo "" >&2
  if [[ $total_available -gt 12 ]]; then
    echo -e "  ${BOLD}Available names:${NC} ${display_names}(+$((total_available - 12)) more)" >&2
  else
    echo -e "  ${BOLD}Available names:${NC} ${display_names}" >&2
  fi

  while true; do
    echo -en "  ${CYAN}Name for agent ${agent_num}/${total} [${default}]: ${NC}" >&2
    read -r picked
    picked="${picked:-$default}"

    # Check if picked name is valid
    if [[ ! "$picked" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
      log_error "Must start with a letter, only letters/numbers/hyphens/underscores." >&2
      continue
    fi
    if [[ ${#picked} -gt 30 ]]; then
      log_error "Name too long (max 30 chars)." >&2
      continue
    fi
    if [[ "$(registry_get_agent "$picked")" != "null" ]]; then
      log_error "Name '$picked' already in use. Pick another." >&2
      continue
    fi

    echo "$picked"
    return
  done
}

# Get the fleet manager name (host agent that oversees the fleet)
get_fleet_manager_name() {
  echo "${FLEET_MANAGER_NAME:-mini4}"
}
