---
id: "008"
title: "Sentry bridge Cloudflare Worker"
status: "done"
github_issue: 7
updated: "2026-05-12"
---

## Why

Some client-side projects need a Sentry proxy to avoid CORS issues or to strip PII before forwarding errors.

## What

Cloudflare Worker at `workers/sentry-bridge/` acting as a proxy between client apps and the Sentry ingestion endpoint.
