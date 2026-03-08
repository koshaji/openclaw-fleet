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
  require_cmd docker "https://docs.docker.com/get-docker/"
  require_cmd jq "brew install jq (macOS) or apt-get install jq (Linux)"
  if ! docker info &>/dev/null; then
    log_fatal "Docker daemon is not running. Start Docker Desktop or the Docker service."
  fi
}

# File locking — cross-platform mutex using mkdir (atomic on all filesystems)
LOCK_DIR=""
acquire_lock() {
  LOCK_DIR="${FLEET_DIR}/agents/.fleet.lock"
  local retries=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    retries=$((retries + 1))
    if [[ $retries -ge 30 ]]; then
      log_fatal "Could not acquire fleet lock after 30 seconds. Another fleet.sh may be running. Remove ${LOCK_DIR} if stale."
    fi
    sleep 1
  done
  # Clean up lock on exit
  trap 'release_lock' EXIT INT TERM
}

release_lock() {
  if [[ -n "$LOCK_DIR" ]] && [[ -d "$LOCK_DIR" ]]; then
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
  echo "$content" > "$tmp"
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
    ! ss -tln 2>/dev/null | grep -q ":${port} "
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
