#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_NAME="${1:?Usage: delete-env.sh <env-name>}"
OVERLAY_DIR="$ROOT_DIR/overlays/$ENV_NAME"

CONFIG="$ROOT_DIR/.moltbot-env.json"
[[ -f "$CONFIG" ]] || { echo "Error: .moltbot-env.json not found" >&2; exit 1; }

CF_ACCOUNT_ID=$(jq -re '.cfAccountId // empty' "$CONFIG") || { echo "Error: cfAccountId missing from .moltbot-env.json" >&2; exit 1; }

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
  echo "Error: overlay directory not found: $OVERLAY_DIR" >&2
  exit 1
fi

for cmd in npx jq curl node; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required tool not found: $cmd" >&2
    exit 1
  fi
done

echo "▶ Checking wrangler auth..."
if ! npx wrangler whoami &>/dev/null; then
  echo "Error: wrangler is not logged in. Run 'npx wrangler login' first." >&2
  exit 1
fi

if [[ -z "${CF_ACCESS_API_TOKEN:-}" ]]; then
  CF_ACCESS_API_TOKEN=$(load_credential cfAccessApiToken "$CONFIG")
  export CF_ACCESS_API_TOKEN
fi

if [[ -z "${CF_ACCESS_API_TOKEN:-}" ]]; then
  echo "Error: CF_ACCESS_API_TOKEN environment variable is required (for Cloudflare Access API)." >&2
  echo "  See docs/cf-api-token.md for how to create one." >&2
  exit 1
fi

# Auto-load SOPS_AGE_KEY from config credentials if not already set
if [[ -z "${SOPS_AGE_KEY:-}" ]]; then
  SOPS_AGE_KEY=$(load_credential sopsAgeKey "$CONFIG")
  export SOPS_AGE_KEY
fi

# Unset wrangler-recognized token vars so wrangler uses its own login session
unset CF_API_TOKEN CLOUDFLARE_API_TOKEN

# --- Parse overlay config ---

WORKER_NAME=$(node "$SCRIPT_DIR/jsonc-strip.js" "$OVERLAY_DIR/wrangler.jsonc" | jq -r '.name')
BUCKET_NAME=$(node "$SCRIPT_DIR/jsonc-strip.js" "$OVERLAY_DIR/wrangler.jsonc" | jq -r '.r2_buckets[0].bucket_name')

echo ""
echo "Environment: $ENV_NAME"
echo "  Worker:    $WORKER_NAME"
echo "  R2 bucket: $BUCKET_NAME"
echo ""

# --- Delete Cloudflare Worker ---
# Design Decision: 2>/dev/null on destructive wrangler commands hides all errors (auth, network),
# not just "not found". A future improvement should capture stderr, distinguish "not found" from
# real errors, and surface unexpected failures before proceeding with overlay cleanup.

echo "▶ Deleting Cloudflare Worker: $WORKER_NAME"
if npx wrangler delete --name "$WORKER_NAME" --force 2>/dev/null; then
  echo "  Worker deleted"
else
  echo "  ⚠ Worker deletion failed (may not exist or already deleted)"
fi

# --- Delete Container App ---

CONTAINER_NAME="${WORKER_NAME}-sandbox"
echo "▶ Deleting container app: $CONTAINER_NAME"
# Design Decision: 2>/dev/null hides auth/network errors, making failures look like "not found".
# This is a low-frequency interactive script; improving stderr handling is deferred to a future PR.
CONTAINER_ID=$(npx wrangler containers list 2>/dev/null | jq -r --arg name "$CONTAINER_NAME" '.[] | select(.name == $name) | .id')

if [[ -n "$CONTAINER_ID" ]]; then
  if npx wrangler containers delete "$CONTAINER_ID" 2>/dev/null; then
    echo "  Deleted (ID: $CONTAINER_ID)"
  else
    echo "  ⚠ Container deletion failed"
  fi
else
  echo "  Not found, skipping"
fi

# --- Delete CF Access Apps ---

API_BASE="https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/access/apps"
MAIN_APP_NAME="${WORKER_NAME} - Cloudflare Workers"
WEBHOOK_APP_NAME="${WORKER_NAME}-telegram-webhook"

echo "▶ Fetching Access apps..."
APPS_RESPONSE=$(curl -s "$API_BASE" -H "Authorization: Bearer $CF_ACCESS_API_TOKEN")

if [[ "$(echo "$APPS_RESPONSE" | jq -r '.success')" != "true" ]]; then
  echo "  ⚠ Failed to list Access apps:" >&2
  echo "$APPS_RESPONSE" | jq . >&2
