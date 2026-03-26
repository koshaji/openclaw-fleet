#!/usr/bin/env bash
# doctor-os.sh — OS-level fleet node diagnostics
# Sourced by fleet.sh to extend doctor.sh with macOS health checks.

# ---------------------------------------------------------------------------
# Output helpers — reuse doctor.sh symbols if already loaded, else define them
# ---------------------------------------------------------------------------
_doc_pass()  { printf "  \033[32m✓\033[0m  %s\n" "$*"; }
_doc_warn()  { printf "  \033[33m!\033[0m  %s\n" "$*"; }
_doc_fail()  { printf "  \033[31m✗\033[0m  %s\n" "$*"; }
_doc_fix()   { printf "  \033[36m⟳\033[0m  %s\n" "$*"; }

doctor_pass() { if command -v _doctor_pass &>/dev/null; then _doctor_pass "$@"; else _doc_pass "$@"; fi; }
doctor_warn() { if command -v _doctor_warn &>/dev/null; then _doctor_warn "$@"; else _doc_warn "$@"; fi; }
doctor_fail() { if command -v _doctor_fail &>/dev/null; then _doctor_fail "$@"; else _doc_fail "$@"; fi; }
doctor_fix()  { if command -v _doctor_fix  &>/dev/null; then _doctor_fix  "$@"; else _doc_fix  "$@"; fi; }

# ---------------------------------------------------------------------------
# Individual checks
# ---------------------------------------------------------------------------

check_filevault() {
  local status
  status=$(fdesetup status 2>/dev/null)
  if echo "$status" | grep -qi "On"; then
    doctor_pass "FileVault is On"
  else
    doctor_fail "FileVault is Off — enable via System Settings > Privacy & Security"
  fi
}

check_firewall() {
  local state
  state=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null)
  if echo "$state" | grep -qi "enabled"; then
    doctor_pass "Firewall is enabled"
  else
    doctor_fail "Firewall is disabled"
    doctor_fix "Enabling firewall..."
    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on 2>/dev/null \
      && doctor_pass "Firewall enabled" \
      || doctor_fail "Could not enable firewall (need sudo)"
  fi
}

check_auto_login() {
  local user
  user=$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)
  if [[ -n "$user" ]]; then
    doctor_pass "Auto-login configured for: $user"
  else
    doctor_fail "Auto-login is not set — required for unattended boot"
  fi
}

check_auto_restart() {
  local val
  val=$(pmset -g 2>/dev/null | grep autorestart | awk '{print $2}')
  if [[ "$val" == "1" ]]; then
    doctor_pass "Auto-restart on power loss is enabled"
  else
    doctor_fail "Auto-restart on power loss is disabled"
    doctor_fix "Enabling auto-restart on power loss..."
    sudo pmset -a autorestart 1 2>/dev/null \
      && doctor_pass "Auto-restart enabled" \
      || doctor_fail "Could not set autorestart (need sudo)"
  fi
}

check_sleep_disabled() {
  # Match " sleep" with leading space to avoid "displaysleep" / "disksleep"
  local val
  val=$(pmset -g 2>/dev/null | grep " sleep" | head -1 | awk '{print $NF}')
  if [[ "$val" == "0" ]]; then
    doctor_pass "System sleep is disabled"
  else
    doctor_warn "System sleep is set to ${val:-unknown} minutes"
    doctor_fix "Disabling system sleep..."
    sudo pmset -a sleep 0 2>/dev/null \
      && doctor_pass "System sleep disabled" \
      || doctor_fail "Could not disable sleep (need sudo)"
  fi
}

check_ssh() {
  local state
  state=$(systemsetup -getremotelogin 2>/dev/null)
  if echo "$state" | grep -qi "On"; then
    doctor_pass "SSH (Remote Login) is On"
  else
    doctor_fail "SSH (Remote Login) is Off"
    doctor_fix "Enabling SSH..."
    sudo systemsetup -setremotelogin on 2>/dev/null \
      && doctor_pass "SSH enabled" \
      || doctor_fail "Could not enable SSH (need sudo)"
  fi
}

