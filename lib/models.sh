#!/usr/bin/env bash
# models.sh — Provider/subscription management and model allocation

PROVIDERS_FILE="${FLEET_DIR}/agents/providers.json"

# Known provider definitions (type -> base config)
# Using functions instead of associative arrays for bash 3.2 compatibility

get_provider_api() {
  case "$1" in
    anthropic)  echo "anthropic" ;;
    openai)     echo "openai-completions" ;;
    google)     echo "google-ai" ;;
    zai)        echo "openai-completions" ;;
    ollama)     echo "openai-completions" ;;
    openrouter) echo "openai-completions" ;;
    *)          echo "openai-completions" ;;
  esac
}

get_provider_url() {
  case "$1" in
    zai)        echo "https://api.z.ai/api/coding/paas/v4" ;;
    ollama)     echo "http://localhost:11434/v1" ;;
    openrouter) echo "https://openrouter.ai/api/v1" ;;
    *)          echo "" ;;
  esac
}

# Known models per provider type
ANTHROPIC_MODELS='[
  {"id":"claude-opus-4-6","name":"Claude Opus 4.6","reasoning":true,"input":["text","image"],"contextWindow":200000,"maxTokens":32000},
  {"id":"claude-sonnet-4-6","name":"Claude Sonnet 4.6","reasoning":true,"input":["text","image"],"contextWindow":200000,"maxTokens":16000},
  {"id":"claude-haiku-4-5","name":"Claude Haiku 4.5","reasoning":false,"input":["text","image"],"contextWindow":200000,"maxTokens":8192},
  {"id":"claude-opus-4-20250514","name":"Claude Opus 4","reasoning":true,"input":["text","image"],"contextWindow":200000,"maxTokens":32000},
  {"id":"claude-sonnet-4-20250514","name":"Claude Sonnet 4","reasoning":true,"input":["text","image"],"contextWindow":200000,"maxTokens":16000},
  {"id":"claude-sonnet-4-5-20241022","name":"Claude Sonnet 3.5 v2","reasoning":false,"input":["text","image"],"contextWindow":200000,"maxTokens":8192}
]'

OPENAI_MODELS='[
  {"id":"gpt-4o","name":"GPT-4o","reasoning":false,"input":["text","image"],"contextWindow":128000,"maxTokens":16384},
  {"id":"gpt-4o-mini","name":"GPT-4o Mini","reasoning":false,"input":["text","image"],"contextWindow":128000,"maxTokens":16384},
  {"id":"o3","name":"o3","reasoning":true,"input":["text"],"contextWindow":200000,"maxTokens":100000},
  {"id":"o3-mini","name":"o3-mini","reasoning":true,"input":["text"],"contextWindow":200000,"maxTokens":100000},
  {"id":"o4-mini","name":"o4-mini","reasoning":true,"input":["text","image"],"contextWindow":200000,"maxTokens":100000},
  {"id":"gpt-4-turbo","name":"GPT-4 Turbo","reasoning":false,"input":["text","image"],"contextWindow":128000,"maxTokens":4096}
]'

GOOGLE_MODELS='[
  {"id":"gemini-2.5-pro","name":"Gemini 2.5 Pro","reasoning":true,"input":["text","image"],"contextWindow":1000000,"maxTokens":65536},
  {"id":"gemini-2.5-flash","name":"Gemini 2.5 Flash","reasoning":false,"input":["text","image"],"contextWindow":1000000,"maxTokens":65536},
  {"id":"gemini-2.0-flash","name":"Gemini 2.0 Flash","reasoning":false,"input":["text","image"],"contextWindow":1000000,"maxTokens":8192},
  {"id":"gemini-2.0-flash-lite","name":"Gemini 2.0 Flash Lite","reasoning":false,"input":["text","image"],"contextWindow":1000000,"maxTokens":8192}
]'

