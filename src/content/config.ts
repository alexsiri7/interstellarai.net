import { defineCollection, z } from "astro:content";

const mementos = defineCollection({
  type: "content",
  schema: z.object({
    title: z.string(),
    number: z.number(),
    status: z.enum(["proposed", "accepted", "superseded", "deprecated"]),
    date: z.coerce.date(),
    projects: z.array(z.string()).optional(),
    supersedes: z.number().optional(),
  }),
});

const conventions = defineCollection({
  type: "content",
  schema: z.object({
    title: z.string(),
    order: z.number(),
    summary: z.string(),
    updated: z.coerce.date(),
  }),
});

export const collections = { mementos, conventions };
