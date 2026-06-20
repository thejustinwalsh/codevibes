import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";
export default defineWorkersConfig({
  css: { postcss: { plugins: [] } },
  test: {
    poolOptions: {
      workers: {
        wrangler: { configPath: "./wrangler.toml" },
        // Test-only stub bindings live HERE, not in wrangler.toml, so the deploy
        // config never carries secret-shaped fields (no leak surface, no prod
        // collision with the Secrets Store bindings).
        miniflare: {
          bindings: {
            JWT_SECRET: "test-jwt-secret",
            ENCRYPTION_KEY: "test-encryption-key-32chars123456",
            GITHUB_CLIENT_ID: "test-github-client-id",
            GITHUB_CLIENT_SECRET: "test-github-client-secret",
            TUNNEL_CRED: '{"TunnelID":"test-tunnel"}',
          },
        },
      },
    },
  },
});
