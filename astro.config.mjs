import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";

export default defineConfig({
  site: "https://www.interstellarai.net",
  trailingSlash: "ignore",
  integrations: [
    sitemap({
      // 404 is a real page in the build output but must never be indexed.
      filter: (page) => !page.endsWith("/404"),
    }),
  ],
});
