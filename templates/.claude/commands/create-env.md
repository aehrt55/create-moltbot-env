# Create New Moltbot Environment

Read `.moltbot-env.json` for config values. Use `<envRepo>` as a placeholder for the env repo slug (read from `.moltbot-env.json` → `envRepo` field) in all `gh` CLI calls. Use `<cfAccountId>` and `<workersSubdomain>` from the config for URLs and domains.

You are creating a new moltbot environment. Follow these phases exactly.

## Phase 1 — Collect Information

Use AskUserQuestion to gather the following:

**Question 1: Environment name**
Ask "What should the environment be named?" with a text input. The name will be used as `moltbot-<name>` for the worker and `moltbot-<name>-data` for the R2 bucket. Suggest a short kebab-case name (e.g. `test-sub-auth`, `staging`).

**Question 2: Auth mode**
Ask "How should users authenticate for AI access?" with these options:
- Subscription only (Recommended) — users bring their own API keys via `/claude_auth` or `/openai_auth`. No server-side API keys needed.
- Server API keys — environment provides API keys for all users.
- Both — server API keys as default, with subscription auth as an option.

**Question 3: Default model**
Ask "Which default model?" with these options:
- `google/gemini-3-flash-preview` (Recommended)
- `anthropic/claude-sonnet-4-6`
- `openai/gpt-4o`

Note: For "Subscription only" mode, this model is used as the initial default but users will switch to their own provider after authenticating.

**Question 4: Bedrock**
Ask "Need Bedrock model fallback?" with these options:
- No
- `claude-sonnet-4-6`
- `claude-haiku-4-5`

Save the auth mode choice for later phases. Define:
- `is_subscription` = true if auth mode is "Subscription only" or "Both"
- `needs_api_keys` = true if auth mode is "Server API keys" or "Both"

## Phase 2 — Create Infrastructure

The script auto-loads `CF_ACCESS_API_TOKEN` from the credentials config in `.moltbot-env.json`. If that fails, use AskUserQuestion to ask how to provide it:
- "Paste manually" — use AskUserQuestion to ask the user to paste their CF_ACCESS_API_TOKEN.

Then run the create-env script:
   ```bash
   CF_ACCESS_API_TOKEN="<token-if-manual>" DEFAULT_MODEL="<chosen-model>" BEDROCK_DEFAULT_MODEL="<chosen-bedrock-or-empty>" SUBSCRIPTION_AUTH="<true-or-empty>" bash scripts/create-env.sh <env-name>
   ```
   - If BEDROCK_DEFAULT_MODEL is "No" or empty, omit it entirely.
   - If `is_subscription` is true, set `SUBSCRIPTION_AUTH=true`. Otherwise omit it.

3. Show the user the results (R2 bucket, CF Access AUD, overlay directory).

4. Capture `ENV_AGE_PUBLIC_KEY` and `ENV_AGE_PRIVATE_KEY` from the script output. Show:

   > **Public key** (saved to `.sops.yaml`): `<ENV_AGE_PUBLIC_KEY>`
   > **Private key**: `<ENV_AGE_PRIVATE_KEY>`

