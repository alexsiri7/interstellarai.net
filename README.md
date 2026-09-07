# interstellarai.net

The public site at **www.interstellarai.net** plus the engineering handbook for
the InterStellar AI project portfolio.

## What lives here

- **Marketing pages** (`src/pages/`) — what visitors see at www.interstellarai.net
- **Tenets** (`src/pages/tenets.astro`) — the non-negotiable principles
- **Mementos** (`src/content/mementos/`) — architecture decision records for
  cross-project decisions
- **Project index** (`src/pages/projects.astro`) — catalog with deploy targets,
  rendered from `src/data/projects.ts` (the homepage grid and hero counters
  read the same file, so they cannot drift apart)

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
resolves via Cloudflare's automatic DNS. **`www` is the canonical host** — it is
the value of `site` in `astro.config.mjs` and the origin used for canonical and
Open Graph URLs.

### Apex redirect (not yet configured)

The apex `interstellarai.net` currently has **no DNS record**, so it fails to
resolve. To send it to `www`, in the Cloudflare dashboard for the zone:

1. **DNS** → add a *proxied* record for `@` so the hostname resolves at all —
   either `CNAME @ → <pages-project>.pages.dev` or a placeholder
   `A @ → 192.0.2.1`. The orange-cloud proxy must be on; Cloudflare flattens
   the apex CNAME and terminates TLS.
2. **Rules → Redirect Rules** → create a rule:
   - When: `http.host eq "interstellarai.net"`
   - Then: dynamic redirect to
     `concat("https://www.interstellarai.net", http.request.uri.path)`,
     status **301**, *preserve query string* enabled.

Attaching the apex as a second custom domain on the Pages project is **not**
equivalent — that serves the same site on two hosts (duplicate content) rather
than redirecting one to the other.

## Writing a new memento (ADR)

1. Pick the next `number` (check `src/content/mementos/` — current max + 1).
2. Copy an existing memento as a template.
3. Fill in frontmatter (`title`, `number`, `status`, `date`, and `projects` if the decision spans multiple projects — `projects` is optional and omitted for single-project decisions).
4. Write Context / Decision / Consequences / Alternatives-considered.
5. Open a PR. Merging publishes it to `/mementos/<slug>`.

## Writing a new tenet

Edit `src/pages/tenets.astro` directly. Keep them short — each tenet is one
paragraph. If it needs more, it's a decision record, not a tenet.
