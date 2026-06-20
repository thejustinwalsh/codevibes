import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";
export default defineWorkersConfig({
  css: { postcss: { plugins: [] } },
  test: { poolOptions: { workers: { wrangler: { configPath: "./wrangler.toml" } } } },
});