ZAI_MODELS='[
  {"id":"glm-5","name":"GLM-5","reasoning":true,"input":["text"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":204800,"maxTokens":131072},
  {"id":"glm-4.7","name":"GLM-4.7","reasoning":true,"input":["text"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":204800,"maxTokens":131072}
]'

OLLAMA_MODELS='[
  {"id":"llama3.3","name":"Llama 3.3 70B","reasoning":false,"input":["text"],"contextWindow":131072,"maxTokens":8192},
  {"id":"qwen3","name":"Qwen 3","reasoning":true,"input":["text"],"contextWindow":131072,"maxTokens":8192},
  {"id":"deepseek-r1","name":"DeepSeek R1","reasoning":true,"input":["text"],"contextWindow":131072,"maxTokens":8192},
  {"id":"mistral","name":"Mistral 7B","reasoning":false,"input":["text"],"contextWindow":32768,"maxTokens":4096}
]'

OPENROUTER_MODELS='[
  {"id":"anthropic/claude-opus-4-6","name":"Claude Opus 4.6 (OpenRouter)","reasoning":true,"input":["text","image"],"contextWindow":200000,"maxTokens":32000},
  {"id":"openai/gpt-4o","name":"GPT-4o (OpenRouter)","reasoning":false,"input":["text","image"],"contextWindow":128000,"maxTokens":16384},
  {"id":"google/gemini-2.5-pro","name":"Gemini 2.5 Pro (OpenRouter)","reasoning":true,"input":["text","image"],"contextWindow":1000000,"maxTokens":65536},
  {"id":"deepseek/deepseek-r1","name":"DeepSeek R1 (OpenRouter)","reasoning":true,"input":["text"],"contextWindow":131072,"maxTokens":8192}
]'

# Initialize providers registry
init_providers() {
  if [[ ! -f "$PROVIDERS_FILE" ]]; then
    atomic_json_write "$PROVIDERS_FILE" '{
      "version": 1,
      "subscriptions": {},
      "allocations": {}
    }'
    chmod 600 "$PROVIDERS_FILE"
  fi
}

# Add a provider subscription
# Usage: add_subscription <name> <type> <api_key> [label] [base_url]
add_subscription() {
  local name="$1"
  local type="$2"
  local api_key="$3"
  local label="${4:-$name}"
  local base_url="${5:-}"

  init_providers

  # Get default base URL for type
  if [[ -z "$base_url" ]]; then
    base_url="$(get_provider_url "$type")"
  fi

  # Get default API format
  local api_format
  api_format="$(get_provider_api "$type")"

  # Get models list for this type
  local models_json="[]"
  case "$type" in
    anthropic)  models_json="$ANTHROPIC_MODELS" ;;
    openai)     models_json="$OPENAI_MODELS" ;;
    google)     models_json="$GOOGLE_MODELS" ;;
    zai)        models_json="$ZAI_MODELS" ;;
    ollama)     models_json="$OLLAMA_MODELS" ;;
    openrouter) models_json="$OPENROUTER_MODELS" ;;
    *)          models_json="[]" ;;
  esac

  local updated
  updated=$(jq \
    --arg name "$name" \
    --arg type "$type" \
    --arg key "$api_key" \
    --arg label "$label" \
    --arg url "$base_url" \
    --arg api "$api_format" \
    --argjson models "$models_json" \
    '.subscriptions[$name] = {
      type: $type,
      apiKey: $key,
      label: $label,
      baseUrl: $url,
      api: $api,
      models: $models,
      addedAt: (now | todate)
    }' "$PROVIDERS_FILE")

  atomic_json_write "$PROVIDERS_FILE" "$updated"
  chmod 600 "$PROVIDERS_FILE"
  log_ok "Added subscription '$name' ($label) — type: $type"
}

# Remove a subscription
remove_subscription() {
  local name="$1"
  init_providers

  # Check if any agents use this subscription
  local users
  users=$(jq -r ".allocations | to_entries[] | select(.value.primary | startswith(\"$name/\")) | .key" "$PROVIDERS_FILE" 2>/dev/null)
  if [[ -n "$users" ]]; then
    log_error "Cannot remove '$name' — still allocated to agents: $users"
    log_error "Reallocate those agents first with: ./fleet.sh models assign <agent> <subscription/model>"
    return 1
  fi

  local updated
  updated=$(jq --arg name "$name" 'del(.subscriptions[$name])' "$PROVIDERS_FILE")
  atomic_json_write "$PROVIDERS_FILE" "$updated"
  chmod 600 "$PROVIDERS_FILE"
  log_ok "Removed subscription '$name'"
}

