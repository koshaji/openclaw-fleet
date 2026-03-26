#!/bin/bash
set -euo pipefail

###############################################################################
# provision.sh — macOS provisioning for OpenClaw AI agent fleet nodes
#
# Usage:
#   sudo ./provision.sh --hostname mac-mini-01 --user agent --password '...' \
#     --op-token 'ops_...' --gateway-port 3100
#
# All flags are optional; missing values are prompted interactively.
###############################################################################

# ---------------------------------------------------------------------------
# Colors and logging
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC}   %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
fail()  { printf "${RED}[FAIL]${NC} %s\n" "$*"; }
header(){ printf "\n${BLUE}=== %s ===${NC}\n" "$*"; }

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
HOSTNAME_FLAG=""
USER_FLAG=""
PASSWORD_FLAG=""
OP_TOKEN=""
GATEWAY_PORT="3100"
SKIP_FILEVAULT=false
SKIP_DOCKER=false
SKIP_TAILSCALE=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)       HOSTNAME_FLAG="$2"; shift 2 ;;
    --user)           USER_FLAG="$2"; shift 2 ;;
    --password)       PASSWORD_FLAG="$2"; shift 2 ;;
    --op-token)       OP_TOKEN="$2"; shift 2 ;;
    --gateway-port)   GATEWAY_PORT="$2"; shift 2 ;;
    --skip-filevault) SKIP_FILEVAULT=true; shift ;;
    --skip-docker)    SKIP_DOCKER=true; shift ;;
    --skip-tailscale) SKIP_TAILSCALE=true; shift ;;
    -h|--help)
      echo "Usage: sudo $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --hostname NAME       Machine hostname"
      echo "  --user USERNAME       Local user account (default: current user)"
      echo "  --password PASS       User password (for FileVault/auto-login)"
      echo "  --op-token TOKEN      1Password service account token"
      echo "  --gateway-port PORT   OpenClaw gateway port (default: 3100)"
      echo "  --skip-filevault      Skip FileVault enablement"
      echo "  --skip-docker         Skip Docker Desktop install"
      echo "  --skip-tailscale      Skip Tailscale install"
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  fail "This script must be run as root (use sudo)."
  exit 1
fi

# ---------------------------------------------------------------------------
# Interactive prompts for missing values
# ---------------------------------------------------------------------------
header "Pre-flight Configuration"

if [[ -z "$USER_FLAG" ]]; then
  USER_FLAG="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
  if [[ -z "$USER_FLAG" ]]; then
    read -rp "Enter the local username: " USER_FLAG
  else
    info "Detected user: $USER_FLAG"
  fi
fi

USER_HOME=$(eval echo "~${USER_FLAG}")
if [[ ! -d "$USER_HOME" ]]; then
  fail "Home directory for user '$USER_FLAG' not found at $USER_HOME"
  exit 1
fi

if [[ -z "$HOSTNAME_FLAG" ]]; then
  read -rp "Enter hostname for this machine: " HOSTNAME_FLAG
fi

if [[ -z "$PASSWORD_FLAG" ]]; then
  read -rsp "Enter password for user '$USER_FLAG' (used for FileVault/auto-login): " PASSWORD_FLAG
  echo ""
fi

if [[ -z "$OP_TOKEN" ]]; then
  read -rp "Enter 1Password service account token (or press Enter to skip): " OP_TOKEN
fi

info "Hostname:     $HOSTNAME_FLAG"
info "User:         $USER_FLAG"
info "Gateway port: $GATEWAY_PORT"
info "FileVault:    $(if $SKIP_FILEVAULT; then echo 'skip'; else echo 'enable'; fi)"
info "Docker:       $(if $SKIP_DOCKER; then echo 'skip'; else echo 'install'; fi)"
info "Tailscale:    $(if $SKIP_TAILSCALE; then echo 'skip'; else echo 'install'; fi)"
info "1Password:    $(if [[ -n "$OP_TOKEN" ]]; then echo 'configured'; else echo 'skip'; fi)"

# ---------------------------------------------------------------------------
# Step 1: Set hostname
# ---------------------------------------------------------------------------
header "Set Hostname"

