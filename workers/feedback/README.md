# feedback worker

Cloudflare Worker that accepts feedback submissions from mobile apps and files
them as GitHub issues on the allowlisted repos, optionally with a screenshot.

## Why

Mobile apps cannot safely hold a GitHub PAT (it's extractable from the signed
APK). This worker holds the PAT server-side; clients only know the worker URL.

## API

```
POST https://<worker>.workers.dev/
Content-Type: application/json

{
  "repo": "alexsiri7/un-reminder",      // must be in allowlist
  "type": "bug" | "feature" | "other",
  "message": "...",                      // required, ≤10k chars
  "screenshot": "<base64 or data URL>",  // optional, ≤2MB decoded
  "context": {
    "appVersion": "1.2.3",
    "os": "Android 16",
    "device": "Pixel 8 Pro"
  }
}
```

Response on success: `201 { success: true, issueUrl, issueNumber }`.
Errors: `400` invalid body, `403` repo not allowlisted, `502` GitHub API
failure, `503` worker missing secret.

## Allowlist

Edit `ALLOWED_REPOS` in `src/index.ts` to add a new repo. Redeploy.

## Deploy

CI: push to `main` with changes under `workers/feedback/**` triggers the
`Deploy feedback worker` workflow. Repo secrets required:

- `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` (already set)
- `GITHUB_FEEDBACK_TOKEN` — fine-grained PAT with Issues:write on every
  repo in the allowlist

Manual: `cd workers/feedback && npx wrangler deploy` (after
`wrangler secret put GITHUB_FEEDBACK_TOKEN`).
