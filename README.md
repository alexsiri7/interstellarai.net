# interstellarai.net

The public site at **www.interstellarai.net** plus the engineering handbook for
the InterStellar AI project portfolio.

## What lives here

- **Marketing pages** (`src/pages/`) — what visitors see at the apex domain
- **Tenets** (`src/pages/tenets.astro`) — the non-negotiable principles
- **Decision log** (`src/content/decisions/`) — ADRs for cross-project decisions
- **Project index** (`src/pages/projects.astro`) — catalog with deploy targets

Per-project apps live under subdomains (e.g. `filmduel.interstellarai.net`),
deployed from their own repos — not from here.

## Stack

- [Astro 5](https://astro.build) static site generator
- TypeScript + content collections for type-safe Markdown
- Deploy: GitHub Actions → GitHub Pages (configured in
  `.github/workflows/deploy.yml`)

## Local development

```bash
npm install
npm run dev
```

Build check:

```bash
npm run build && npm run preview
```

## Deploy setup — human steps still needed

1. **GitHub Pages**: In repo Settings → Pages → Source: **GitHub Actions**.
   The `deploy.yml` workflow handles the rest on push to `main`.
2. **Custom domain**: Settings → Pages → Custom domain: `www.interstellarai.net`.
   Add the `CNAME` and DNS records per GitHub's docs. Cloudflare-side DNS entries
   need to point at `alexsiri7.github.io`.
3. **HTTPS**: enforce HTTPS in Pages settings after the cert provisions.

Once set up, every push to `main` deploys. No manual steps.

## Writing a new ADR

1. Pick the next `number` (check `src/content/decisions/` — current max + 1).
2. Copy an existing ADR as a template.
3. Fill in frontmatter (`title`, `number`, `status`, `date`, `projects`).
4. Write Context / Decision / Consequences / Alternatives-considered.
5. Open a PR. Merging publishes it to `/decisions/<slug>`.

## Writing a new tenet

Edit `src/pages/tenets.astro` directly. Keep them short — each tenet is one
paragraph. If it needs more, it's a decision record, not a tenet.