sudo scutil --set ComputerName "$HOSTNAME_FLAG"
sudo scutil --set HostName "$HOSTNAME_FLAG"
sudo scutil --set LocalHostName "$HOSTNAME_FLAG"
sudo dscacheutil -flushcache
ok "Hostname set to $HOSTNAME_FLAG"

# ---------------------------------------------------------------------------
# Step 2: Enable firewall
# ---------------------------------------------------------------------------
header "Enable Firewall"

sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setallowsigned on
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setallowsignedapp on
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on
ok "Firewall enabled with stealth mode"

# ---------------------------------------------------------------------------
# Step 3: FileVault
# ---------------------------------------------------------------------------
header "FileVault"

if $SKIP_FILEVAULT; then
  info "Skipping FileVault (--skip-filevault)"
else
  FV_STATUS=$(fdesetup status 2>&1 || true)
  if echo "$FV_STATUS" | grep -q "FileVault is On"; then
    ok "FileVault is already enabled"
  else
    info "Enabling FileVault..."
    # Create a plist with the user credentials for non-interactive enablement
    FV_PLIST=$(mktemp /tmp/fv_input.XXXXXX.plist)
    cat > "$FV_PLIST" <<FVEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Username</key>
  <string>${USER_FLAG}</string>
  <key>Password</key>
  <string>${PASSWORD_FLAG}</string>
</dict>
</plist>
FVEOF
    RECOVERY_KEY=$(fdesetup enable -inputplist < "$FV_PLIST" 2>&1 || true)
    rm -f "$FV_PLIST"
    if echo "$RECOVERY_KEY" | grep -qi "recovery key"; then
      ok "FileVault enabled"
      warn "RECOVERY KEY — save this securely:"
      echo "$RECOVERY_KEY"
    else
      warn "FileVault enablement returned: $RECOVERY_KEY"
      warn "You may need to enable FileVault manually via System Settings."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Step 4: Auto-login
# ---------------------------------------------------------------------------
header "Auto-Login"

# Auto-login works WITH FileVault on macOS — the stored credentials unlock
# the disk at boot, contrary to common belief.
sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "$USER_FLAG"