# List all subscriptions
list_subscriptions() {
  init_providers

  local count
  count=$(jq '.subscriptions | length' "$PROVIDERS_FILE")

  if [[ "$count" == "0" ]]; then
    log_info "No provider subscriptions configured."
    log_info "Add one with: ./fleet.sh providers add"
    return
  fi

  echo ""
  echo -e "${BOLD}Provider Subscriptions${NC}"
  echo -e "${BOLD}$(printf '=%.0s' {1..78})${NC}"
  printf "  ${BOLD}%-20s %-12s %-25s %-15s${NC}\n" "NAME" "TYPE" "LABEL" "MODELS"
  echo "  $(printf -- '-%.0s' {1..76})"

  jq -r '.subscriptions | to_entries[] | "\(.key)\t\(.value.type)\t\(.value.label)\t\(.value.models | length)"' \
    "$PROVIDERS_FILE" | while IFS=$'\t' read -r name type label model_count; do
    printf "  %-20s %-12s %-25s %-15s\n" "$name" "$type" "$label" "${model_count} models"
  done

  echo ""

  # Show available models per subscription
  echo -e "${BOLD}Available Models${NC}"
  echo "  $(printf -- '-%.0s' {1..76})"
  jq -r '.subscriptions | to_entries[] | .key as $sub | .value.models[]? | "\($sub)/\(.id)\t\(.name)"' \
    "$PROVIDERS_FILE" | while IFS=$'\t' read -r model_id model_name; do
    printf "  %-40s %s\n" "$model_id" "$model_name"
  done
  echo ""
}

# Allocate a model to an agent (primary + fallbacks)
# Usage: allocate_model <agent_name> <subscription/model> [fallback1] [fallback2] ...
allocate_model() {
  local agent_name="$1"
  local primary="$2"
  shift 2
  local fallback_count=$#
  local fallbacks; fallbacks=("$@")

  init_providers

  # Validate primary model exists
  local sub_name="${primary%%/*}"
  local model_id="${primary##*/}"

  local sub_exists
  sub_exists=$(jq -r ".subscriptions[\"$sub_name\"] // \"null\"" "$PROVIDERS_FILE")
  if [[ "$sub_exists" == "null" ]]; then
    log_fatal "Subscription '$sub_name' not found. Run: ./fleet.sh providers list"
  fi

  # Build fallbacks array
  local fallbacks_json="[]"
  if [[ $fallback_count -gt 0 ]]; then
    fallbacks_json=$(printf '%s\n' "${fallbacks[@]}" | jq -R . | jq -s .)
  fi

  local updated
  updated=$(jq \
    --arg agent "$agent_name" \
    --arg primary "$primary" \
    --argjson fallbacks "$fallbacks_json" \
    '.allocations[$agent] = {
      primary: $primary,
      fallbacks: $fallbacks,
      updatedAt: (now | todate)
    }' "$PROVIDERS_FILE")

  atomic_json_write "$PROVIDERS_FILE" "$updated"
  chmod 600 "$PROVIDERS_FILE"
  log_ok "Allocated '$primary' to agent '$agent_name'"
  if [[ $fallback_count -gt 0 ]]; then
    log_ok "  Fallbacks: ${fallbacks[*]}"
  fi
}

# Get an agent's model allocation
get_agent_allocation() {
  local agent_name="$1"
  init_providers
  jq -r ".allocations[\"$agent_name\"] // \"null\"" "$PROVIDERS_FILE"
}

