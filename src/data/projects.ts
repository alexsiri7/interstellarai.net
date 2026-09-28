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
  /** The running project. Omitted for projects with no public URL. */
  url?: string;
  /** Public source repo, when there is one. */
  repo?: string;
  /** Paragraphs for the project's own page at /projects/<id>. */
  about: string[];
  /** Short bullet list for the project's own page. */
  highlights: string[];
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
    url: "https://filmduel.interstellarai.net",
    blurb: "Rank movies and TV via ELO duels.",
    desc: "Movie and TV ranking via ELO duels. FastAPI + React, PostgreSQL/Supabase.",
    stackShort: "FastAPI · React",
    stack: "FastAPI · React · Postgres",
    repo: "https://github.com/alexsiri7/filmduel",
    about: [
      "Two films appear side by side; you pick the one you would rather watch. Each pick moves both titles on an ELO scale, so a personal ranking emerges from a few dozen quick decisions instead of a blank-page list.",
      "Movies and TV share one ladder, so you can finally settle whether that sitcom beats that thriller.",
    ],
    highlights: [
      "ELO-based head-to-head ranking",
      "Movies and TV in one list",
      "FastAPI backend, React frontend",
      "Postgres on the consolidated Supabase project",
    ],
    status: "live",
    shape: "web",
  },
  {
    id: "kindred",
    namePre: "Kindred",
    nameEm: "",
    namePost: "",
    url: "https://kindred.interstellarai.net",
    blurb: "Reflective journaling through your AI assistant.",
    desc: "An MCP server + web app for reflective journaling. You talk to your AI assistant; Kindred provides the memory, structure, and patterns. No streaks, no nudges — just a quiet companion that remembers.",
    stackShort: "TypeScript · MCP · React · Supabase",
    stack: "TypeScript · MCP · React · Supabase · Railway",
    repo: "https://github.com/alexsiri7/kindred",
    about: [
      "Kindred is reflective journaling that happens inside the AI assistant you already use. You talk; Kindred, exposed as an MCP server, keeps the entries, structure and recurring patterns, and a small web app lets you browse them.",
      "There are no streaks and no nudges. It is a quiet companion that remembers.",
    ],
    highlights: [
      "MCP server: save, search and update entries",
      "Pattern tracking across entries",
      "Web app for browsing your journal",
      "Supabase auth and storage",
    ],
    status: "live",
    shape: "web",
  },
  {
    id: "reli",
    namePre: "Reli",
    nameEm: "",
    namePost: "",
    url: "https://reli.interstellarai.net",
    blurb: "Personal AI assistant with a knowledge graph.",
    desc: "Personal AI assistant with a knowledge graph. Python/FastAPI + React, Postgres with pgvector.",
    stackShort: "FastAPI · React",
    stack: "FastAPI · React · pgvector",
    repo: "https://github.com/alexsiri7/reli",
    about: [
      "Reli is a personal assistant built on a knowledge graph. Tasks, notes, projects and ideas are Things, connected by typed relationships, so the assistant can answer from what it knows about you rather than starting cold each time.",
    ],
    highlights: [
      "Knowledge graph of Things and typed relationships",
      "pgvector for semantic recall",
      "FastAPI backend, React frontend",
      "MCP interface for AI assistants",
    ],
    status: "wip",
    shape: "web",
  },
  {
    id: "annie",
    namePre: "",
    nameEm: "Word Coach",
    namePost: " Annie",
    url: "https://annie.interstellarai.net",
    blurb: "AI writing assistant for novelists.",
    desc: "AI writing assistant for novelists. Next.js 15, PostgreSQL/Supabase, Prisma, with an MCP server exposing 48 tools.",
    stackShort: "Next.js · Supabase",
    stack: "Next.js · Supabase · Prisma",
    repo: "https://github.com/alexsiri7/word-coach-annie",
    about: [
      "Word Coach Annie is a writing assistant for novelists. It holds the manuscript, the story bible and the outline, and coaches from that context instead of generic advice.",
      "An MCP server exposes 48 tools so an AI assistant can read scenes, check consistency and manage plot threads directly.",
    ],
    highlights: [
      "Manuscript, outline and story-bible management",
      "Consistency and voice checks",
      "MCP server with 48 tools",
      "Next.js 15, Prisma, Supabase",
    ],
    status: "wip",
    shape: "web",
  },
  {
    id: "lachesis",
    namePre: "Lachesis",
    nameEm: "",
    namePost: "",
    url: "https://lachesis.interstellarai.net",
    blurb: "Hosted MCP server for lightweight requirements management.",
    desc: "Hosted MCP server for lightweight requirements management, scoped per GitHub repository. Requirements are stored as Markdown in each repo and linked to GitHub Issues. Python/FastMCP, MCP OAuth 2.1.",
    stackShort: "Python · FastMCP · MCP",
    stack: "Python · FastMCP · Supabase · Railway",
    about: [
      "Lachesis is a hosted MCP server for lightweight requirements management. Requirements live as Markdown files in each repository and are linked to GitHub Issues, so the spec stays next to the code it describes.",
      "It is scoped per GitHub repository and authenticates with MCP OAuth 2.1.",
    ],
    highlights: [
      "Requirements stored as Markdown in your repo",
      "Linked to GitHub Issues",
      "Per-repository scoping",
      "Python and FastMCP, hosted on Railway",
    ],
    status: "live",
    shape: "web",
  },
  {
    id: "musenmingle",
    namePre: "",
    nameEm: "Muse",
    namePost: " & Mingle",
    url: "https://musenmingle.interstellarai.net",
    repo: "https://github.com/alexsiri7/musenmingle",
    blurb: "London cultural events for creative people.",
    desc: "London cultural events for creative people: exhibitions, expos, talks, workshops and community meetups, gathered from APIs and hand-written scrapers into one feed. Rust (axum, sqlx), Postgres.",
    stackShort: "Rust · axum · Postgres",
    stack: "Rust · axum · sqlx · Postgres · Railway",
    about: [
      "Muse & Mingle collects London's exhibitions, expos, talks, workshops and community events (CreativeMornings, writing groups and the like) into one place for creative people. It was called Thaleia until September 2026.",
      "An ingestion job runs every 15 minutes across a growing set of sources: the Ticketmaster API plus scrapers for galleries and museums. Events are normalised and de-duplicated, then served through a read API and a small server-rendered web page. A health checker files a GitHub issue when a scraper breaks, and visitors can suggest a site that is missing.",
    ],
    highlights: [
      "Ingestion every 15 minutes from APIs and per-site scrapers",
      "Normalisation and de-duplication across sources",
      "Read API plus a server-rendered web page with saved events",
      "Self-reporting: broken scrapers and site suggestions become GitHub issues",
      "Rust: axum, tokio, sqlx, reqwest, maud",
    ],
    status: "live",
    shape: "web",
  },
  {
    id: "zoomies",
    namePre: "",
    nameEm: "Zoomies",
    namePost: "",
    url: "https://zoomies.interstellarai.net",
    repo: "https://github.com/alexsiri7/zoomies",
    blurb: "A 3D endless runner starring a cat with the 3am zoomies.",
    desc: "A 3D endless runner for your phone. It is 3am and a ginger and white cat has the zoomies: run the hallway, garden and rooftops, eat kibble, dodge furniture. Three.js, no build step.",
    stackShort: "Three.js · Web Audio",
    stack: "Three.js · Web Audio · Caddy · Railway",
    about: [
      "It is 3am and a ginger and white cat has the zoomies. Run through the hallway, the garden and the rooftops at night, eating kibble and dodging whatever is in the way. You have nine lives.",
      "Swipe left or right to change lanes, and swipe up or tap to jump. On a keyboard, use the arrow keys or A, D, W and Space. Tall things such as bookcases, bushes and chimneys must be dodged; low things such as footstools, hedgehogs and pigeons can be jumped. Each of the three levels is faster than the last.",
    ],
    highlights: [
      "Three lanes, three levels, nine lives",
      "Touch swipes on phones, keyboard on desktop",
      "All music and sound effects synthesised live with the Web Audio API",
      "A static page with no build step and no asset files",
    ],
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
    repo: "https://github.com/alexsiri7/cosmic-match",
    about: [
      "A space-themed match-3 puzzle game for Android, built with Flutter and the Flame engine.",
    ],
    highlights: [
      "Match-3 gameplay with a space theme",
      "Flutter and Flame",
      "Android",
    ],
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
    repo: "https://github.com/alexsiri7/un-reminder",
    about: [
      "A fixed-time reminder gets ignored within a week. The Un-Reminder replaces \"do X at 7pm\" with habit prompts that arrive at random moments inside windows you choose, only for habits you can do where you are, each worded differently so your brain cannot filter it out.",
      "Prompts are generated ahead of time through a private Cloudflare Worker that proxies to Requesty.ai, so no third-party account is needed. It is a single-user, single-device app: no sign-in, no streaks, no dashboards.",
    ],
    highlights: [
      "Stochastic trigger times via WorkManager",
      "Location-aware, using geofencing",
      "Every notification worded differently",
      "Home-screen widget with a \"did it\" action",
      "Kotlin, Jetpack Compose and Room",
    ],
    status: "wip",
    shape: "mobile",
  },
];

/** Internal page for a project. Every project has one; the live URL and the
 *  repo are linked from there, never straight from a card or list row. */
export const projectHref = (p: Project) => `/projects/${p.id}`;

/** Deploy-shape groups rendered on /projects, in display order. */
export const shapeGroups: { shape: Project["shape"]; title: string; meta: string }[] = [
  { shape: "web", title: "Web backends", meta: "Railway · managed Postgres" },
  { shape: "mobile", title: "Mobile", meta: "Android · store artifacts" },
];