else
  # Delete webhook bypass app
  echo "▶ Deleting webhook bypass app: $WEBHOOK_APP_NAME"
  WEBHOOK_APP_ID=$(echo "$APPS_RESPONSE" | jq -r --arg name "$WEBHOOK_APP_NAME" '.result[] | select(.name == $name) | .id')

  if [[ -n "$WEBHOOK_APP_ID" ]]; then
    DELETE_RESPONSE=$(curl -s -X DELETE "$API_BASE/$WEBHOOK_APP_ID" \
      -H "Authorization: Bearer $CF_ACCESS_API_TOKEN")
    if [[ "$(echo "$DELETE_RESPONSE" | jq -r '.success')" == "true" ]]; then
      echo "  Deleted (ID: $WEBHOOK_APP_ID)"
    else
      echo "  ⚠ Failed to delete:" >&2
      echo "$DELETE_RESPONSE" | jq . >&2
    fi
  else
    echo "  Not found, skipping"
  fi

  # Delete main Access app
  echo "▶ Deleting main Access app: $MAIN_APP_NAME"
  MAIN_APP_ID=$(echo "$APPS_RESPONSE" | jq -r --arg name "$MAIN_APP_NAME" '.result[] | select(.name == $name) | .id')

  if [[ -n "$MAIN_APP_ID" ]]; then
    DELETE_RESPONSE=$(curl -s -X DELETE "$API_BASE/$MAIN_APP_ID" \
      -H "Authorization: Bearer $CF_ACCESS_API_TOKEN")
    if [[ "$(echo "$DELETE_RESPONSE" | jq -r '.success')" == "true" ]]; then
      echo "  Deleted (ID: $MAIN_APP_ID)"
    else
      echo "  ⚠ Failed to delete:" >&2
      echo "$DELETE_RESPONSE" | jq . >&2
    fi
  else
    echo "  Not found, skipping"
  fi
fi

# --- Delete R2 Bucket ---

echo "▶ Deleting R2 bucket: $BUCKET_NAME"

# Extract R2 credentials from secrets.json to empty the bucket via S3 API
R2_ENDPOINT="https://${CF_ACCOUNT_ID}.r2.cloudflarestorage.com"
if [[ -f "$OVERLAY_DIR/secrets.json" ]] && command -v sops &>/dev/null && command -v aws &>/dev/null && [[ -n "${SOPS_AGE_KEY:-}" ]]; then
  secrets_json=$(sops decrypt "$OVERLAY_DIR/secrets.json" 2>/dev/null) || secrets_json=""
  R2_KEY_ID=$(echo "$secrets_json" | jq -r '.R2_ACCESS_KEY_ID // empty')
  R2_SECRET=$(echo "$secrets_json" | jq -r '.R2_SECRET_ACCESS_KEY // empty')
  if [[ -n "$R2_KEY_ID" && -n "$R2_SECRET" ]]; then
    echo "  Emptying bucket via S3 API..."
    AWS_ACCESS_KEY_ID="$R2_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET" \
      aws s3 rm "s3://${BUCKET_NAME}" --recursive --endpoint-url "$R2_ENDPOINT" 2>/dev/null || true
  fi
fi

if npx wrangler r2 bucket delete "$BUCKET_NAME" 2>/dev/null; then
  echo "  R2 bucket deleted"
else
  echo "  ⚠ R2 bucket deletion failed (may be non-empty or already deleted)"
  echo "  Delete from dashboard: https://dash.cloudflare.com/$CF_ACCOUNT_ID/r2/default/buckets/$BUCKET_NAME"
fi

# --- Remove overlay directory ---

echo "▶ Removing overlay directory: overlays/$ENV_NAME/"
rm -rf "$OVERLAY_DIR"
echo "  Removed"

# --- Remove .sops.yaml rule ---

echo "▶ Removing .sops.yaml rule for $ENV_NAME"
SOPS_FILE="$ROOT_DIR/.sops.yaml"

if grep -q "path_regex: overlays/${ENV_NAME}/secrets" "$SOPS_FILE" 2>/dev/null; then
  SOPS_TMP=$(mktemp)
  awk -v env="$ENV_NAME" '
    BEGIN { skip = 0 }
    $0 ~ "path_regex: overlays/" env "/secrets" { skip = 1; next }
    skip && /^  - path_regex:/ { skip = 0 }
    skip && /^[^ ]/ { skip = 0 }
    skip && /^$/ { next }
    skip { next }
    { print }
  ' "$SOPS_FILE" > "$SOPS_TMP"
  mv "$SOPS_TMP" "$SOPS_FILE"
  echo "  Rule removed"
else
  echo "  No rule found for $ENV_NAME, skipping"
fi

# --- Summary ---

echo ""
echo "✅ Environment '$ENV_NAME' deleted successfully!"
echo ""
echo "Manual cleanup reminders:"
echo "  1. Delete R2 API Token from: https://dash.cloudflare.com/$CF_ACCOUNT_ID/r2/api-tokens"
echo "  2. Remove any CI/CD secrets for this environment"