check_ssh_password_auth() {
  local val
  val=$(grep -i "^PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
  if [[ "${val,,}" == "no" ]]; then
    doctor_pass "SSH password authentication is disabled"
  elif [[ -z "$val" ]]; then
    doctor_warn "PasswordAuthentication not explicitly set in sshd_config (defaults may vary)"
  else
    doctor_fail "SSH password authentication is enabled — should be 'no'"
  fi
}

check_tailscale_running() {
  if tailscale status &>/dev/null; then
    doctor_pass "Tailscale is running"
  else
    doctor_fail "Tailscale is not running or not installed"
  fi
}

check_tailscale_launchdaemon() {
  if ls /Library/LaunchDaemons/*tailscale* &>/dev/null; then
    doctor_pass "Tailscale LaunchDaemon plist exists"
  else
    doctor_warn "No Tailscale LaunchDaemon found in /Library/LaunchDaemons/"
  fi
}

check_docker_running() {
  if docker info &>/dev/null; then
    doctor_pass "Docker is running"
  else
    doctor_fail "Docker is not running"
    doctor_fix "Attempting to start Docker Desktop..."
    open -a Docker 2>/dev/null
    # Give it a moment — caller can re-run doctor to verify
    doctor_warn "Docker Desktop launch requested — re-run doctor to verify"
  fi
}

check_docker_autostart() {
  local settings_file="$HOME/Library/Group Containers/group.com.docker/settings-store.json"
  if [[ ! -f "$settings_file" ]]; then
    settings_file="$HOME/.docker/desktop/settings-store.json"
  fi

  if [[ -f "$settings_file" ]]; then
    local autostart
    autostart=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('AutoStart',''))" "$settings_file" 2>/dev/null)
    if [[ "$autostart" == "True" ]] || [[ "$autostart" == "true" ]]; then
      doctor_pass "Docker auto-start is enabled"
    else
      doctor_fail "Docker auto-start is not enabled (AutoStart=${autostart:-unset})"
    fi
  else
    doctor_warn "Docker settings-store.json not found — cannot verify auto-start"
  fi
}

check_openclaw_gateway_running() {
  if launchctl list 2>/dev/null | grep -q "openclaw.*gateway"; then
    doctor_pass "OpenClaw gateway is running"
  else
    doctor_fail "OpenClaw gateway is not running"
    # Attempt to load the plist if it exists
    local plist
    plist=$(ls /Library/LaunchDaemons/ai.openclaw.*.gateway.plist 2>/dev/null | head -1)
    if [[ -n "$plist" ]]; then
      doctor_fix "Loading gateway plist: $plist"
      sudo launchctl load "$plist" 2>/dev/null \
        && doctor_pass "Gateway loaded" \
        || doctor_fail "Could not load gateway plist (need sudo)"
    fi
  fi
}

check_openclaw_gateway_plist() {
  if ls /Library/LaunchDaemons/ai.openclaw.*.gateway.plist &>/dev/null; then
    doctor_pass "OpenClaw gateway LaunchDaemon plist exists"
  else
    doctor_fail "OpenClaw gateway plist missing from /Library/LaunchDaemons/"
  fi
}

check_key_sync_running() {
  if launchctl list 2>/dev/null | grep -q "sync-keys"; then
    doctor_pass "Key sync service is running"
  else
    doctor_fail "Key sync service is not running"
  fi
}

check_watchdog_running() {
  if launchctl list 2>/dev/null | grep -q "watchdog"; then
    doctor_pass "Watchdog service is running"
  else
    doctor_fail "Watchdog service is not running"
  fi
}

check_disk_space() {
  local usage
  usage=$(df -h / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
  if [[ -z "$usage" ]]; then
    doctor_warn "Could not determine disk usage"
    return
  fi
  if (( usage >= 95 )); then
    doctor_fail "Disk usage critical: ${usage}% used"
  elif (( usage >= 90 )); then
    doctor_warn "Disk usage high: ${usage}% used"
  else
    doctor_pass "Disk usage OK: ${usage}% used"
  fi
}

check_memory_pressure() {
  # memory_pressure gives a clean percentage on macOS
  if command -v memory_pressure &>/dev/null; then
    local pct
    pct=$(memory_pressure 2>/dev/null | grep "System-wide memory free percentage" | awk '{print $NF}' | tr -d '%')
    if [[ -n "$pct" ]]; then
      if (( pct <= 10 )); then
        doctor_fail "Memory pressure critical: only ${pct}% free"
      elif (( pct <= 25 )); then
        doctor_warn "Memory pressure elevated: ${pct}% free"
      else
        doctor_pass "Memory pressure OK: ${pct}% free"
      fi
      return
    fi
  fi

  # Fallback to vm_stat — compute pages free + inactive as rough gauge
  local pagesize free_pages
  pagesize=$(pagesize 2>/dev/null || echo 16384)
  free_pages=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
  if [[ -n "$free_pages" ]]; then
    local free_mb=$(( free_pages * pagesize / 1024 / 1024 ))
    if (( free_mb < 512 )); then
      doctor_warn "Low free memory: ~${free_mb} MB free (vm_stat)"
    else
      doctor_pass "Memory OK: ~${free_mb} MB free (vm_stat)"
    fi
  else
    doctor_warn "Could not determine memory pressure"
  fi
}

# ---------------------------------------------------------------------------
# Main entry point — called by fleet.sh doctor
# ---------------------------------------------------------------------------
run_os_checks() {
  echo ""
  echo "=== OS-Level Health Checks ==="
  echo ""

  # Security
  check_filevault
  check_firewall
  check_ssh_password_auth

  # Unattended operation
  check_auto_login
  check_auto_restart
  check_sleep_disabled

  # Remote access
  check_ssh
  check_tailscale_running
  check_tailscale_launchdaemon

  # Docker
  check_docker_running
  check_docker_autostart

  # OpenClaw services
  check_openclaw_gateway_running
  check_openclaw_gateway_plist
  check_key_sync_running
  check_watchdog_running

  # Resources
  check_disk_space
  check_memory_pressure

  echo ""
}

# Allow running standalone for testing
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_os_checks
fi