5. Use AskUserQuestion: "Configure GitHub Actions environment and branch protection now?" with options:
   - Yes, set it up via `gh` CLI (Recommended)
   - No, I'll set it up manually later

   **If yes**, run the following steps in order:

   a. Create GitHub environment with deployment branch policy:
      ```bash
      gh api --method PUT /repos/<envRepo>/environments/<env-name> \
        --input - <<< '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
      ```

   b. Add allowed deployment branches (main + env branch):
      ```bash
      gh api --method POST /repos/<envRepo>/environments/<env-name>/deployment-branch-policies \
        -f name=main -f type=branch 2>/dev/null || true
      gh api --method POST /repos/<envRepo>/environments/<env-name>/deployment-branch-policies \
        -f name=<env-name> -f type=branch 2>/dev/null || true
      ```

   c. Set SOPS_AGE_KEY secret:
      ```bash
      gh secret set SOPS_AGE_KEY --env <env-name> --body "<ENV_AGE_PRIVATE_KEY>" -R <envRepo>
      ```

   d. Add env branch to "Environment branches" ruleset (skip with warning if ruleset doesn't exist or requires Pro):
      ```bash
      ruleset_id=$(gh api /repos/<envRepo>/rulesets --jq '.[] | select(.name == "Environment branches") | .id' 2>/dev/null)
      ```
      If ruleset exists, fetch current include list, append `refs/heads/<env-name>`, and update. If not, warn:
      > Branch protection ruleset not available. Deployment branch policy still protects secret access.

   Tell the user: "GitHub environment `<env-name>` configured: SOPS_AGE_KEY set, deployment branches restricted to `main` + `<env-name>`."

   **If no**, show:
   > To set up later, run `/setup-env-age-key` or manually go to **Settings → Environments → `<env-name>`** and add secret `SOPS_AGE_KEY`.

## Phase 3 — R2 Access Key (Manual Step)

Read `cfAccountId` from `.moltbot-env.json` and tell the user:

> You need to create an R2 API Token manually from the Cloudflare dashboard:
>
> 1. Go to https://dash.cloudflare.com/<cfAccountId>/r2/api-tokens
> 2. Click "Create API Token"
> 3. Select the `moltbot-<env-name>-data` bucket
> 4. Grant "Object Read & Write" permission
> 5. Click "Create API Token"
> 6. Copy the **Access Key ID** and **Secret Access Key**

Then use AskUserQuestion to collect:
- "Paste your R2 Access Key ID"
- "Paste your R2 Secret Access Key"

## Phase 4 — Create secrets.json

1. Generate a random `MOLTBOT_GATEWAY_TOKEN`:
   ```bash
   openssl rand -hex 32
   ```

2. **If `needs_api_keys` is true:** Ask the user with AskUserQuestion (multiSelect: true): "Which API key secrets do you want to add?" with options:
   - ANTHROPIC_API_KEY
   - GOOGLE_API_KEY
   - OPENAI_API_KEY

   For each selected key, use AskUserQuestion to ask the user to paste the value.

   **If `needs_api_keys` is false (subscription only):** Skip this step. Tell the user: "Subscription-only mode — no server-side API keys needed. Users will authenticate via `/claude_auth` or `/openai_auth`."

3. Build the secrets JSON object with all collected values:
   - `MOLTBOT_GATEWAY_TOKEN` (always)
   - `R2_ACCESS_KEY_ID` (from Phase 3)
   - `R2_SECRET_ACCESS_KEY` (from Phase 3)
   - Any selected API keys (only if `needs_api_keys`)

4. Create the encrypted secrets.json using sops. Verify `SOPS_AGE_KEY` is set, then:
   ```bash
   echo '<json-object>' | sops encrypt --input-type json --output-type json /dev/stdin > overlays/<env-name>/secrets.json
   ```

5. Verify the file was created and can be decrypted:
   ```bash
   sops decrypt overlays/<env-name>/secrets.json | jq keys
   ```

## Phase 5 — Deploy

Use AskUserQuestion: "Deploy now?" with options:
- Yes, deploy now
- No, I'll deploy later

If yes:
```bash
cd overlays/<env-name> && make deploy
```

If no, show:
```
To deploy later:
  cd overlays/<env-name> && make deploy
```

After deployment (or showing the deploy-later command), read `workersSubdomain` from `.moltbot-env.json` and display:

> **Chat:** `https://moltbot-<env-name>.<workersSubdomain>.workers.dev/?token=<MOLTBOT_GATEWAY_TOKEN>`
> **Admin:** `https://moltbot-<env-name>.<workersSubdomain>.workers.dev/_admin`

Use the actual `MOLTBOT_GATEWAY_TOKEN` value generated in Phase 4.

## Important Notes

- The script creates: R2 bucket, CF Access app + policy, overlay directory (wrangler.jsonc, version.txt, Makefile symlink), and updates .sops.yaml
- R2 API Tokens cannot be created via CLI — the user must create them manually from the CF dashboard
- `SOPS_AGE_KEY` must be set for sops encryption to work
- After deployment, the worker will be available at `moltbot-<env-name>.<workersSubdomain>.workers.dev`
- When `SUBSCRIPTION_AUTH=true`, the worker starts without API keys. Users authenticate via `/claude_auth` or `/openai_auth` commands in the chat.