# Generate openclaw.json model config for an agent based on its allocation
generate_model_config() {
  local agent_name="$1"
  init_providers

  local allocation
  allocation=$(get_agent_allocation "$agent_name")

  if [[ "$allocation" == "null" ]]; then
    # Default to zai if no allocation
    local default_sub
    default_sub=$(jq -r '.subscriptions | to_entries | map(select(.value.type == "zai")) | .[0].key // empty' "$PROVIDERS_FILE")
    if [[ -n "$default_sub" ]]; then
      allocation='{"primary":"'"${default_sub}/glm-5"'","fallbacks":[]}'
    else
      # Use first available subscription
      default_sub=$(jq -r '.subscriptions | keys[0] // empty' "$PROVIDERS_FILE")
      local first_model
      first_model=$(jq -r ".subscriptions[\"$default_sub\"].models[0].id // empty" "$PROVIDERS_FILE")
      if [[ -n "$default_sub" ]] && [[ -n "$first_model" ]]; then
        allocation='{"primary":"'"${default_sub}/${first_model}"'","fallbacks":[]}'
      else
        log_error "No providers configured. Cannot generate model config."
        return 1
      fi
    fi
  fi

  local primary
  primary=$(echo "$allocation" | jq -r '.primary')
  local primary_sub="${primary%%/*}"
  local primary_model="${primary##*/}"

  # Build providers object and auth profiles
  local providers_json="{}"
  local auth_profiles_json="{}"
  local model_routing_json="{}"

  # Collect all subscriptions used by this agent (primary + fallbacks)
  local all_subs=("$primary_sub")
  local fallbacks
  fallbacks=$(echo "$allocation" | jq -r '.fallbacks[]? // empty')
  for fb in $fallbacks; do
    local fb_sub="${fb%%/*}"
    # Add if not already in list
    local found=false
    for s in "${all_subs[@]}"; do
      [[ "$s" == "$fb_sub" ]] && found=true
    done
    [[ "$found" == "false" ]] && all_subs+=("$fb_sub")
  done

  # Build provider configs for each subscription
  for sub in "${all_subs[@]}"; do
    local sub_info
    sub_info=$(jq ".subscriptions[\"$sub\"]" "$PROVIDERS_FILE")
    local sub_type
    sub_type=$(echo "$sub_info" | jq -r '.type')
    local sub_url
    sub_url=$(echo "$sub_info" | jq -r '.baseUrl // ""')
    local sub_api
    sub_api=$(echo "$sub_info" | jq -r '.api')
    local sub_models
    sub_models=$(echo "$sub_info" | jq '.models')

    # Build provider entry
    local provider_entry
    provider_entry=$(jq -n \
      --arg api "$sub_api" \
      --arg url "$sub_url" \
      --argjson models "$sub_models" \
      '{api: $api, models: $models}')

    if [[ -n "$sub_url" ]]; then
      provider_entry=$(echo "$provider_entry" | jq --arg url "$sub_url" '.baseUrl = $url')
    fi

    providers_json=$(echo "$providers_json" | jq --arg sub "$sub" --argjson entry "$provider_entry" '.[$sub] = $entry')

    # Auth profile
    auth_profiles_json=$(echo "$auth_profiles_json" | jq \
      --arg sub "$sub" \
      --arg type "$sub_type" \
      '.[$sub + ":default"] = {provider: $sub, mode: "api_key"}')
  done

  # Build model routing (primary + fallback chain)
  local primary_full="${primary_sub}/${primary_model}"
  local fallback_chain="[]"
  for fb in $fallbacks; do
    fallback_chain=$(echo "$fallback_chain" | jq --arg fb "$fb" '. + [$fb]')
  done

  # Output the models section for openclaw.json
  jq -n \
    --argjson providers "$providers_json" \
    --arg primary "$primary_full" \
    --argjson fallbacks "$fallback_chain" \
    '{
      mode: "merge",
      providers: $providers
    }'
}

