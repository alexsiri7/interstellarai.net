---
id: "007"
title: "Feedback Cloudflare Worker"
status: "done"
github_issue: 4
updated: "2026-05-12"
---

## Why

In-app feedback from mobile/web projects (Cosmic Match, Un-Reminder) needs a secure intermediary to receive annotated screenshots and create GitHub issues without exposing a GitHub PAT in the client.

## What

Cloudflare Worker at `feedback.alexsiri7.workers.dev` (in `workers/feedback/`). Receives feedback payloads (description + optional screenshot), creates GitHub issues via GitHub API. Auth via shared secret header.
