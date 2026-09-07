/**
 * Single source of truth for the portfolio.
 *
 * Both the homepage grid and /projects render from this array, and the
 * homepage hero counter uses `projects.length` — so adding a project here
 * updates the cards and the count together and the numbers cannot go stale.
 *
 * `name` is split into three parts so the display-serif italic emphasis
 * (e.g. *Film*Duel) survives without dropping raw HTML into the templates.
 */
export interface Project {
  /** Stable id, used as the render key. */
  id: string;
  /** Plain text before the emphasised span. */
  namePre: string;
  /** The italic/emphasised part of the name. */
  nameEm: string;
  /** Plain text after the emphasised span. */
  namePost: string;
  /** Outbound link. Omitted for projects with no public URL yet. */
  href?: string;
  /** One-line copy for the homepage card. */
  blurb: string;
  /** Fuller copy for the /projects list. */
  desc: string;
  /** Compact stack label for the homepage card footer. */
  stackShort: string;
  /** Fuller stack label for the /projects list. */
  stack: string;
  status: "live" | "wip";
  /** Deploy shape, per ADR-003. Drives the grouping on /projects. */
  shape: "web" | "mobile";
}

export const projects: Project[] = [
  {
    id: "filmduel",
    namePre: "",
    nameEm: "Film",
    namePost: "Duel",
    href: "https://filmduel.interstellarai.net",
    blurb: "Rank movies and TV via ELO duels.",
    desc: "Movie and TV ranking via ELO duels. FastAPI + React, PostgreSQL/Supabase.",
    stackShort: "FastAPI · React",
    stack: "FastAPI · React · Postgres",
    status: "live",
    shape: "web",
  },
  {
    id: "kindred",
    namePre: "Kindred",
    nameEm: "",
    namePost: "",
    href: "https://kindred.interstellarai.net",
    blurb: "Reflective journaling through your AI assistant.",
    desc: "An MCP server + web app for reflective journaling. You talk to your AI assistant; Kindred provides the memory, structure, and patterns. No streaks, no nudges — just a quiet companion that remembers.",
    stackShort: "TypeScript · MCP · React · Supabase",
    stack: "TypeScript · MCP · React · Supabase · Railway",
    status: "live",
    shape: "web",
  },
  {
    id: "reli",
    namePre: "Reli",
    nameEm: "",
    namePost: "",
    href: "https://reli.interstellarai.net",
    blurb: "Personal AI assistant with a knowledge graph.",
    desc: "Personal AI assistant with a knowledge graph. Python/FastAPI + React, Postgres with pgvector.",
    stackShort: "FastAPI · React",
    stack: "FastAPI · React · pgvector",
    status: "wip",
    shape: "web",
  },
  {
    id: "annie",
    namePre: "",
    nameEm: "Word Coach",
    namePost: " Annie",
    href: "https://annie.interstellarai.net",
    blurb: "AI writing assistant for novelists.",
    desc: "AI writing assistant for novelists. Next.js 15, PostgreSQL/Supabase, Prisma, with an MCP server exposing 48 tools.",
    stackShort: "Next.js · Supabase",
    stack: "Next.js · Supabase · Prisma",
    status: "wip",
    shape: "web",
  },
  {
    id: "lachesis",
    namePre: "Lachesis",
    nameEm: "",
    namePost: "",
    href: "https://lachesis.interstellarai.net",
    blurb: "Hosted MCP server for lightweight requirements management.",
    desc: "Hosted MCP server for lightweight requirements management, scoped per GitHub repository. Requirements are stored as Markdown in each repo and linked to GitHub Issues. Python/FastMCP, MCP OAuth 2.1.",
    stackShort: "Python · FastMCP · MCP",
    stack: "Python · FastMCP · Supabase · Railway",
    status: "live",
    shape: "web",
  },
  {
    id: "cosmic-match",
    namePre: "",
    nameEm: "Cosmic",
    namePost: " Match",
    blurb: "Space-themed match-3 mobile game.",
    desc: "Space-themed match-3 mobile game. Flutter + Flame, Android.",
    stackShort: "Flutter · Flame",
    stack: "Flutter · Flame",
    status: "wip",
    shape: "mobile",
  },
  {
    id: "un-reminder",
    namePre: "The ",
    nameEm: "Un-Reminder",
    namePost: "",
    blurb: "Stochastic, context-aware habit prompts.",
    desc: "Stochastic, context-aware habit prompts designed to defeat notification blindness. Native Android; notifications are generated through a private Cloudflare Worker proxy to Requesty.ai, so no third-party account is required.",
    stackShort: "Android · Cloudflare Worker",
    stack: "Android · Kotlin · Cloudflare Worker",
    status: "wip",
    shape: "mobile",
  },
];

/** Deploy-shape groups rendered on /projects, in display order. */
export const shapeGroups: { shape: Project["shape"]; title: string; meta: string }[] = [
  { shape: "web", title: "Web backends", meta: "Railway · managed Postgres" },
  { shape: "mobile", title: "Mobile", meta: "Android · store artifacts" },
];
