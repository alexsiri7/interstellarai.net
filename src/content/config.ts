import { defineCollection, z } from "astro:content";

const decisions = defineCollection({
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

export const collections = { decisions };
