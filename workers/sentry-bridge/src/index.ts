// Sentry → GitHub issue bridge.
//
// Sentry's built-in GitHub integration is paid-plan-only. This worker is a
// free-tier substitute: a Sentry Internal Integration posts webhooks here on
// issue.created, we verify the HMAC signature, map the Sentry project slug
// to a GitHub repo in the user's allowlist, and file a bug-labelled issue
// with an archon:queued label so the archon pipeline picks it up.
//
// See workers/sentry-bridge/README.md for the one-time Sentry click-path.
//
// Do not add retry/queue logic — Sentry retries on non-2xx for 24 hours.
//
// Idempotency: we search for an existing issue containing the marker line
// "Sentry issue ID: <id>" in its body before creating a new one. The marker
// is in the body (not title) so the user can edit titles freely.
//
// Secrets (see wrangler.toml):
//   SENTRY_CLIENT_SECRET — HMAC-SHA256 key for signature verification.
//   GITHUB_TOKEN         — PAT with Issues:write on the mapped repos.

interface Env {
  SENTRY_CLIENT_SECRET: string;
  GITHUB_TOKEN: string;
}

// Sentry project slug → GitHub "owner/repo".
// Edit this and redeploy to add a new app.
const PROJECT_REPO_MAP: Record<string, string> = {
  "un-reminder": "alexsiri7/un-reminder",
  "cosmic-match": "alexsiri7/cosmic-match",
  "word-coach-annie": "alexsiri7/word-coach-annie",
  filmduel: "alexsiri7/filmduel",
  reli: "alexsiri7/Reli",
  "interstellarai.net": "alexsiri7/interstellarai.net",
};

const ISSUE_LABELS = ["bug", "sentry", "archon:queued"];
const SENTRY_LABEL_NAME = "sentry";
const SENTRY_LABEL_COLOR = "362d59"; // Sentry brand purple.
const SENTRY_LABEL_DESC = "Auto-filed from a Sentry event via sentry-bridge.";

const MAX_TITLE_CHARS = 150;
const USER_AGENT = "sentry-bridge-worker";

interface SentryIssuePayload {
  action?: string;
  data?: {
    issue?: {
      id?: string | number;
      title?: string;
      permalink?: string;
      culprit?: string;
      project?: { slug?: string };
      metadata?: { value?: string; filename?: string; function?: string };
    };
  };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function hexToBytes(hex: string): Uint8Array | null {
  const clean = hex.trim().toLowerCase();
  if (!/^[0-9a-f]*$/.test(clean) || clean.length % 2 !== 0) return null;
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(clean.substr(i * 2, 2), 16);
  }
  return out;
}

function bytesToHex(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i++) {
    s += bytes[i].toString(16).padStart(2, "0");
  }
  return s;
}

function constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

async function verifySignature(
  secret: string,
  bodyBytes: ArrayBuffer,
  signatureHex: string,
): Promise<boolean> {
  const expected = hexToBytes(signatureHex);
  if (!expected) return false;

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, bodyBytes));
  return constantTimeEqual(sig, expected);
}

function ghHeaders(token: string): Record<string, string> {
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "User-Agent": USER_AGENT,
    "X-GitHub-Api-Version": "2022-11-28",
  };
}

async function findExistingIssue(
  token: string,
  repo: string,
  sentryIssueId: string,
): Promise<{ number: number; html_url: string } | null> {
  // Search by the exact marker line we write into the body. Using quotes
  // forces GitHub's search to look for the phrase, and in:body scopes it.
  const q = `repo:${repo} in:body "Sentry issue ID: ${sentryIssueId}"`;
  const url = `https://api.github.com/search/issues?q=${encodeURIComponent(q)}`;
  const res = await fetch(url, { headers: ghHeaders(token) });
  if (!res.ok) return null;
  const data = (await res.json()) as {
    items?: Array<{ number: number; html_url: string }>;
  };
  if (data.items && data.items.length > 0) return data.items[0];
  return null;
}

async function ensureSentryLabel(token: string, repo: string): Promise<void> {
  const getRes = await fetch(
    `https://api.github.com/repos/${repo}/labels/${SENTRY_LABEL_NAME}`,
    { headers: ghHeaders(token) },
  );
  if (getRes.ok) return;
  if (getRes.status !== 404) return; // Some other error; let issue-create proceed.
  // Create it. Ignore errors — we'll still try the issue POST either way.
  await fetch(`https://api.github.com/repos/${repo}/labels`, {
    method: "POST",
    headers: { ...ghHeaders(token), "Content-Type": "application/json" },
    body: JSON.stringify({
      name: SENTRY_LABEL_NAME,
      color: SENTRY_LABEL_COLOR,
      description: SENTRY_LABEL_DESC,
    }),
  }).catch(() => {});
}