# Generate auth-profiles.json for an agent based on its allocation
generate_agent_auth_profiles() {
  local agent_name="$1"
  init_providers

  local allocation
  allocation=$(get_agent_allocation "$agent_name")

  # Collect all subscriptions used
  local all_subs=()
  if [[ "$allocation" != "null" ]]; then
    local primary_sub
    primary_sub=$(echo "$allocation" | jq -r '.primary' | cut -d'/' -f1)
    all_subs+=("$primary_sub")
    local fallbacks
    fallbacks=$(echo "$allocation" | jq -r '.fallbacks[]? // empty' | cut -d'/' -f1)
    for fb_sub in $fallbacks; do
      local found=false
      for s in "${all_subs[@]}"; do
        [[ "$s" == "$fb_sub" ]] && found=true
      done
      [[ "$found" == "false" ]] && all_subs+=("$fb_sub")
    done
  else
    # Default: use all subscriptions
    while IFS= read -r sub; do
      all_subs+=("$sub")
    done < <(jq -r '.subscriptions | keys[]' "$PROVIDERS_FILE" 2>/dev/null)
  fi

  local profiles="{}"
  for sub in "${all_subs[@]}"; do
    local api_key
    local raw_key
    raw_key=$(jq -r ".subscriptions[\"$sub\"].apiKey" "$PROVIDERS_FILE")
    # Resolve op:// references if 1Password is configured
    api_key=$(resolve_secret "$raw_key") || api_key="$raw_key"
    local sub_type
    sub_type=$(jq -r ".subscriptions[\"$sub\"].type" "$PROVIDERS_FILE")

    profiles=$(_JQ_SECRET="$api_key" jq \
      --arg name "${sub}:default" \
      --arg type "api_key" \
      --arg provider "$sub" \
      '.[$name] = {type: $type, provider: $provider, key: $ENV._JQ_SECRET}' <<< "$profiles")
  done

  jq -n --argjson profiles "$profiles" '{version: 1, profiles: $profiles}'
}

# Get the primary model string for an agent (used in openclaw.json agents.defaults.model.primary)
get_primary_model_string() {
  local agent_name="$1"
  init_providers

  local allocation
  allocation=$(get_agent_allocation "$agent_name")

  if [[ "$allocation" == "null" ]]; then
    echo "zai/glm-5"
    return
  fi

  echo "$allocation" | jq -r '.primary'
}

# Discover models from OpenClaw CLI (if available and provider is configured)
discover_models() {
  local type="$1"
  local api_key="$2"
  local base_url="${3:-}"

  # Try openclaw models scan if available
  if command -v openclaw &>/dev/null; then
    local scan_result
    scan_result=$(openclaw models scan --provider "$type" 2>/dev/null | tail -n +2 || true)
    if [[ -n "$scan_result" ]]; then
      echo "$scan_result"
      return 0
    fi
  fi
  return 1
}