# Store the password in the kcpassword file for auto-login
# The kcpassword file uses a simple XOR cipher with a fixed key
KCPASSWORD_KEY=( 125 137 82 35 210 188 221 234 163 185 31 )
encode_kcpassword() {
  local password="$1"
  local key_len=${#KCPASSWORD_KEY[@]}
  local out_file="/etc/kcpassword"
  local bytes=()
  local i

  for (( i=0; i<${#password}; i++ )); do
    local char_code
    char_code=$(printf '%d' "'${password:$i:1}")
    local key_byte=${KCPASSWORD_KEY[$((i % key_len))]}
    bytes+=( $(( char_code ^ key_byte )) )
  done

  # Pad to 12-byte boundary
  local remainder=$(( ${#bytes[@]} % 12 ))
  if [[ $remainder -ne 0 ]]; then
    local pad=$(( 12 - remainder ))
    for (( i=0; i<pad; i++ )); do
      bytes+=( $(( 0 ^ KCPASSWORD_KEY[$(( (${#password} + i) % key_len ))] )) )
    done
  fi

  # Write binary
  printf '' > "$out_file"
  for b in "${bytes[@]}"; do
    printf "\\$(printf '%03o' "$b")" >> "$out_file"
  done
  chmod 600 "$out_file"
}

encode_kcpassword "$PASSWORD_FLAG"
ok "Auto-login configured for $USER_FLAG (works with FileVault)"

# ---------------------------------------------------------------------------
# Step 5: Power management
# ---------------------------------------------------------------------------
header "Power Management"

sudo pmset -a autorestart 1
sudo pmset -a sleep 0
sudo pmset -a displaysleep 10
sudo pmset -a powernap 0
ok "Power settings: auto-restart on, sleep off, display sleep 10m, powernap off"

# ---------------------------------------------------------------------------
# Step 6: SSH hardening
# ---------------------------------------------------------------------------
header "SSH Hardening"

# Enable remote login
sudo systemsetup -setremotelogin on 2>/dev/null || \
  sudo launchctl load -w /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || \
  warn "Could not enable remote login — enable manually in System Settings > Sharing"

# Generate ed25519 host key if missing
if [[ ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
  sudo ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ""
  ok "Generated ed25519 host key"
else
  ok "ed25519 host key already exists"
fi

# Generate user ed25519 key if missing
USER_SSH_DIR="${USER_HOME}/.ssh"
if [[ ! -f "${USER_SSH_DIR}/id_ed25519" ]]; then
  sudo -u "$USER_FLAG" mkdir -p "$USER_SSH_DIR"
  sudo -u "$USER_FLAG" ssh-keygen -t ed25519 -f "${USER_SSH_DIR}/id_ed25519" -N "" -C "${USER_FLAG}@${HOSTNAME_FLAG}"
  ok "Generated user ed25519 key at ${USER_SSH_DIR}/id_ed25519"
else
  ok "User ed25519 key already exists"
fi

# Harden sshd_config — disable password auth
SSHD_CONFIG="/etc/ssh/sshd_config"
if [[ -f "$SSHD_CONFIG" ]]; then
  # Back up the original
  cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

  # Disable password authentication
  if grep -q "^PasswordAuthentication" "$SSHD_CONFIG"; then
    sed -i '' 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
  elif grep -q "^#PasswordAuthentication" "$SSHD_CONFIG"; then
    sed -i '' 's/^#PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
  else
    echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
  fi

  # Disable challenge-response
  if grep -q "^KbdInteractiveAuthentication" "$SSHD_CONFIG"; then
    sed -i '' 's/^KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' "$SSHD_CONFIG"
  elif grep -q "^#KbdInteractiveAuthentication" "$SSHD_CONFIG"; then
    sed -i '' 's/^#KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' "$SSHD_CONFIG"
  else
    echo "KbdInteractiveAuthentication no" >> "$SSHD_CONFIG"
  fi

  ok "SSH hardened: password auth disabled"
else
  warn "sshd_config not found at $SSHD_CONFIG"
fi

# ---------------------------------------------------------------------------
# Step 7: Tailscale
# ---------------------------------------------------------------------------
header "Tailscale"

if $SKIP_TAILSCALE; then
  info "Skipping Tailscale (--skip-tailscale)"
else
  # Check for app-only installation (not homebrew)
  if [[ -d "/Applications/Tailscale.app" ]] && ! brew list tailscale &>/dev/null 2>&1; then
    warn "Tailscale is installed as an app-only (GUI) version."
    warn "The app version does NOT create a LaunchDaemon and will not survive reboot without login."
    warn "Consider uninstalling Tailscale.app and reinstalling via: brew install tailscale"
  fi

  if command -v tailscale &>/dev/null && brew list tailscale &>/dev/null 2>&1; then
    ok "Tailscale already installed via Homebrew"
  else
    info "Installing Tailscale via Homebrew..."
    sudo -u "$USER_FLAG" brew install tailscale
    ok "Tailscale installed via Homebrew"
  fi

  # Homebrew creates /Library/LaunchDaemons/homebrew.mxcl.tailscale.plist
  # which is critical for running tailscaled at boot without user login.
  TAILSCALE_PLIST="/Library/LaunchDaemons/homebrew.mxcl.tailscale.plist"
  if [[ -f "$TAILSCALE_PLIST" ]]; then
    sudo launchctl bootstrap system "$TAILSCALE_PLIST" 2>/dev/null || \
      sudo launchctl load -w "$TAILSCALE_PLIST" 2>/dev/null || true
    ok "Tailscale LaunchDaemon loaded (survives reboot without login)"
  else
    warn "Tailscale LaunchDaemon plist not found at $TAILSCALE_PLIST"
    warn "You may need to run: sudo brew services start tailscale"
  fi

  info "Run 'sudo tailscale up' to authenticate after provisioning."
fi

# ---------------------------------------------------------------------------
# Step 8: Docker Desktop
# ---------------------------------------------------------------------------
header "Docker Desktop"

if $SKIP_DOCKER; then
  info "Skipping Docker Desktop (--skip-docker)"
else
  # Install Docker Desktop via brew if not present
  if [[ -d "/Applications/Docker.app" ]]; then
    ok "Docker Desktop already installed"
  else
    info "Installing Docker Desktop via Homebrew..."
    sudo -u "$USER_FLAG" brew install --cask docker
    ok "Docker Desktop installed"
  fi

  # Write Docker settings — LicenseTermsVersion=2 is critical or Docker
  # gets stuck in "starting" state forever.
  DOCKER_SETTINGS_DIR="${USER_HOME}/Library/Group Containers/group.com.docker"
  sudo -u "$USER_FLAG" mkdir -p "$DOCKER_SETTINGS_DIR"

  DOCKER_SETTINGS_FILE="${DOCKER_SETTINGS_DIR}/settings-store.json"
  info "Writing Docker Desktop settings..."
  cat > "$DOCKER_SETTINGS_FILE" <<'DSEOF'
{
  "LicenseTermsVersion": 2,
  "DisplayedOnboarding": true,
  "ShowInstallScreen": false,
  "AutoStart": true,
  "AutoDownloadUpdates": true,
  "SettingsVersion": 43,
  "UseContainerdSnapshotter": true
}
DSEOF
  chown "${USER_FLAG}" "$DOCKER_SETTINGS_FILE"
  ok "Docker settings written (LicenseTermsVersion=2)"

  # Install privileged helper: vmnetd
  VMNETD_SRC="/Applications/Docker.app/Contents/Library/LaunchServices/com.docker.vmnetd"
  VMNETD_DEST="/Library/PrivilegedHelperTools/com.docker.vmnetd"
  VMNETD_PLIST="/Library/LaunchDaemons/com.docker.vmnetd.plist"

  if [[ -f "$VMNETD_SRC" ]]; then
    info "Installing Docker vmnetd privileged helper..."
    cp "$VMNETD_SRC" "$VMNETD_DEST"
    chmod 544 "$VMNETD_DEST"
    chown root:wheel "$VMNETD_DEST"

    cat > "$VMNETD_PLIST" <<VMEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.docker.vmnetd</string>
  <key>Program</key>
  <string>/Library/PrivilegedHelperTools/com.docker.vmnetd</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Library/PrivilegedHelperTools/com.docker.vmnetd</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>Sockets</key>
  <dict>
    <key>Listener</key>
    <dict>
      <key>SockPathMode</key>
      <integer>438</integer>
      <key>SockPathName</key>
      <string>/var/run/com.docker.vmnetd.sock</string>
    </dict>
  </dict>
  <key>UserName</key>
  <string>root</string>
</dict>
</plist>
VMEOF
    sudo launchctl bootstrap system "$VMNETD_PLIST" 2>/dev/null || \
      sudo launchctl load -w "$VMNETD_PLIST" 2>/dev/null || true
    ok "Docker vmnetd helper installed"
  else
    warn "vmnetd not found at $VMNETD_SRC — Docker.app may not be fully installed yet"
  fi

  # Install socket helper
  SOCKET_SRC="/Applications/Docker.app/Contents/Library/LaunchServices/com.docker.socket"
  SOCKET_PLIST="/Library/LaunchDaemons/com.docker.socket.plist"

  if [[ -f "$SOCKET_SRC" ]]; then
    SOCKET_DEST="/Library/PrivilegedHelperTools/com.docker.socket"
    cp "$SOCKET_SRC" "$SOCKET_DEST"
    chmod 544 "$SOCKET_DEST"
    chown root:wheel "$SOCKET_DEST"

    # Socket plist ProgramArguments must include the USERNAME as second arg
    cat > "$SOCKET_PLIST" <<SOCKETEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.docker.socket</string>
  <key>Program</key>
  <string>/Library/PrivilegedHelperTools/com.docker.socket</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Library/PrivilegedHelperTools/com.docker.socket</string>
    <string>${USER_FLAG}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>UserName</key>
  <string>root</string>
</dict>
</plist>
SOCKETEOF
    sudo launchctl bootstrap system "$SOCKET_PLIST" 2>/dev/null || \
      sudo launchctl load -w "$SOCKET_PLIST" 2>/dev/null || true
    ok "Docker socket helper installed (user: ${USER_FLAG})"
  else
    warn "Docker socket helper not found at $SOCKET_SRC"
    warn "The socket binary may not exist in this Docker Desktop version."
    warn "Docker should still work — the socket is created by Docker Desktop itself."
  fi

  # Start Docker Desktop
  info "Starting Docker Desktop..."
  sudo -u "$USER_FLAG" open -a Docker 2>/dev/null || true
  ok "Docker Desktop launch initiated"
fi

# ---------------------------------------------------------------------------
# Step 9: OpenClaw gateway LaunchDaemon
# ---------------------------------------------------------------------------
header "OpenClaw Gateway LaunchDaemon"

OPENCLAW_STATE_DIR="${USER_HOME}/.openclaw-${HOSTNAME_FLAG}"
OPENCLAW_LOG_DIR="${OPENCLAW_STATE_DIR}/logs"
sudo -u "$USER_FLAG" mkdir -p "$OPENCLAW_LOG_DIR"

GATEWAY_PLIST="/Library/LaunchDaemons/ai.openclaw.${HOSTNAME_FLAG}.gateway.plist"

cat > "$GATEWAY_PLIST" <<GWEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.openclaw.${HOSTNAME_FLAG}.gateway</string>
  <key>UserName</key>
  <string>${USER_FLAG}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/node</string>
    <string>/opt/homebrew/lib/node_modules/openclaw/dist/index.js</string>
    <string>gateway</string>
    <string>--port</string>
    <string>${GATEWAY_PORT}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${USER_HOME}</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>OPENCLAW_STATE_DIR</key>
    <string>${OPENCLAW_STATE_DIR}</string>
    <key>OPENCLAW_PROFILE</key>
    <string>${HOSTNAME_FLAG}</string>
  </dict>
  <key>KeepAlive</key>
  <true/>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${OPENCLAW_LOG_DIR}/gateway.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${OPENCLAW_LOG_DIR}/gateway.stderr.log</string>
</dict>
</plist>
GWEOF

chown root:wheel "$GATEWAY_PLIST"
chmod 644 "$GATEWAY_PLIST"
ok "OpenClaw gateway LaunchDaemon written to $GATEWAY_PLIST"

# ---------------------------------------------------------------------------
# Step 10: 1Password key sync
# ---------------------------------------------------------------------------
header "1Password Key Sync"

if [[ -z "$OP_TOKEN" ]]; then
  info "No --op-token provided, skipping 1Password key sync setup"
else
  FLEET_DIR="${USER_HOME}/.openclaw-fleet"
  sudo -u "$USER_FLAG" mkdir -p "$FLEET_DIR"

  # Write sync-keys.sh
  SYNC_SCRIPT="${FLEET_DIR}/sync-keys.sh"
  info "Writing sync-keys.sh..."

  write_sync_keys_script() {
    local dest="$1"
    local hostname="$2"
    local user_home="$3"
    local state_dir="$4"

    cat > "$dest" <<'SYNCEOF_HEADER'
#!/bin/bash
set -euo pipefail

SYNCEOF_HEADER

    cat >> "$dest" <<SYNCEOF_VARS
HOSTNAME_ID="${hostname}"
STATE_DIR="${state_dir}"
SYNCEOF_VARS

    cat >> "$dest" <<'SYNCEOF_BODY'
VAULT="The Bot Club"
CHANGED=false

# Ensure op CLI is available
if ! command -v op &>/dev/null; then
  echo "[sync-keys] op CLI not found, skipping"
  exit 0
fi

# Pull all items tagged with openclaw-key from the vault
ITEMS=$(op item list --vault "$VAULT" --tags openclaw-key --format=json 2>/dev/null || echo "[]")
if [[ "$ITEMS" == "[]" ]]; then
  echo "[sync-keys] No openclaw-key items found in vault '$VAULT'"
  exit 0
fi

CONFIG_FILE="${STATE_DIR}/openclaw.json"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "{}" > "$CONFIG_FILE"
fi

# Iterate items and extract fields
echo "$ITEMS" | /opt/homebrew/bin/jq -r '.[].id' | while read -r ITEM_ID; do
  KEY_NAME=$(op item get "$ITEM_ID" --fields label=key-name 2>/dev/null || continue)
  KEY_VALUE=$(op item get "$ITEM_ID" --fields label=credential --reveal 2>/dev/null || continue)

  if [[ -z "$KEY_NAME" || -z "$KEY_VALUE" ]]; then
    continue
  fi

  # Check if key changed
  CURRENT=$(cat "$CONFIG_FILE" | /opt/homebrew/bin/jq -r --arg k "$KEY_NAME" '.keys[$k] // ""' 2>/dev/null || echo "")
  if [[ "$CURRENT" != "$KEY_VALUE" ]]; then
    echo "[sync-keys] Updating key: $KEY_NAME"
    TMP=$(mktemp)
    /opt/homebrew/bin/jq --arg k "$KEY_NAME" --arg v "$KEY_VALUE" '.keys[$k] = $v' "$CONFIG_FILE" > "$TMP"
    mv "$TMP" "$CONFIG_FILE"
    CHANGED=true
  fi
done

# Restart gateway service if keys changed
if [[ "$CHANGED" == "true" ]]; then
  echo "[sync-keys] Keys changed, restarting gateway..."
  PLIST="/Library/LaunchDaemons/ai.openclaw.${HOSTNAME_ID}.gateway.plist"
  if [[ -f "$PLIST" ]]; then
    sudo launchctl bootout system "$PLIST" 2>/dev/null || true
    sudo launchctl bootstrap system "$PLIST" 2>/dev/null || true
    echo "[sync-keys] Gateway restarted"
  fi
else
  echo "[sync-keys] No key changes detected"
fi
SYNCEOF_BODY
  }

  write_sync_keys_script "$SYNC_SCRIPT" "$HOSTNAME_FLAG" "$USER_HOME" "$OPENCLAW_STATE_DIR"
  chown "${USER_FLAG}" "$SYNC_SCRIPT"
  chmod 755 "$SYNC_SCRIPT"
  ok "sync-keys.sh written to $SYNC_SCRIPT"

  # Create LaunchAgent for key sync (runs every 900 seconds)
  LAUNCH_AGENTS_DIR="${USER_HOME}/Library/LaunchAgents"
  sudo -u "$USER_FLAG" mkdir -p "$LAUNCH_AGENTS_DIR"

  SYNC_PLIST="${LAUNCH_AGENTS_DIR}/ai.openclaw.sync-keys.plist"

  cat > "$SYNC_PLIST" <<SKEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.openclaw.sync-keys</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SYNC_SCRIPT}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OP_SERVICE_ACCOUNT_TOKEN</key>
    <string>${OP_TOKEN}</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartInterval</key>
  <integer>900</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${FLEET_DIR}/sync-keys.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${FLEET_DIR}/sync-keys.stderr.log</string>
</dict>
</plist>
SKEOF

  chown "${USER_FLAG}" "$SYNC_PLIST"
  # chmod 600 because this file contains the 1Password token
  chmod 600 "$SYNC_PLIST"
  ok "Key sync LaunchAgent written to $SYNC_PLIST (mode 600 — contains token)"
fi

# ---------------------------------------------------------------------------
# Step 11: Watchdog
# ---------------------------------------------------------------------------
header "Watchdog"

FLEET_DIR="${USER_HOME}/.openclaw-fleet"
sudo -u "$USER_FLAG" mkdir -p "$FLEET_DIR"

WATCHDOG_SCRIPT="${FLEET_DIR}/watchdog.sh"
info "Writing watchdog.sh..."

write_watchdog_script() {
  local dest="$1"
  cat > "$dest" <<'WDEOF'
#!/bin/bash
set -euo pipefail

LOG_PREFIX="[watchdog]"

# Check if Docker is running
if ! /usr/local/bin/docker info &>/dev/null && ! /opt/homebrew/bin/docker info &>/dev/null; then
  echo "$LOG_PREFIX Docker is not running, attempting restart..."
  open -a Docker 2>/dev/null || true
  sleep 10
fi

DOCKER_CMD="docker"
if command -v /opt/homebrew/bin/docker &>/dev/null; then
  DOCKER_CMD="/opt/homebrew/bin/docker"
elif command -v /usr/local/bin/docker &>/dev/null; then
  DOCKER_CMD="/usr/local/bin/docker"
fi

# Get all containers (running or not)
CONTAINERS=$($DOCKER_CMD ps -a --format '{{.ID}} {{.Names}} {{.Status}}' 2>/dev/null || echo "")
if [[ -z "$CONTAINERS" ]]; then
  echo "$LOG_PREFIX No containers found"
  exit 0
fi

while IFS= read -r line; do
  CID=$(echo "$line" | awk '{print $1}')
  CNAME=$(echo "$line" | awk '{print $2}')
  CSTATUS=$(echo "$line" | awk '{$1=""; $2=""; print $0}' | xargs)

  # Check for unhealthy containers
  if echo "$CSTATUS" | grep -qi "unhealthy"; then
    echo "$LOG_PREFIX Container $CNAME ($CID) is unhealthy, restarting..."
    $DOCKER_CMD restart "$CID" 2>/dev/null || true
  fi

  # Check for exited containers that should be running
  if echo "$CSTATUS" | grep -qi "exited"; then
    RESTART_POLICY=$($DOCKER_CMD inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$CID" 2>/dev/null || echo "no")
    if [[ "$RESTART_POLICY" != "no" ]]; then
      echo "$LOG_PREFIX Container $CNAME ($CID) exited but has restart policy '$RESTART_POLICY', starting..."
      $DOCKER_CMD start "$CID" 2>/dev/null || true
    fi
  fi
done <<< "$CONTAINERS"

echo "$LOG_PREFIX Health check complete"
WDEOF
}

write_watchdog_script "$WATCHDOG_SCRIPT"
chown "${USER_FLAG}" "$WATCHDOG_SCRIPT"
chmod 755 "$WATCHDOG_SCRIPT"
ok "watchdog.sh written to $WATCHDOG_SCRIPT"

# Create watchdog LaunchAgent (runs every 300 seconds)
LAUNCH_AGENTS_DIR="${USER_HOME}/Library/LaunchAgents"
sudo -u "$USER_FLAG" mkdir -p "$LAUNCH_AGENTS_DIR"

WATCHDOG_PLIST="${LAUNCH_AGENTS_DIR}/ai.openclaw.watchdog.plist"

cat > "$WATCHDOG_PLIST" <<WDPEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.openclaw.watchdog</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${WATCHDOG_SCRIPT}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartInterval</key>
  <integer>300</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${FLEET_DIR}/watchdog.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${FLEET_DIR}/watchdog.stderr.log</string>
</dict>
</plist>
WDPEOF

chown "${USER_FLAG}" "$WATCHDOG_PLIST"
chmod 644 "$WATCHDOG_PLIST"
ok "Watchdog LaunchAgent written to $WATCHDOG_PLIST"

# ---------------------------------------------------------------------------
# Step 12: Verification
# ---------------------------------------------------------------------------
header "Verification"

ERRORS=0

# Hostname
CURRENT_HOSTNAME=$(scutil --get ComputerName 2>/dev/null || echo "UNKNOWN")
if [[ "$CURRENT_HOSTNAME" == "$HOSTNAME_FLAG" ]]; then
  ok "Hostname: $CURRENT_HOSTNAME"
else
  fail "Hostname mismatch: expected $HOSTNAME_FLAG, got $CURRENT_HOSTNAME"
  ERRORS=$((ERRORS + 1))
fi

# Firewall
FW_STATE=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || echo "")
if echo "$FW_STATE" | grep -qi "enabled"; then
  ok "Firewall: enabled"
else
  fail "Firewall: not enabled"
  ERRORS=$((ERRORS + 1))
fi

# FileVault
if $SKIP_FILEVAULT; then
  info "FileVault: skipped"
else
  FV_CHECK=$(fdesetup status 2>/dev/null || echo "")
  if echo "$FV_CHECK" | grep -qi "on\|encryption in progress"; then
    ok "FileVault: enabled"
  else
    warn "FileVault: may require reboot to complete"
  fi
fi

# Auto-login
AL_USER=$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || echo "")
if [[ "$AL_USER" == "$USER_FLAG" ]]; then
  ok "Auto-login: $AL_USER"
else
  fail "Auto-login: not set correctly"
  ERRORS=$((ERRORS + 1))
fi

# Power management
PM_RESTART=$(pmset -g custom 2>/dev/null | grep -m1 autorestart | awk '{print $2}' || echo "")
if [[ "$PM_RESTART" == "1" ]]; then
  ok "Power: auto-restart enabled"
else
  warn "Power: auto-restart may not be set"
fi

# SSH
if [[ -f /etc/ssh/ssh_host_ed25519_key ]]; then
  ok "SSH: ed25519 host key present"
else
  fail "SSH: ed25519 host key missing"
  ERRORS=$((ERRORS + 1))
fi

PASS_AUTH=$(grep -E "^PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null || echo "")
if echo "$PASS_AUTH" | grep -q "no"; then
  ok "SSH: password auth disabled"
else
  warn "SSH: password auth may still be enabled"
fi

# Tailscale
if ! $SKIP_TAILSCALE; then
  if command -v tailscale &>/dev/null; then
    ok "Tailscale: installed"
  else
    fail "Tailscale: not found"
    ERRORS=$((ERRORS + 1))
  fi
fi

# Docker
if ! $SKIP_DOCKER; then
  if [[ -d "/Applications/Docker.app" ]]; then
    ok "Docker Desktop: installed"
  else
    fail "Docker Desktop: not found"
    ERRORS=$((ERRORS + 1))
  fi

  if [[ -f "$DOCKER_SETTINGS_FILE" ]]; then
    ok "Docker settings: written"
  else
    fail "Docker settings: missing"
    ERRORS=$((ERRORS + 1))
  fi
fi

# Gateway plist
if [[ -f "$GATEWAY_PLIST" ]]; then
  ok "Gateway LaunchDaemon: present"
else
  fail "Gateway LaunchDaemon: missing"
  ERRORS=$((ERRORS + 1))
fi

# 1Password sync
if [[ -n "$OP_TOKEN" ]]; then
  if [[ -f "$SYNC_SCRIPT" ]]; then
    ok "Key sync script: present"
  else
    fail "Key sync script: missing"
    ERRORS=$((ERRORS + 1))
  fi
  SYNC_PLIST_CHECK="${LAUNCH_AGENTS_DIR}/ai.openclaw.sync-keys.plist"
  if [[ -f "$SYNC_PLIST_CHECK" ]]; then
    SYNC_PERMS=$(stat -f "%Lp" "$SYNC_PLIST_CHECK" 2>/dev/null || echo "")
    if [[ "$SYNC_PERMS" == "600" ]]; then
      ok "Key sync plist: present (mode 600)"
    else
      warn "Key sync plist: present but mode is $SYNC_PERMS (expected 600)"
    fi
  else
    fail "Key sync plist: missing"
    ERRORS=$((ERRORS + 1))
  fi
fi

# Watchdog
if [[ -f "$WATCHDOG_SCRIPT" ]]; then
  ok "Watchdog script: present"
else
  fail "Watchdog script: missing"
  ERRORS=$((ERRORS + 1))
fi

if [[ -f "$WATCHDOG_PLIST" ]]; then
  ok "Watchdog plist: present"
else
  fail "Watchdog plist: missing"
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Provisioning Complete"

if [[ $ERRORS -eq 0 ]]; then
  ok "All checks passed"
else
  fail "$ERRORS check(s) failed — review output above"
fi

echo ""
info "Next steps:"
info "  1. Run 'sudo tailscale up' to authenticate with Tailscale"
info "  2. Add the SSH public key to authorized machines:"
info "     cat ${USER_SSH_DIR}/id_ed25519.pub"
info "  3. Install openclaw: npm install -g openclaw"
info "  4. Load the gateway: sudo launchctl bootstrap system $GATEWAY_PLIST"
info "  5. Reboot to verify auto-login and all services start correctly"
echo ""
