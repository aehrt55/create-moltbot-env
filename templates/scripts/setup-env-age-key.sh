#!/usr/bin/env bash
set -euo pipefail

# Generate (or regenerate) an AGE key pair for an environment.
# Updates .sops.yaml to include the env public key alongside the manager key.
# Re-encrypts secrets.json if it exists (requires SOPS_AGE_KEY).
#
# Output (last 2 lines, machine-readable):
#   ENV_AGE_PUBLIC_KEY=age1...
#   ENV_AGE_PRIVATE_KEY=AGE-SECRET-KEY-1...

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_NAME="${1:?Usage: setup-env-age-key.sh <environment>}"
OVERLAY_DIR="$ROOT_DIR/overlays/$ENV_NAME"
SOPS_FILE="$ROOT_DIR/.sops.yaml"
SOPS_TMP=""
trap 'rm -f "$SOPS_TMP"' EXIT

CONFIG="$ROOT_DIR/.moltbot-env.json"
[[ -f "$CONFIG" ]] || { echo "Error: .moltbot-env.json not found" >&2; exit 1; }

MANAGER_AGE_KEY=$(jq -re '.managerAgeKey // empty' "$CONFIG") || { echo "Error: managerAgeKey missing from .moltbot-env.json" >&2; exit 1; }

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

if ! command -v age-keygen &>/dev/null; then
  echo "Error: age-keygen not found on PATH" >&2
  exit 1
fi

if ! grep -q "path_regex: overlays/${ENV_NAME}/secrets" "$SOPS_FILE" 2>/dev/null; then
  echo "Error: no .sops.yaml rule found for '$ENV_NAME'" >&2
  exit 1
fi

# --- Generate key pair ---

KEYGEN_OUTPUT=$(age-keygen 2>&1)
PUBLIC_KEY=$(echo "$KEYGEN_OUTPUT" | grep "public key:" | awk '{print $NF}')
PRIVATE_KEY=$(echo "$KEYGEN_OUTPUT" | grep "AGE-SECRET-KEY-")

if [[ -z "$PUBLIC_KEY" || -z "$PRIVATE_KEY" ]]; then
  echo "Error: failed to generate AGE key pair" >&2
  exit 1
fi

# --- Update .sops.yaml ---

echo "▶ Updating .sops.yaml for $ENV_NAME"

# Strategy: single atomic pass — remove existing rule + insert new rule
SOPS_TMP=$(mktemp)
awk -v env="$ENV_NAME" -v env_key="$PUBLIC_KEY" -v mgr_key="$MANAGER_AGE_KEY" '
  BEGIN { skip = 0; inserted = 0 }
  $0 ~ "path_regex: overlays/" env "/secrets" { skip = 1; next }
  skip && /^  - path_regex:/ { skip = 0 }
  skip && /^[^ ]/ { skip = 0 }
  skip && /^$/ { next }
  skip { next }
  /^# Per-env key generation steps/ && !inserted {
    print "  - path_regex: overlays/" env "/secrets\\.json$"
    print "    age: >-"
    print "      " env_key ","
    print "      " mgr_key
    print "    # env, manager"
    print ""
    inserted = 1
  }
  { print }
' "$SOPS_FILE" > "$SOPS_TMP" && mv "$SOPS_TMP" "$SOPS_FILE"

echo "  .sops.yaml updated"

# --- Re-encrypt secrets if they exist ---

if [[ -f "$OVERLAY_DIR/secrets.json" ]]; then
  echo "▶ Re-encrypting secrets.json with new key..."

  # Auto-load SOPS_AGE_KEY from config credentials if not already set
  if [[ -z "${SOPS_AGE_KEY:-}" ]]; then
    SOPS_AGE_KEY=$(load_credential sopsAgeKey "$CONFIG")
    export SOPS_AGE_KEY
  fi

  if [[ -z "${SOPS_AGE_KEY:-}" ]]; then
    echo "ERROR: SOPS_AGE_KEY not set — secrets.json was NOT re-encrypted." >&2
    echo "  .sops.yaml has been updated but secrets.json is out of sync." >&2
    echo "  You MUST re-encrypt: sops updatekeys overlays/$ENV_NAME/secrets.json" >&2
    exit 1
  else
    sops updatekeys -y "$OVERLAY_DIR/secrets.json"
    echo "  secrets.json re-encrypted"
  fi
fi

# --- Output ---

echo ""
# Design Decision: Private key printed to stdout for now; this script is interactive-only
# and not invoked in CI. Separating stdout/stderr output is deferred to a future PR.
echo "ENV_AGE_PUBLIC_KEY=$PUBLIC_KEY"
echo "ENV_AGE_PRIVATE_KEY=$PRIVATE_KEY"