# Interactive provider setup
interactive_add_subscription() {
  echo ""
  echo -e "${BOLD}Add Provider Subscription${NC}"
  echo ""
  echo "  Supported types:"
  echo "    anthropic  — Claude models (Opus, Sonnet, Haiku)"
  echo "    openai     — GPT-4o, o3, o4-mini"
  echo "    google     — Gemini 2.5 Pro/Flash"
  echo "    zai        — GLM-5, GLM-4.7 (free)"
  echo "    ollama     — Local models via Ollama"
  echo "    openrouter — OpenRouter (many providers)"
  echo ""

  echo -en "${CYAN}Provider type: ${NC}"
  read -r type
  if [[ -z "$type" ]]; then
    log_error "Type is required."; return 1
  fi

  case "$type" in
    anthropic|openai|google|zai|ollama|openrouter) ;;
    *) log_error "Unknown provider type '$type'. Supported: anthropic, openai, google, zai, ollama, openrouter"; return 1 ;;
  esac

  echo -en "${CYAN}Subscription name (e.g., anthropic-max1, openai-team): ${NC}"
  read -r name
  if [[ -z "$name" ]]; then
    log_error "Name is required."; return 1
  fi

  echo -en "${CYAN}Label (human-readable, e.g., 'Anthropic Max Plan 1'): ${NC}"
  read -r label
  label="${label:-$name}"

  echo -en "${CYAN}API key: ${NC}"
  read -rs api_key
  echo ""
  if [[ -z "$api_key" ]]; then
    log_error "API key is required."; return 1
  fi

  local base_url=""
  local default_url
    default_url="$(get_provider_url "$type")"
  if [[ -n "$default_url" ]]; then
    echo -en "${CYAN}Base URL [${default_url}]: ${NC}"
    read -r input_url
    base_url="${input_url:-$default_url}"
  fi

  # Offer to add custom model IDs
  echo ""
  echo -e "  ${BOLD}Default models for $type:${NC}"
  local default_models
  case "$type" in
    anthropic)  default_models="$ANTHROPIC_MODELS" ;;
    openai)     default_models="$OPENAI_MODELS" ;;
    google)     default_models="$GOOGLE_MODELS" ;;
    zai)        default_models="$ZAI_MODELS" ;;
    ollama)     default_models="$OLLAMA_MODELS" ;;
    openrouter) default_models="$OPENROUTER_MODELS" ;;
    *)          default_models="[]" ;;
  esac
  echo "$default_models" | jq -r '.[] | "    \(.id) — \(.name)"' 2>/dev/null

  echo ""
  echo -en "${CYAN}Add custom model IDs? (comma-separated, or Enter to use defaults): ${NC}"
  read -r custom_models

  if [[ -n "$custom_models" ]]; then
    # Parse comma-separated model IDs and add them to the defaults
    local extra_json="[]"
    IFS=',' read -ra model_ids <<< "$custom_models"
    for mid in "${model_ids[@]}"; do
      mid=$(echo "$mid" | xargs)  # trim whitespace
      [[ -z "$mid" ]] && continue
      extra_json=$(echo "$extra_json" | jq --arg id "$mid" --arg name "$mid" \
        '. + [{"id": $id, "name": $name, "reasoning": false, "input": ["text"], "contextWindow": 128000, "maxTokens": 8192}]')
    done
    # Merge with defaults
    default_models=$(echo "$default_models" "$extra_json" | jq -s '.[0] + .[1] | unique_by(.id)')
  fi

  add_subscription "$name" "$type" "$api_key" "$label" "$base_url"

  # Override with discovered/custom models if any
  if [[ -n "$custom_models" ]]; then
    local updated
    updated=$(jq --arg name "$name" --argjson models "$default_models" \
      '.subscriptions[$name].models = $models' "$PROVIDERS_FILE")
    atomic_json_write "$PROVIDERS_FILE" "$updated"
    chmod 600 "$PROVIDERS_FILE"
    log_ok "Updated models for subscription '$name'"
  fi
}

# Interactive model allocation
interactive_allocate_model() {
  local agent_name="${1:-}"

  if [[ -z "$agent_name" ]]; then
    echo -en "${CYAN}Agent name: ${NC}"
    read -r agent_name
  fi

  init_providers
  echo ""
  echo -e "${BOLD}Available models:${NC}"
  jq -r '.subscriptions | to_entries[] | .key as $sub | .value.models[]? | "  \($sub)/\(.id)  (\(.name))"' "$PROVIDERS_FILE"
  echo ""

  echo -en "${CYAN}Primary model (subscription/model): ${NC}"
  read -r primary

  local fallbacks; fallbacks=()
  while true; do
    echo -en "${CYAN}Fallback model (empty to finish): ${NC}"
    read -r fb
    [[ -z "$fb" ]] && break
    fallbacks+=("$fb")
  done

  allocate_model "$agent_name" "$primary" ${fallbacks[@]+"${fallbacks[@]}"}
}

# Print model allocations for all agents
print_allocations() {
  init_providers

  echo ""
  echo -e "${BOLD}Model Allocations${NC}"
  echo -e "${BOLD}$(printf '=%.0s' {1..78})${NC}"
  printf "  ${BOLD}%-15s %-30s %-30s${NC}\n" "AGENT" "PRIMARY" "FALLBACKS"
  echo "  $(printf -- '-%.0s' {1..76})"

  for name in $(registry_list_agents); do
    local allocation
    allocation=$(get_agent_allocation "$name")
    local primary="-"
    local fallbacks="-"

    if [[ "$allocation" != "null" ]]; then
      primary=$(echo "$allocation" | jq -r '.primary')
      fallbacks=$(echo "$allocation" | jq -r '.fallbacks | join(", ") | if . == "" then "-" else . end')
    fi

    printf "  %-15s %-30s %-30s\n" "$name" "$primary" "$fallbacks"
  done
  echo ""
}
