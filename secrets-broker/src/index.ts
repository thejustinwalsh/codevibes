// CodeVibes secrets broker. Sits behind Cloudflare Access (service-token policy).
// Defense in depth: require the Access assertion header; only serves /secrets.

// Production bindings are Secrets Store objects ({ get(): Promise<string> }).
// Test bindings (wrangler.toml [vars]) are plain strings.
// SecretsBinding covers both so the Worker runs hermetically in vitest.
type SecretsBinding = string | { get(): Promise<string> };

export interface Env {
  JWT_SECRET: SecretsBinding;
  ENCRYPTION_KEY: SecretsBinding;
  GITHUB_CLIENT_ID: SecretsBinding;
  GITHUB_CLIENT_SECRET: SecretsBinding;
  TUNNEL_CRED: SecretsBinding;
}

// Resolve a binding to its string value — handles both Secrets Store and plain-var forms.
async function resolve(b: SecretsBinding): Promise<string> {
  return typeof b === "string" ? b : b.get();
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname !== "/secrets") return new Response("not found", { status: 404 });
    // Access injects this header once its policy passes. Absent => not via Access.
    if (!req.headers.get("Cf-Access-Jwt-Assertion")) {
      return new Response("unauthorized", { status: 401 });
    }
    const body = {
      JWT_SECRET: await resolve(env.JWT_SECRET),
      ENCRYPTION_KEY: await resolve(env.ENCRYPTION_KEY),
      GITHUB_CLIENT_ID: await resolve(env.GITHUB_CLIENT_ID),
      GITHUB_CLIENT_SECRET: await resolve(env.GITHUB_CLIENT_SECRET),
      TUNNEL_CRED: await resolve(env.TUNNEL_CRED),
    };
    return Response.json(body, { headers: { "cache-control": "no-store" } });
  },
};
