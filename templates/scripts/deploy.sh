#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_NAME="${1:?Usage: deploy.sh <environment>}"
OVERLAY_DIR="$ROOT_DIR/overlays/$ENV_NAME"

if [[ ! -d "$OVERLAY_DIR" ]]; then
  echo "Error: overlay '$ENV_NAME' not found at $OVERLAY_DIR" >&2; exit 1
fi

# In CI, CLOUDFLARE_API_TOKEN must be set; locally, wrangler uses its own OAuth session
if [[ -n "${CI:-}" ]]; then
  [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || { echo "Error: CLOUDFLARE_API_TOKEN not set" >&2; exit 1; }
fi

CONFIG="$ROOT_DIR/.moltbot-env.json"
[[ -f "$CONFIG" ]] || { echo "Error: .moltbot-env.json not found" >&2; exit 1; }

APP_REPO_SLUG=$(jq -re '.appRepo // empty' "$CONFIG") || { echo "Error: appRepo missing from .moltbot-env.json" >&2; exit 1; }
CF_ACCOUNT_ID=$(jq -re '.cfAccountId // empty' "$CONFIG") || { echo "Error: cfAccountId missing from .moltbot-env.json" >&2; exit 1; }

VERSION=$(tr -d '[:space:]' < "$OVERLAY_DIR/version.txt")
[[ "$VERSION" =~ ^[0-9a-f]{7,40}$ ]] || { echo "Error: invalid SHA in version.txt: '$VERSION'" >&2; exit 1; }
APP_REPO="${APP_REPO:-git@github.com:${APP_REPO_SLUG}.git}"
case "$APP_REPO" in
  https://*|git@*|/*) ;;
  */*) APP_REPO="git@github.com:${APP_REPO}.git" ;;
esac
# Validate SOPS_AGE_KEY before deploying to prevent partial deploys (code without secrets)
if [[ -f "$OVERLAY_DIR/secrets.json" ]]; then
  [[ -n "${SOPS_AGE_KEY:-}" ]] || { echo "Error: SOPS_AGE_KEY not set but secrets.json exists — would cause partial deploy" >&2; exit 1; }
fi

WORK_DIR="/tmp/deploy-moltbot-$$"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "▶ Deploying moltbot @ ${VERSION} (${ENV_NAME})"

# 1. Clone app repo at pinned version
git clone "$APP_REPO" "$WORK_DIR"
cd "$WORK_DIR"
git checkout "$VERSION"

# 2. Install dependencies
npm ci

# 3. Merge configs: base (app repo) + overlay (env repo)
echo "▶ Merging wrangler config..."
STRIP="node $SCRIPT_DIR/jsonc-strip.js"
merged=$(mktemp)
jq -s --arg acct "$CF_ACCOUNT_ID" '.[0] * .[1] * {account_id: $acct}' <($STRIP "$WORK_DIR/wrangler.jsonc") <($STRIP "$OVERLAY_DIR/wrangler.jsonc") > "$merged"
mv "$merged" "$WORK_DIR/wrangler.jsonc"

# 4. Deploy
npx wrangler deploy

# 5. Push secrets (if secrets.json exists)
if [[ -f "$OVERLAY_DIR/secrets.json" ]]; then
  echo "▶ Deploying secrets..."
  secrets=$(mktemp)
  trap 'rm -rf "$WORK_DIR" "$secrets"' EXIT
  sops decrypt "$OVERLAY_DIR/secrets.json" > "$secrets"
  npx wrangler secret bulk "$secrets"
  rm -f "$secrets"
fi

echo "✅ Deploy complete: moltbot @ ${VERSION} (${ENV_NAME})"
