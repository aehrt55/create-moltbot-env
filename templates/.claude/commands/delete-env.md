# Delete Moltbot Environment

Read `.moltbot-env.json` for config values. Use `<envRepo>` as a placeholder for the env repo slug (read from `.moltbot-env.json` → `envRepo` field) in all `gh` CLI calls. Use `<cfAccountId>` from the config for dashboard URLs.

You are deleting a moltbot environment. This is a destructive operation. Follow these phases exactly.

## Phase 1 — Select Environment

1. List existing overlay directories by running:
   ```bash
   ls -d overlays/*/
   ```

2. Use AskUserQuestion to ask "Which environment do you want to delete?" with the overlay names as options.

3. Parse the selected environment's `wrangler.jsonc` to extract the worker name and R2 bucket name:
   ```bash
   node scripts/jsonc-strip.js overlays/<env-name>/wrangler.jsonc | jq '{name, bucket: .r2_buckets[0].bucket_name}'
   ```

4. Show the user what will be destroyed:
   > **The following resources will be permanently deleted:**
   >
   > - Cloudflare Worker: `<worker-name>`
   > - Container app: `<worker-name>-sandbox`
   > - Cloudflare Access app: `moltbot-<env-name>`
   > - R2 bucket: `<bucket-name>`
   > - Overlay directory: `overlays/<env-name>/`
   > - `.sops.yaml` rule for this environment

5. Use AskUserQuestion to confirm: "Are you sure you want to delete this environment? This is irreversible." with options:
   - Yes, delete everything
   - No, cancel

   If the user cancels, stop immediately.

## Phase 1.5 — Export Secrets

If `overlays/<env-name>/secrets.json` exists, use AskUserQuestion to ask: "Export a plaintext copy of secrets before deletion?" with options:
- Yes — save to `_<env-name>.secrets.json`
- No

If yes:
```bash
sops decrypt overlays/<env-name>/secrets.json > _<env-name>.secrets.json
```
Tell the user: "Plaintext secrets saved to `_<env-name>.secrets.json`. This file is in `.gitignore` and won't be committed. Delete it when you no longer need it."

## Phase 2 — Delete Infrastructure

The script auto-loads credentials from `.moltbot-env.json`. Run the delete-env script:
```bash
bash scripts/delete-env.sh <env-name>
```

Show the user the results.

## Phase 3 — GitHub Actions Cleanup

Use AskUserQuestion: "Clean up GitHub Actions environment and branch protection for `<env-name>`?" with options:
- Yes, clean up via `gh` CLI (Recommended)
- No, I'll handle it manually

**If yes**, run the following steps:

1. Remove env branch from "Environment branches" ruleset (skip if ruleset doesn't exist):
   ```bash
   ruleset_id=$(gh api /repos/<envRepo>/rulesets --jq '.[] | select(.name == "Environment branches") | .id' 2>/dev/null)
   ```
   If ruleset exists, fetch current include list, remove `refs/heads/<env-name>`, and update.

2. Delete GitHub environment (removes secrets + deployment branch policies):
   ```bash
   gh api --method DELETE /repos/<envRepo>/environments/<env-name>
   ```

3. Delete the env branch if it exists:
   ```bash
   gh api --method DELETE /repos/<envRepo>/git/refs/heads/<env-name> 2>/dev/null || true
   ```

Tell the user: "GitHub environment `<env-name>` deleted (including secrets, deployment policies, and branch)."

**If no**, show:
> Manual cleanup:
> 1. Go to **Settings → Environments** and delete `<env-name>`
> 2. Delete the `<env-name>` branch if it exists
> 3. Remove `<env-name>` from the "Environment branches" ruleset (if applicable)

## Phase 4 — Manual Cleanup Reminders

Read `cfAccountId` from `.moltbot-env.json` and tell the user:

> **Manual cleanup needed:**
>
> 1. **Delete R2 API Token** — Go to https://dash.cloudflare.com/<cfAccountId>/r2/api-tokens and delete the token for this environment's bucket.

## Important Notes

- The script deletes: Worker, container app, CF Access app + policies, R2 bucket, overlay directory, and .sops.yaml rule
- R2 bucket deletion will fail if the bucket is non-empty — the script will show instructions for emptying it
- Non-critical failures (e.g., resource already deleted) are logged as warnings but don't stop the script
- After deletion, remember to commit the changes to `.sops.yaml` and the removed overlay directory
