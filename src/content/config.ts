import { defineCollection, z } from "astro:content";

const decisions = defineCollection({
  type: "content",
  schema: z.object({
    title: z.string(),
    number: z.number(),
    status: z.enum(["proposed", "accepted", "superseded", "deprecated"]),
    date: z.string(),
    projects: z.array(z.string()).optional(),
    supersedes: z.number().optional(),
  }),
});

const projects = defineCollection({
  type: "content",
  schema: z.object({
    name: z.string(),
    tagline: z.string(),
    repo: z.string(),
    url: z.string().optional(),
    stack: z.array(z.string()),
    deploy: z.string(),
  }),
});

export const collections = { decisions, projects };
