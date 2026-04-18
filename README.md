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
- Deploy: **Cloudflare Pages** via Git integration (no workflow in this repo —
  CF builds on push to `main` and publishes preview deploys per PR)

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

1. **Cloudflare Pages project**: Cloudflare dashboard → **Workers & Pages** →
   Create → Pages → **Connect to Git** → pick `alexsiri7/interstellarai.net`.
   - Framework preset: **Astro**
   - Build command: `npm run build`
   - Build output directory: `dist`
   - Root directory: (leave empty)
2. **Custom domain**: in the Pages project → **Custom domains** → add
   `www.interstellarai.net`. Cloudflare auto-creates the CNAME since the zone
   lives in the same account.
3. **Apex redirect** (optional): add a Cloudflare redirect rule or page rule
   sending `interstellarai.net/*` → `https://www.interstellarai.net/$1`.

Once connected, every push to `main` deploys. Pull requests get preview URLs
automatically.

## Writing a new ADR

1. Pick the next `number` (check `src/content/decisions/` — current max + 1).
2. Copy an existing ADR as a template.
3. Fill in frontmatter (`title`, `number`, `status`, `date`, `projects`).
4. Write Context / Decision / Consequences / Alternatives-considered.
5. Open a PR. Merging publishes it to `/decisions/<slug>`.

## Writing a new tenet

Edit `src/pages/tenets.astro` directly. Keep them short — each tenet is one
paragraph. If it needs more, it's a decision record, not a tenet.
