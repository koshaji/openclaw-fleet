#!/usr/bin/env bash
# common.sh — Shared functions: logging, colors, platform detection, locking

set -euo pipefail

# Secure default: new files are owner-only (rw-------)
umask 077

# Colors (disabled with --no-color or non-tty)
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_fatal() { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }

# Prompt to retry or skip (interactive recovery)
prompt_or_fail() {
  local msg="$1"
  local allow_skip="${2:-true}"
  log_error "$msg"
  if [[ ! -t 0 ]]; then
    # Non-interactive: fail immediately
    exit 1
  fi
  local options="[R]etry"
  [[ "$allow_skip" == "true" ]] && options="${options} / [S]kip"
  options="${options} / [Q]uit"
  echo -en "${YELLOW}${options}: ${NC}"
  read -r choice
  case "${choice,,}" in
    r|retry)  return 1 ;;  # Caller should retry
    s|skip)   return 0 ;;  # Caller should skip
    q|quit|*) exit 1 ;;
  esac
}

# Retry a command up to N times with interactive fallback
retry_or_skip() {
  local description="$1"
  shift
  local max_retries=3
  local attempt=0
  while true; do
    if "$@" 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    if [[ $attempt -ge $max_retries ]]; then
      if prompt_or_fail "${description} failed after ${max_retries} attempts."; then
        log_warn "Skipping: ${description}"
        return 0
      fi
      attempt=0  # Reset for another round of retries
    fi
  done
}

# Prompt for input with validation and retry
prompt_with_retry() {
  local prompt_msg="$1"
  local var_name="$2"
  local validation_regex="${3:-}"
  local allow_empty="${4:-false}"
  local max_attempts=3
  local attempt=0
  while true; do
    echo -en "  ${CYAN}${prompt_msg}: ${NC}"
    read -r input
    if [[ -z "$input" ]] && [[ "$allow_empty" == "true" ]]; then
      eval "$var_name=''"
      return 0
    fi
    if [[ -z "$input" ]]; then
      attempt=$((attempt + 1))
      if [[ $attempt -ge $max_attempts ]]; then
        if prompt_or_fail "No input provided after ${max_attempts} attempts."; then
          eval "$var_name=''"
          return 0
        fi
        attempt=0
      else
        log_warn "Input required. Try again."
      fi
      continue
    fi
    if [[ -n "$validation_regex" ]] && ! echo "$input" | grep -qE "$validation_regex"; then
      attempt=$((attempt + 1))
      if [[ $attempt -ge $max_attempts ]]; then
        if prompt_or_fail "Invalid format after ${max_attempts} attempts."; then
          eval "$var_name=''"
          return 0
        fi
        attempt=0
      else
        log_warn "Invalid format. Try again."
      fi
      continue
    fi
    eval "$var_name=\$input"
    return 0
  done
}

# Auto-install a dependency
auto_install_dep() {
  local cmd="$1"
  local brew_pkg="${2:-$cmd}"
  local apt_pkg="${3:-$cmd}"
  local url="${4:-}"

  if command -v "$cmd" &>/dev/null; then
    return 0
  fi

  log_warn "'$cmd' not found."

  # Try to auto-install
  if [[ "${PLATFORM:-}" == "darwin" ]]; then
    if command -v brew &>/dev/null; then
      log_info "Installing $cmd via Homebrew..."
      if brew install "$brew_pkg" 2>&1; then
        log_ok "$cmd installed"
        return 0
      fi
    fi
    # Try direct download methods for macOS without Homebrew
    case "$cmd" in
      jq)
        log_info "Installing jq via direct download..."
        local arch; arch=$(uname -m)
        local jq_url="https://github.com/jqlang/jq/releases/latest/download/jq-macos-${arch}"
        if curl -fsSL -o /usr/local/bin/jq "$jq_url" 2>/dev/null && chmod +x /usr/local/bin/jq 2>/dev/null; then
          log_ok "jq installed to /usr/local/bin/jq"
          return 0
        elif curl -fsSL -o /tmp/jq "$jq_url" 2>/dev/null && chmod +x /tmp/jq; then
          export PATH="/tmp:$PATH"
          log_ok "jq installed to /tmp/jq"
          return 0
        fi
        ;;
      docker)
        log_info "Docker Desktop must be installed manually."
        log_info "Download from: https://docs.docker.com/desktop/install/mac-install/"
        if [[ -t 0 ]]; then
          echo -en "${CYAN}Press Enter after installing Docker (or 's' to skip): ${NC}"
          read -r answer
          [[ "${answer,,}" == "s" ]] && return 1
          command -v docker &>/dev/null && return 0
        fi
        ;;
    esac
  elif command -v apt-get &>/dev/null; then
    log_info "Installing $cmd via apt..."
    if sudo apt-get install -y "$apt_pkg" 2>&1; then
      log_ok "$cmd installed"
      return 0
    fi
  elif command -v yum &>/dev/null; then
    log_info "Installing $cmd via yum..."
    if sudo yum install -y "$apt_pkg" 2>&1; then
      log_ok "$cmd installed"
      return 0
    fi
  fi

  if [[ -n "$url" ]]; then
    log_error "Could not auto-install '$cmd'. Install manually from: $url"
  else
    log_error "Could not auto-install '$cmd'."
  fi
  return 1
}

