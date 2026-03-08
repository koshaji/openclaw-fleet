#!/usr/bin/env bash
# OpenClaw Fleet Manager — Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/koshaji/openclaw-fleet/main/install.sh | bash
#    or: bash install.sh [--dir /path/to/install]
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/koshaji/openclaw-fleet/main"
DEFAULT_DIR="$HOME/.openclaw-fleet"
INSTALL_DIR=""

# Colors
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
fail()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Detect if we can prompt the user (not piped)
can_prompt() {
  [[ -t 0 ]] || [[ -e /dev/tty ]]
}

ask() {
  local msg="$1"
  if [[ -t 0 ]]; then
    echo -en "${YELLOW}${msg} [y/N]${NC} "
    read -r answer
  elif [[ -e /dev/tty ]]; then
    echo -en "${YELLOW}${msg} [y/N]${NC} " >/dev/tty
    read -r answer </dev/tty
  else
    return 1
  fi
  [[ "$answer" =~ ^[Yy]$ ]]
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)  INSTALL_DIR="$2"; shift 2 ;;
    --help) echo "Usage: install.sh [--dir /path/to/install]"; exit 0 ;;
    *)      fail "Unknown option: $1" ;;
  esac
done

INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_DIR}"

# Validate install directory (reject shell metacharacters and relative paths)
if [[ "$INSTALL_DIR" != /* ]]; then
  fail "Install directory must be an absolute path: $INSTALL_DIR"
fi
if [[ "$INSTALL_DIR" =~ [\;\|\&\$\`\!] ]]; then
  fail "Install directory contains invalid characters: $INSTALL_DIR"
fi

echo ""
echo -e "${BOLD}OpenClaw Fleet Manager — Installer${NC}"
echo ""

# --- Dependency checks ---

PLATFORM="$(uname -s)"
MISSING=()

# Docker
if ! command -v docker &>/dev/null; then
  warn "Docker not found."
  if [[ "$PLATFORM" == "Darwin" ]]; then
    if command -v brew &>/dev/null && can_prompt && ask "Install Docker Desktop via Homebrew?"; then
      brew install --cask docker
      info "Open Docker Desktop to finish setup, then re-run this installer."
      exit 0
    else
      MISSING+=("Docker — brew install --cask docker (macOS) or https://docs.docker.com/get-docker/")
    fi
  else
    MISSING+=("Docker — https://docs.docker.com/engine/install/")
  fi
else
  ok "Docker found"
fi

# jq
if ! command -v jq &>/dev/null; then
  warn "jq not found."
  if [[ "$PLATFORM" == "Darwin" ]] && command -v brew &>/dev/null; then
    if can_prompt && ask "Install jq via Homebrew?"; then
      brew install jq
    else
      MISSING+=("jq — brew install jq")
    fi
  elif command -v apt-get &>/dev/null; then
    if can_prompt && ask "Install jq via apt?"; then
      sudo apt-get install -y jq
    else
      MISSING+=("jq — sudo apt-get install jq")
    fi
  else
    MISSING+=("jq — https://jqlang.github.io/jq/download/")
  fi
  if command -v jq &>/dev/null; then
    ok "jq installed"
  fi
else
  ok "jq found"
fi

# openssl
if ! command -v openssl &>/dev/null; then
  MISSING+=("openssl — needed for generating secure tokens")
else
  ok "openssl found"
fi

# curl (if we got here via curl|bash, it's definitely installed, but check anyway)
if ! command -v curl &>/dev/null; then
  MISSING+=("curl — needed for downloading files")
else
  ok "curl found"
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo ""
  warn "Missing dependencies:"
  for dep in "${MISSING[@]}"; do
    echo "  - $dep"
  done
  echo ""
  fail "Install the missing dependencies and re-run the installer."
fi

# Check Docker is running
if ! docker info &>/dev/null 2>&1; then
  warn "Docker is installed but not running. Start Docker Desktop (or the Docker service) before creating agents."
fi

echo ""

# --- Download ---

FILES=(
  fleet.sh
  lib/common.sh
  lib/ports.sh
  lib/config.sh
  lib/docker.sh
  lib/health.sh
  lib/models.sh
  lib/naming.sh
  lib/secrets.sh
  lib/agentguard.sh
  lib/maintain.sh
)

info "Installing to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}/lib"

# Detect if running from a local checkout (install.sh is next to fleet.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LOCAL_INSTALL=false
if [[ -f "${SCRIPT_DIR}/fleet.sh" ]] && [[ -d "${SCRIPT_DIR}/lib" ]]; then
  LOCAL_INSTALL=true
  info "Detected local checkout at ${SCRIPT_DIR}"
fi

DOWNLOAD_FAILED=0
for file in "${FILES[@]}"; do
  if [[ "$LOCAL_INSTALL" == true ]]; then
    # Copy from local checkout
    if [[ -f "${SCRIPT_DIR}/${file}" ]]; then
      cp "${SCRIPT_DIR}/${file}" "${INSTALL_DIR}/${file}"
    else
      warn "Missing local file: $file"
      DOWNLOAD_FAILED=1
    fi
  else
    # Download from GitHub (requires public repo or gh auth)
    if curl -fsSL "${REPO_URL}/${file}" -o "${INSTALL_DIR}/${file}" 2>/dev/null; then
      if [[ ! -s "${INSTALL_DIR}/${file}" ]]; then
        warn "Downloaded empty file: $file"
        DOWNLOAD_FAILED=1
      fi
    elif command -v gh &>/dev/null; then
      # Fallback: use gh CLI for private repos
      if gh api "repos/koshaji/openclaw-fleet/contents/${file}" -q '.content' 2>/dev/null \
         | base64 -d > "${INSTALL_DIR}/${file}" 2>/dev/null && [[ -s "${INSTALL_DIR}/${file}" ]]; then
        true
      else
        warn "Failed to download: $file"
        DOWNLOAD_FAILED=1
      fi
    else
      warn "Failed to download: $file (repo may be private — install gh CLI or make repo public)"
      DOWNLOAD_FAILED=1
    fi
  fi
done

if [[ $DOWNLOAD_FAILED -eq 1 ]]; then
  fail "Some files failed to download. Check your internet connection and try again."
fi

chmod +x "${INSTALL_DIR}/fleet.sh"

# Syntax check
if ! bash -n "${INSTALL_DIR}/fleet.sh" 2>/dev/null; then
  warn "Syntax check failed on fleet.sh — the download may be corrupted. Try again."
fi

ok "Fleet manager installed to ${INSTALL_DIR}"

# --- Post-install ---

echo ""
echo -e "${BOLD}Setup complete!${NC}"
echo ""

# Detect shell config file
SHELL_RC=""
case "$(basename "${SHELL:-/bin/bash}")" in
  zsh)  SHELL_RC="~/.zshrc" ;;
  bash) SHELL_RC="~/.bashrc" ;;
  *)    SHELL_RC="your shell config" ;;
esac

echo "  Add this alias to ${SHELL_RC}:"
echo ""
echo -e "    ${CYAN}alias fleet='${INSTALL_DIR}/fleet.sh'${NC}"
echo ""
echo "  Then run the full setup (installs OpenClaw, configures manager agent, Telegram):"
echo ""
echo -e "    ${CYAN}fleet setup${NC}"
echo ""
echo "  Or skip the manager agent and just create container agents:"
echo ""
echo -e "    ${CYAN}fleet capacity${NC}        # See how many agents your machine can run"
echo -e "    ${CYAN}fleet create 1${NC}        # Create your first agent"
echo ""
echo "  On first run, it will ask for your AI provider API key and Telegram bot token."
echo "  Get a bot token from @BotFather: https://t.me/BotFather"
echo ""
