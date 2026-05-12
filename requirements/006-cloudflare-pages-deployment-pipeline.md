---
id: "006"
title: "Cloudflare Pages deployment pipeline"
status: "done"
github_issue: 3
updated: "2026-05-12"
---

## Why

The site must be publicly accessible at `www.interstellarai.net` with automatic deploys on every push to `main` and preview URLs for pull requests.

## What

GitHub Actions workflow using `cloudflare/wrangler-action` to run `wrangler pages deploy dist` against the `interstellarai-net` Pages project. `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` in repo secrets. Custom domain attached in Cloudflare Pages dashboard.
