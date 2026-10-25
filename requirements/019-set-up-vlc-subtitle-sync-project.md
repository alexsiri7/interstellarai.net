---
created: '2026-10-11'
github_issue: 190
id: '019'
status: done
title: Set up vlc-subtitle-sync project
updated: '2026-10-25'
---

## Why

Alex wants speech-snap subtitle sync in VLC for Android/Android TV (for Stremio's external-player hand-off), contributed back to VideoLAN. Creating the project via Lachesis failed: GitHub returned 403 on repo creation with Lachesis's token.

## What

A private GitHub repo alexsiri7/vlc-subtitle-sync exists, contains the vlc-android source with VideoLAN upstream tracked so patches can be sent as GitLab merge requests, has openspec/specs/subtitle-sync/spec.md with the agreed spec, and is registered with Lachesis so the factory can pick up its work.

## Issues

- #190 — Create and register the vlc-subtitle-sync project