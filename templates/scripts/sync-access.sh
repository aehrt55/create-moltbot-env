#!/usr/bin/env bash
set -euo pipefail

# sync-access.sh — Ensure Cloudflare Access Applications match desired state
#
# For each overlay, ensures:
# 1. A main Access app exists (domain-level protection)
# 2. A webhook bypass app exists if TELEGRAM_WEBHOOK_SECRET is in secrets
#
# Usage: sync-access.sh <env-name>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_NAME="${1:?Usage: sync-access.sh <env-name>}"
OVERLAY_DIR="$ROOT_DIR/overlays/$ENV_NAME"

CONFIG="$ROOT_DIR/.moltbot-env.json"
[[ -f "$CONFIG" ]] || { echo "Error: .moltbot-env.json not found" >&2; exit 1; }

CF_ACCOUNT_ID=$(jq -re '.cfAccountId // empty' "$CONFIG") || { echo "Error: cfAccountId missing from .moltbot-env.json" >&2; exit 1; }
WORKERS_SUBDOMAIN=$(jq -re '.workersSubdomain // empty' "$CONFIG") || { echo "Error: workersSubdomain missing from .moltbot-env.json" >&2; exit 1; }
API_BASE="https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/access/apps"

# --- Credential loading ---

load_credential() {
  local key="$1" config="$2"
  local source=$(jq -r --arg k "$key" '.credentials[$k].source' "$config")
  if [[ "$source" == "keychain" ]] && command -v security &>/dev/null; then
    local account=$(jq -r --arg k "$key" '.credentials[$k].keychainAccount' "$config")
    local service=$(jq -r --arg k "$key" '.credentials[$k].keychainService' "$config")
    security find-generic-password -a "$account" -s "$service" -w 2>/dev/null || true
  fi
}

# --- Validation ---

if [[ ! -d "$OVERLAY_DIR" ]]; then
  echo "Error: overlay '$ENV_NAME' not found at $OVERLAY_DIR" >&2
  exit 1
fi

for cmd in curl jq node npx; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required tool not found: $cmd" >&2
    exit 1
  fi
done

if [[ -z "${CF_ACCESS_API_TOKEN:-}" ]]; then
  CF_ACCESS_API_TOKEN=$(load_credential cfAccessApiToken "$CONFIG")
  export CF_ACCESS_API_TOKEN
fi

if [[ -z "${CF_ACCESS_API_TOKEN:-}" ]]; then
  echo "Error: CF_ACCESS_API_TOKEN environment variable is required." >&2
  echo "  See docs/cf-api-token.md for how to create one." >&2
  exit 1
fi

# Unset wrangler-recognized token vars so wrangler uses its own login session
unset CF_API_TOKEN CLOUDFLARE_API_TOKEN

STRIP="node $SCRIPT_DIR/jsonc-strip.js"
WORKER_NAME=$($STRIP "$OVERLAY_DIR/wrangler.jsonc" | jq -r '.name')
WORKER_DOMAIN="${WORKER_NAME}.${WORKERS_SUBDOMAIN}.workers.dev"
MAIN_APP_NAME="${WORKER_NAME} - Cloudflare Workers"
WEBHOOK_APP_NAME="${WORKER_NAME}-telegram-webhook"
WEBHOOK_DOMAIN="${WORKER_DOMAIN}/telegram/webhook"

# --- Fetch current Access apps ---

echo "▶ Fetching Access apps for account..."
APPS_RESPONSE=$(curl -s "$API_BASE" \
  -H "Authorization: Bearer $CF_ACCESS_API_TOKEN")

if [[ "$(echo "$APPS_RESPONSE" | jq -r '.success')" != "true" ]]; then
  echo "Error: Failed to list Access apps:" >&2
  echo "$APPS_RESPONSE" | jq . >&2
  exit 1
fi

# Check main app
MAIN_APP=$(echo "$APPS_RESPONSE" | jq -r --arg name "$MAIN_APP_NAME" '.result[] | select(.name == $name)')
if [[ -z "$MAIN_APP" ]]; then
  echo "  ⚠ Main Access app '$MAIN_APP_NAME' not found"
  echo "  Run create-env.sh first or create it manually." >&2
  exit 1
fi
MAIN_APP_ID=$(echo "$MAIN_APP" | jq -r '.id')
echo "  Main app: $MAIN_APP_NAME (ID: $MAIN_APP_ID)"