# Platform detection
detect_platform() {
  case "$(uname -s)" in
    Darwin) PLATFORM="darwin" ;;
    Linux)  PLATFORM="linux" ;;
    *)      log_fatal "Unsupported platform: $(uname -s)" ;;
  esac
  export PLATFORM
}

# Check required dependencies
require_cmd() {
  local cmd="$1"
  local install_hint="${2:-}"
  if ! command -v "$cmd" &>/dev/null; then
    if [[ -n "$install_hint" ]]; then
      log_fatal "'$cmd' is required but not found. Install with: $install_hint"
    else
      log_fatal "'$cmd' is required but not found."
    fi
  fi
}

check_dependencies() {
  auto_install_dep docker "docker" "docker.io" "https://docs.docker.com/get-docker/" || log_fatal "Docker is required."
  auto_install_dep jq "jq" "jq" "https://jqlang.github.io/jq/download/" || log_fatal "jq is required."
  if command -v bc &>/dev/null; then
    true
  else
    # bc is optional — use awk fallback
    log_info "bc not found, using awk for math operations"
  fi
  if ! docker info &>/dev/null 2>&1; then
    log_error "Docker daemon is not running."
    if [[ "${PLATFORM:-}" == "darwin" ]]; then
      log_info "Attempting to start Docker Desktop..."
      open -a Docker 2>/dev/null || true
      local tries=0
      while ! docker info &>/dev/null 2>&1; do
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
          log_fatal "Docker daemon did not start after 60 seconds. Start Docker Desktop manually."
        fi
        sleep 2
      done
      log_ok "Docker daemon started"
    else
      log_fatal "Start the Docker service: sudo systemctl start docker"
    fi
  fi
}

# File locking — cross-platform mutex using mkdir (atomic on all filesystems)
LOCK_DIR=""
acquire_lock() {
  LOCK_DIR="${FLEET_DIR}/agents/.fleet.lock"
  local retries=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    # Check for stale lock (PID-based detection)
    local lock_pid_file="${LOCK_DIR}/pid"
    if [[ -f "$lock_pid_file" ]]; then
      local lock_pid
      lock_pid=$(cat "$lock_pid_file" 2>/dev/null || echo "")
      if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
        log_warn "Removing stale lock (PID $lock_pid no longer running)"
        rm -rf "$LOCK_DIR"
        continue
      fi
    fi
    retries=$((retries + 1))
    if [[ $retries -ge 30 ]]; then
      log_fatal "Could not acquire fleet lock after 30 seconds. Another fleet.sh may be running. Remove ${LOCK_DIR} if stale."
    fi
    sleep 1
  done
  # Write our PID for stale lock detection
  echo $$ > "${LOCK_DIR}/pid" 2>/dev/null || true
  # Clean up lock on exit (preserve existing traps)
  local existing_trap
  existing_trap=$(trap -p EXIT 2>/dev/null | sed "s/trap -- '\\(.*\\)' EXIT/\\1/" || true)
  if [[ -n "$existing_trap" ]]; then
    trap "release_lock; $existing_trap" EXIT INT TERM
  else
    trap 'release_lock' EXIT INT TERM
  fi
}

release_lock() {
  if [[ -n "$LOCK_DIR" ]] && [[ -d "$LOCK_DIR" ]]; then
    rm -f "${LOCK_DIR}/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

# Atomic JSON write — write to tmp, validate, then mv
atomic_json_write() {
  local target="$1"
  local content="$2"
  local tmp="${target}.tmp.$$"
  local backup="${target}.bak"

  # Validate JSON before writing
  if ! echo "$content" | jq empty 2>/dev/null; then
    log_error "Invalid JSON — refusing to write to $target"
    return 1
  fi

  # Backup current file
  if [[ -f "$target" ]]; then
    cp "$target" "$backup"
  fi

  # Atomic write (600 permissions enforced before mv)
  printf '%s\n' "$content" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$target"
}

# Generate a random hex token
generate_token() {
  openssl rand -hex 32 2>/dev/null || python3 -c "import secrets; print(secrets.token_hex(32))"
}

# Check if a port is available on localhost
port_is_free() {
  local port="$1"
  if [[ "$PLATFORM" == "darwin" ]]; then
    ! lsof -i :"$port" &>/dev/null
  else
    ! ss -tln 2>/dev/null | grep -qE ":${port}([[:space:]]|$)"
  fi
}

# Print a formatted table row
table_row() {
  printf "  ${BOLD}%-12s${NC} %-10s %-8s %-8s %-14s %-20s\n" "$@"
}

# Confirm prompt (returns 0 for yes, 1 for no)
confirm() {
  local msg="${1:-Continue?}"
  echo -en "${YELLOW}${msg} [y/N]${NC} "
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

# Staggered delay between operations
stagger_delay() {
  local delay="${1:-3}"
  log_info "Waiting ${delay}s before next operation..."
  sleep "$delay"
}
