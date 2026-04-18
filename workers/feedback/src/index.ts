// Feedback worker — receives feedback submissions from mobile apps and
// creates a GitHub issue with an optional annotated screenshot.
//
// Why this exists: mobile apps cannot hold a GitHub PAT safely (it would be
// extractable from the signed APK). This worker holds the PAT server-side
// and exposes a narrow API: create an issue on one of the allowlisted repos,
// optionally with a screenshot attachment, and nothing else.
//
// Allowlist is baked in — clients cannot submit to arbitrary repos.

interface Env {
  GITHUB_FEEDBACK_TOKEN: string;
}

const ALLOWED_REPOS = new Set<string>([
  "alexsiri7/un-reminder",
  "alexsiri7/cosmic-match",
]);

const LABEL_MAP: Record<string, string> = {
  bug: "bug",
  feature: "enhancement",
  other: "feedback",
};

const MAX_SCREENSHOT_BYTES = 2 * 1024 * 1024;
const MAX_MESSAGE_CHARS = 10_000;

interface FeedbackBody {
  repo: string;
  type: "bug" | "feature" | "other";
  message: string;
  screenshot?: string;
  context?: {
    appVersion?: string;
    device?: string;
    os?: string;
  };
}

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Max-Age": "86400",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS },
  });
}

function escapeMd(s: string): string {
  return s.replace(/[<>`]/g, (c) => `\\${c}`);
}

async function getRepoId(token: string, repo: string): Promise<string> {
  const res = await fetch(`https://api.github.com/repos/${repo}`, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github+json",
      "User-Agent": "feedback-worker",
    },
  });
  if (!res.ok) throw new Error(`repo lookup failed: ${res.status}`);
  const data = (await res.json()) as { id: number };
  return String(data.id);
}

async function uploadScreenshot(
  token: string,
  repo: string,
  dataUrl: string,
): Promise<string | null> {
  const base64 = dataUrl.includes(",") ? dataUrl.split(",")[1] : dataUrl;
  if (!base64) return null;

  const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  if (bytes.length > MAX_SCREENSHOT_BYTES) return null;

  const blob = new Blob([bytes], { type: "image/png" });
  const form = new FormData();
  form.append("file", blob, `feedback-${Date.now()}.png`);
  form.append("repository_id", await getRepoId(token, repo));
  form.append("authenticity_token", token);

  const res = await fetch(
    `https://uploads.github.com/repos/${repo}/issues/uploads`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
        "User-Agent": "feedback-worker",
      },
      body: form,
    },
  );
  if (!res.ok) return null;
  const data = (await res.json()) as {
    href?: string;
    asset?: { href?: string };
  };
  return data.href || data.asset?.href || null;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    if (req.method === "OPTIONS")
      return new Response(null, { headers: CORS });
    if (req.method !== "POST")
      return json({ error: "method not allowed" }, 405);

    let body: FeedbackBody;
    try {
      body = (await req.json()) as FeedbackBody;
    } catch {
      return json({ error: "invalid JSON" }, 400);
    }

    if (!ALLOWED_REPOS.has(body.repo))
      return json({ error: "repo not allowed" }, 403);
    if (!body.type || !(body.type in LABEL_MAP))
      return json({ error: "invalid type" }, 400);
    if (!body.message?.trim())
      return json({ error: "message required" }, 400);
    if (body.message.length > MAX_MESSAGE_CHARS)
      return json({ error: "message too long" }, 400);

    const token = env.GITHUB_FEEDBACK_TOKEN;
    if (!token) return json({ error: "worker not configured" }, 503);

    let screenshotUrl: string | null = null;
    if (body.screenshot) {
      try {
        screenshotUrl = await uploadScreenshot(token, body.repo, body.screenshot);
      } catch {
        screenshotUrl = null;
      }
    }

    const msg = body.message.trim();
    const parts: string[] = [msg];
    if (screenshotUrl) {
      parts.push("", "### Screenshot", `![screenshot](${screenshotUrl})`);
    }
    if (body.context) {
      const ctx: string[] = [];
      if (body.context.appVersion)
        ctx.push(`**App version:** ${escapeMd(body.context.appVersion)}`);
      if (body.context.os) ctx.push(`**OS:** ${escapeMd(body.context.os)}`);
      if (body.context.device)
        ctx.push(`**Device:** ${escapeMd(body.context.device)}`);
      if (ctx.length) parts.push("", "---", "### Context", ...ctx);
    }

    const typePrefix =
      body.type === "bug" ? "Bug: " : body.type === "feature" ? "Feature: " : "";
    const titleSnippet = msg.split("\n")[0].slice(0, 80);
    const title = `${typePrefix}${titleSnippet}`;
    const labels = [LABEL_MAP[body.type]];

    const issueRes = await fetch(
      `https://api.github.com/repos/${body.repo}/issues`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          Accept: "application/vnd.github+json",
          "Content-Type": "application/json",
          "User-Agent": "feedback-worker",
          "X-GitHub-Api-Version": "2022-11-28",
        },
        body: JSON.stringify({ title, body: parts.join("\n"), labels }),
      },
    );

    if (!issueRes.ok) return json({ error: "failed to create issue" }, 502);

    const issue = (await issueRes.json()) as {
      html_url: string;
      number: number;
    };
    return json(
      { success: true, issueUrl: issue.html_url, issueNumber: issue.number },
      201,
    );
  },
};