function buildIssueBody(issue: NonNullable<SentryIssuePayload["data"]>["issue"]): string {
  const lines: string[] = [];
  lines.push(`Automatically created from Sentry — do not edit the title (used for dedup).`);
  lines.push("");
  if (issue?.permalink) lines.push(`**Sentry link:** ${issue.permalink}`);
  if (issue?.id !== undefined) lines.push(`**Sentry issue ID:** ${issue.id}`);
  if (issue?.project?.slug) lines.push(`**Project:** ${issue.project.slug}`);
  if (issue?.culprit) lines.push(`**Culprit:** \`${issue.culprit}\``);
  const meta = issue?.metadata;
  if (meta?.value) {
    lines.push("");
    lines.push("### Error");
    lines.push("```");
    lines.push(meta.value);
    lines.push("```");
  }
  if (meta?.filename || meta?.function) {
    const where = [meta.function, meta.filename].filter(Boolean).join(" @ ");
    lines.push("");
    lines.push(`**First frame:** \`${where}\``);
  }
  return lines.join("\n");
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (req.method === "GET" && url.pathname === "/") {
      // Tiny health endpoint; the real webhook endpoint is POST only.
      return json({ service: "sentry-bridge", ok: true });
    }
    if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
    if (url.pathname !== "/sentry" && url.pathname !== "/") {
      return json({ error: "not found" }, 404);
    }

    if (!env.SENTRY_CLIENT_SECRET || !env.GITHUB_TOKEN) {
      return json({ error: "worker not configured" }, 503);
    }

    const bodyBytes = await req.arrayBuffer();
    const signature = req.headers.get("sentry-hook-signature") || "";
    if (!signature) return json({ error: "missing signature" }, 401);

    const ok = await verifySignature(env.SENTRY_CLIENT_SECRET, bodyBytes, signature);
    if (!ok) return json({ error: "invalid signature" }, 401);

    // Resource type is in this header; we only act on issue.created.
    const resource = req.headers.get("sentry-hook-resource") || "";

    let payload: SentryIssuePayload;
    try {
      payload = JSON.parse(new TextDecoder().decode(bodyBytes)) as SentryIssuePayload;
    } catch {
      return json({ error: "invalid JSON" }, 400);
    }

    if (resource && resource !== "issue") {
      return json({ status: "ignored", reason: `resource:${resource}` });
    }
    if (payload.action && payload.action !== "created") {
      return json({ status: "ignored", reason: `action:${payload.action}` });
    }

    const sentryIssue = payload.data?.issue;
    if (!sentryIssue?.id) return json({ error: "missing issue payload" }, 400);

    const projectSlug = sentryIssue.project?.slug || "";
    const repo = PROJECT_REPO_MAP[projectSlug];
    if (!repo) {
      return json({ status: "ignored", reason: "unknown-project", project: projectSlug });
    }

    const sentryIssueId = String(sentryIssue.id);

    // Idempotency check.
    const existing = await findExistingIssue(env.GITHUB_TOKEN, repo, sentryIssueId);
    if (existing) {
      return json({ status: "exists", issue_number: existing.number, issue_url: existing.html_url });
    }

    // Make sure the "sentry" label exists (best effort).
    await ensureSentryLabel(env.GITHUB_TOKEN, repo);

    const rawTitle = sentryIssue.title?.trim() || "Sentry error";
    const title = `[Sentry] ${rawTitle}`.slice(0, MAX_TITLE_CHARS);
    const body = buildIssueBody(sentryIssue);

    // First attempt with all labels. If 422 (label doesn't exist and ensure
    // step failed), fall back to archon:queued + bug only.
    const baseInit = {
      method: "POST",
      headers: { ...ghHeaders(env.GITHUB_TOKEN), "Content-Type": "application/json" },
    };
    let issueRes = await fetch(`https://api.github.com/repos/${repo}/issues`, {
      ...baseInit,
      body: JSON.stringify({ title, body, labels: ISSUE_LABELS }),
    });
    if (issueRes.status === 422) {
      issueRes = await fetch(`https://api.github.com/repos/${repo}/issues`, {
        ...baseInit,
        body: JSON.stringify({
          title,
          body,
          labels: ISSUE_LABELS.filter((l) => l !== SENTRY_LABEL_NAME),
        }),
      });
    }

    if (!issueRes.ok) {
      const text = await issueRes.text().catch(() => "");
      return json({ error: "failed to create issue", github_status: issueRes.status, detail: text.slice(0, 500) }, 502);
    }

    const issue = (await issueRes.json()) as { html_url: string; number: number };
    return json({ status: "created", issue_number: issue.number, issue_url: issue.html_url }, 201);
  },
};
