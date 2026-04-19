# sentry-bridge worker

Cloudflare Worker that receives Sentry webhooks and files GitHub issues on the
mapped repo, labelled so the archon auto-fix pipeline picks them up. This is a
free-tier replacement for Sentry's paid GitHub integration.

## Flow

```
Sentry issue.created
  → Internal Integration webhook (HMAC-SHA256 signed)
  → this worker (POST /sentry)
      - verify signature
      - map data.issue.project.slug → GitHub repo
      - dedup by "Sentry issue ID: <id>" body marker
      - create issue with labels [bug, sentry, archon:queued]
  → archon pipeline auto-queues it after 5 minutes
```

## One-time Sentry setup (user action)

Sentry org: `alex-siri` on the EU region (`de.sentry.io`).

1. Go to https://de.sentry.io/settings/alex-siri/developer-settings/ .
2. Click **Internal Integrations** → **Create New Integration**.
3. Fill in:
   - **Name:** `GitHub Issue Bridge`
   - **Webhook URL:** `https://sentry-bridge.alexsiri7.workers.dev/sentry`
   - **Alert Rule Action:** off (unless you want manual alert triggering too)
   - **Permissions → Issue & Event:** Read
   - **Webhooks:** check the `issue` resource
4. Save. Sentry auto-installs internal integrations into the org.
5. Click the integration, reveal the **Client Secret**, and copy it.
6. Store it in the worker:

   ```
   cd workers/sentry-bridge
   npx wrangler secret put SENTRY_CLIENT_SECRET
   # paste the Client Secret when prompted
   ```

   Or set it as a GitHub Actions repo secret named `SENTRY_CLIENT_SECRET` and
   let CI push it (see `.github/workflows/deploy-worker.yml`).

## Secrets

| Secret | Purpose |
| --- | --- |
| `SENTRY_CLIENT_SECRET` | HMAC key for verifying `Sentry-Hook-Signature`. From the Internal Integration. |
| `GITHUB_TOKEN` | PAT with Issues:write on every repo in `PROJECT_REPO_MAP`. Can reuse the same PAT value as the feedback worker's `FEEDBACK_TOKEN` if its scopes cover every repo listed. |

Set them via CI (repo secrets of the same name — the deploy workflow pushes
them into the Worker) or manually:

```
npx wrangler secret put SENTRY_CLIENT_SECRET
npx wrangler secret put GITHUB_TOKEN
```

## Project → repo map

Edit `PROJECT_REPO_MAP` in `src/index.ts` to add a new app. Unknown Sentry
project slugs are ignored with a `200 {status:"ignored"}` so Sentry does not
retry forever.

Current map:

- `un-reminder` → `alexsiri7/un-reminder`
- `cosmic-match` → `alexsiri7/cosmic-match`
- `word-coach-annie` → `alexsiri7/word-coach-annie`
- `filmduel` → `alexsiri7/filmduel`
- `reli` → `alexsiri7/Reli`
- `interstellarai.net` → `alexsiri7/interstellarai.net`

## Endpoint

- `POST https://sentry-bridge.alexsiri7.workers.dev/sentry`
  - `Sentry-Hook-Signature: <hex hmac-sha256 of body>` required, else 401.
  - Responds 201 with `{status:"created", issue_number, issue_url}`,
    200 with `{status:"exists", ...}` or `{status:"ignored", ...}`,
    401 on signature mismatch, 502 on GitHub failure.
- `GET /` is a liveness endpoint (returns `{service:"sentry-bridge", ok:true}`).

## Smoke test

```
# 401 on unsigned request (sanity check the worker is live and rejecting)
curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST https://sentry-bridge.alexsiri7.workers.dev/sentry -d '{}'
# → 401

# Liveness
curl -s https://sentry-bridge.alexsiri7.workers.dev/
# → {"service":"sentry-bridge","ok":true}
```

## Deploy

CI: push to `main` with changes under `workers/sentry-bridge/**` triggers the
`Deploy sentry-bridge worker` workflow. Repo secrets required:

- `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` (already set)
- `SENTRY_CLIENT_SECRET` (from the Sentry Internal Integration)
- `SENTRY_BRIDGE_GITHUB_TOKEN` — PAT with Issues:write on every repo in the map.
  Named with the `SENTRY_BRIDGE_` prefix because GitHub Actions reserves the
  plain `GITHUB_TOKEN` secret name for the auto-provisioned per-workflow token.
  CI pushes it into the Worker as the `GITHUB_TOKEN` binding. Reuse the same
  PAT value as the feedback worker's `FEEDBACK_TOKEN` if its scopes cover the
  mapped repos.

Manual: `cd workers/sentry-bridge && npx wrangler deploy`.
