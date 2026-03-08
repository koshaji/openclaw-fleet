#!/usr/bin/env bash
# secrets.sh — Secret resolution with optional 1Password integration

# Check if 1Password CLI is available and authenticated
op_available() {
  command -v op &>/dev/null && op account list &>/dev/null 2>&1
}

# Resolve a secret value — supports op:// references or returns plaintext as-is
resolve_secret() {
  local value="$1"
  if [[ "$value" == op://* ]]; then
    if ! command -v op &>/dev/null; then
      log_error "1Password CLI (op) required to resolve: $value"
      log_error "Install with: brew install 1password-cli"
      return 1
    fi
    op read "$value" 2>/dev/null || {
      log_error "Failed to resolve 1Password reference: $value"
      return 1
    }
  else
    echo "$value"
  fi
}

# Store a secret in 1Password (creates or updates)
store_secret() {
  local vault="$1"
  local item="$2"
  local field="$3"
  local value="$4"

  if ! op_available; then
    return 1
  fi

  if op item get "$item" --vault "$vault" &>/dev/null 2>&1; then
    op item edit "$item" --vault "$vault" "${field}=${value}" &>/dev/null
  else
    op item create --category=api_credential --vault "$vault" \
      --title "$item" "${field}=${value}" &>/dev/null
  fi
}

# Get the 1Password reference string for a secret
secret_ref() {
  local vault="$1"
  local item="$2"
  local field="$3"
  echo "op://${vault}/${item}/${field}"
}

# Initialize 1Password vault for the fleet (interactive, one-time)
init_op_vault() {
  local vault_name="OpenClaw-Fleet"

  if ! command -v op &>/dev/null; then
    log_info "1Password CLI not found. Secrets will be stored in plaintext."
    log_info "To enable 1Password: brew install 1password-cli && op signin"
    return 1
  fi

  if ! op account list &>/dev/null 2>&1; then
    log_info "1Password CLI not signed in. Run: op signin"
    return 1
  fi

  if ! op vault get "$vault_name" &>/dev/null 2>&1; then
    log_info "Creating 1Password vault: $vault_name"
    op vault create "$vault_name" &>/dev/null || {
      log_error "Failed to create vault. You may need to create it manually."
      return 1
    }
  fi

  log_ok "1Password vault '$vault_name' ready"
  echo "$vault_name"
}

# Migrate plaintext secrets to 1Password references
migrate_to_op() {
  local vault_name
  vault_name=$(init_op_vault) || return 1

  local providers_file="${FLEET_DIR}/agents/providers.json"
  if [[ ! -f "$providers_file" ]]; then
    log_info "No providers.json to migrate."
    return 0
  fi

  log_info "Migrating provider secrets to 1Password..."

  local names
  names=$(jq -r '.subscriptions | keys[]' "$providers_file" 2>/dev/null)

  local migrated=0
  for name in $names; do
    local api_key
    api_key=$(jq -r ".subscriptions[\"$name\"].apiKey" "$providers_file")

    # Skip if already an op:// reference
    if [[ "$api_key" == op://* ]]; then
      continue
    fi

    if store_secret "$vault_name" "provider-${name}" "apiKey" "$api_key"; then
      local ref
      ref=$(secret_ref "$vault_name" "provider-${name}" "apiKey")
      local updated
      updated=$(jq --arg name "$name" --arg ref "$ref" \
        '.subscriptions[$name].apiKey = $ref' "$providers_file")
      atomic_json_write "$providers_file" "$updated"
      chmod 600 "$providers_file"
      log_ok "Migrated '$name' API key to 1Password"
      migrated=$((migrated + 1))
    else
      log_warn "Could not store '$name' key in 1Password — keeping plaintext"
    fi
  done

  if [[ $migrated -gt 0 ]]; then
    log_ok "Migrated $migrated secret(s) to 1Password"
  else
    log_info "No secrets needed migration."
  fi
}
