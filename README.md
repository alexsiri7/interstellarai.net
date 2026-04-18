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
- Deploy: **Cloudflare Pages** in direct-upload mode via
  `.github/workflows/deploy.yml`. Every push to `main` builds and deploys.
  Pull requests get preview URLs on the Cloudflare dashboard.

## Local development

```bash
npm install
npm run dev
```

Build check:

```bash
npm run build && npm run preview
```

## Deploy

The workflow uses `cloudflare/wrangler-action` to `wrangler pages deploy dist`
against the `interstellarai-net` Pages project. Required repo secrets:

- `CLOUDFLARE_API_TOKEN` — scoped to Pages:Edit on the target account
- `CLOUDFLARE_ACCOUNT_ID`

Custom domain `www.interstellarai.net` is attached to the Pages project and
resolves via Cloudflare's automatic DNS.

### Optional apex redirect

Add a Cloudflare redirect rule or page rule sending
`interstellarai.net/*` → `https://www.interstellarai.net/$1`.

## Writing a new ADR

1. Pick the next `number` (check `src/content/decisions/` — current max + 1).
2. Copy an existing ADR as a template.
3. Fill in frontmatter (`title`, `number`, `status`, `date`, `projects`).
4. Write Context / Decision / Consequences / Alternatives-considered.
5. Open a PR. Merging publishes it to `/decisions/<slug>`.

## Writing a new tenet

Edit `src/pages/tenets.astro` directly. Keep them short — each tenet is one
paragraph. If it needs more, it's a decision record, not a tenet.