# Check webhook bypass app
WEBHOOK_APP=$(echo "$APPS_RESPONSE" | jq -r --arg name "$WEBHOOK_APP_NAME" '.result[] | select(.name == $name)')
WEBHOOK_APP_ID=""
if [[ -n "$WEBHOOK_APP" ]]; then
  WEBHOOK_APP_ID=$(echo "$WEBHOOK_APP" | jq -r '.id')
  echo "  Webhook bypass app: $WEBHOOK_APP_NAME (ID: $WEBHOOK_APP_ID)"
else
  echo "  Webhook bypass app: not found"
fi

# --- Determine desired state ---

# Check if TELEGRAM_WEBHOOK_SECRET is configured as a wrangler secret
WANTS_WEBHOOK=false
echo ""
echo "▶ Checking wrangler secrets..."
WRANGLER_TMP=$(mktemp).json
$STRIP "$OVERLAY_DIR/wrangler.jsonc" > "$WRANGLER_TMP"
SECRET_LIST=$(npx wrangler secret list --config "$WRANGLER_TMP" 2>/dev/null || echo "[]")
rm -f "$WRANGLER_TMP"
if echo "$SECRET_LIST" | jq -e '.[] | select(.name == "TELEGRAM_WEBHOOK_SECRET")' &>/dev/null; then
  WANTS_WEBHOOK=true
fi

echo ""
echo "  Desired webhook bypass: $WANTS_WEBHOOK"

# --- Reconcile ---

if [[ "$WANTS_WEBHOOK" == "true" && -z "$WEBHOOK_APP_ID" ]]; then
  # Create webhook bypass app
  echo ""
  echo "▶ Creating webhook bypass app: $WEBHOOK_APP_NAME"
  echo "  Domain: $WEBHOOK_DOMAIN"

  CREATE_RESPONSE=$(curl -s -X POST "$API_BASE" \
    -H "Authorization: Bearer $CF_ACCESS_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${WEBHOOK_APP_NAME}\",
      \"type\": \"self_hosted\",
      \"domain\": \"${WEBHOOK_DOMAIN}\",
      \"session_duration\": \"24h\"
    }")

  if [[ "$(echo "$CREATE_RESPONSE" | jq -r '.success')" != "true" ]]; then
    echo "Error: Failed to create webhook bypass app:" >&2
    echo "$CREATE_RESPONSE" | jq . >&2
    exit 1
  fi

  WEBHOOK_APP_ID=$(echo "$CREATE_RESPONSE" | jq -r '.result.id')
  echo "  Created (ID: $WEBHOOK_APP_ID)"

  # Add bypass policy
  echo "▶ Creating bypass policy: Bypass Everyone"
  POLICY_RESPONSE=$(curl -s -X POST \
    "$API_BASE/$WEBHOOK_APP_ID/policies" \
    -H "Authorization: Bearer $CF_ACCESS_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "Bypass Everyone",
      "decision": "bypass",
      "include": [{"everyone": {}}]
    }')

  if [[ "$(echo "$POLICY_RESPONSE" | jq -r '.success')" != "true" ]]; then
    echo "Error: Failed to create bypass policy:" >&2
    echo "$POLICY_RESPONSE" | jq . >&2
    exit 1
  fi

  echo "  Policy created"
  echo ""
  echo "✅ Webhook bypass app created: $WEBHOOK_DOMAIN"

elif [[ "$WANTS_WEBHOOK" == "false" && -n "$WEBHOOK_APP_ID" ]]; then
  # Delete webhook bypass app (no longer needed)
  echo ""
  echo "▶ Deleting webhook bypass app: $WEBHOOK_APP_NAME (no longer needed)"

  DELETE_RESPONSE=$(curl -s -X DELETE \
    "$API_BASE/$WEBHOOK_APP_ID" \
    -H "Authorization: Bearer $CF_ACCESS_API_TOKEN")

  if [[ "$(echo "$DELETE_RESPONSE" | jq -r '.success')" == "true" ]]; then
    echo "  Deleted"
  else
    echo "  ⚠ Failed to delete:" >&2
    echo "$DELETE_RESPONSE" | jq . >&2
  fi

  echo ""
  echo "✅ Webhook bypass app removed"

else
  echo ""
  if [[ "$WANTS_WEBHOOK" == "true" ]]; then
    echo "✅ Webhook bypass app already exists — no changes needed"
  else
    echo "✅ No webhook bypass needed — no changes needed"
  fi
fi
