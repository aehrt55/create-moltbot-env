# Setup Environment AGE Key for CI/CD

Read `.moltbot-env.json` for config values. Use `<envRepo>` as a placeholder for the env repo slug (read from `.moltbot-env.json` → `envRepo` field) in all `gh` CLI calls.

Generate (or regenerate) an AGE key pair for an environment's CI/CD deployment. The public key is added to `.sops.yaml` so CI/CD can decrypt secrets; the private key must be stored as a GitHub Actions environment secret.

Use this when:
- Setting up CI/CD for an existing environment that doesn't have an env key yet
- Regenerating a compromised or lost key
- Retroactively adding CI/CD to environments created before the deploy workflow

## Phase 1 — Select Environment

1. List existing overlay directories:
   ```bash
   ls -d overlays/*/
   ```

2. Use AskUserQuestion to ask "Which environment needs an AGE key?" with the overlay names as options.

## Phase 2 — Generate Key Pair

Run the setup script:
```bash
bash scripts/setup-env-age-key.sh <env-name>
```

The script will:
- Generate a new AGE key pair
- Update `.sops.yaml` to include the env public key alongside the manager key
- Re-encrypt `secrets.json` if it exists (requires `SOPS_AGE_KEY`)

Capture the `ENV_AGE_PUBLIC_KEY` and `ENV_AGE_PRIVATE_KEY` from the output.

## Phase 3 — GitHub Actions Setup

Show the user the generated keys:

> **Public key** (saved to `.sops.yaml`): `<ENV_AGE_PUBLIC_KEY>`
> **Private key**: `<ENV_AGE_PRIVATE_KEY>`

Then use AskUserQuestion: "Configure GitHub Actions environment and branch protection now?" with options:
- Yes, set it up via `gh` CLI (Recommended)
- No, I'll set it up manually later

**If yes**, run the following steps in order:

1. Create GitHub environment with deployment branch policy:
   ```bash
   gh api --method PUT /repos/<envRepo>/environments/<env-name> \
     --input - <<< '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
   ```

2. Add allowed deployment branches (main + env branch):
   ```bash
   gh api --method POST /repos/<envRepo>/environments/<env-name>/deployment-branch-policies \
     -f name=main -f type=branch 2>/dev/null || true
   gh api --method POST /repos/<envRepo>/environments/<env-name>/deployment-branch-policies \
     -f name=<env-name> -f type=branch 2>/dev/null || true
   ```

3. Set SOPS_AGE_KEY secret:
   ```bash
   gh secret set SOPS_AGE_KEY --env <env-name> --body "<ENV_AGE_PRIVATE_KEY>" -R <envRepo>
   ```

4. Add env branch to "Environment branches" ruleset (requires GitHub Pro for private repos — skip with warning if unavailable):
   ```bash
   ruleset_id=$(gh api /repos/<envRepo>/rulesets --jq '.[] | select(.name == "Environment branches") | .id' 2>/dev/null)
   ```
   - **If ruleset exists**: fetch current include list, append `refs/heads/<env-name>`, update:
     ```bash
     current=$(gh api /repos/<envRepo>/rulesets/$ruleset_id --jq '.conditions.ref_name.include')
     updated=$(echo "$current" | jq --arg b "refs/heads/<env-name>" '. + [$b] | unique')
     gh api --method PUT /repos/<envRepo>/rulesets/$ruleset_id \
       --input - <<< "{\"conditions\":{\"ref_name\":{\"include\":$updated,\"exclude\":[]}}}"
     ```
   - **If ruleset doesn't exist**: try to create it with the full rule set (deletion + non_fast_forward + pull_request with 1 reviewer). If creation fails (403 / requires Pro), warn:
     > Branch protection ruleset requires GitHub Pro for private repos. Skipping — deployment branch policy still protects secret access. Consider upgrading or making the repo public to enable branch protection.

Tell the user: "GitHub environment `<env-name>` configured: SOPS_AGE_KEY set, deployment branches restricted to `main` + `<env-name>`."

**If no**, show:
> To set up later, run `/setup-env-age-key` or manually:
> 1. Go to the repo's **Settings → Environments → `<env-name>`**
> 2. Add secret `SOPS_AGE_KEY` = `<ENV_AGE_PRIVATE_KEY>`
> 3. Set deployment branch policy to allow only `main` and `<env-name>`

Remind the user to commit the `.sops.yaml` changes (and `secrets.json` if re-encrypted).

## Important Notes

- The script replaces any existing env key in `.sops.yaml` for this environment
- If `secrets.json` exists, it will be re-encrypted with `sops updatekeys` so the new key can decrypt it
- `SOPS_AGE_KEY` (manager private key) is auto-loaded from credentials config if available
- The private key is sensitive — only store it in GitHub Actions secrets, never commit it
- Deployment branch policy ensures only `main` and the env's own branch can access its secrets
- The "Environment branches" ruleset (when available) enforces PR reviews + blocks force push/deletion on env branches
