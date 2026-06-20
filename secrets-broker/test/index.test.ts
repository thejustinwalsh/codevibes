import { env, createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import worker from "../src/index";

const goodHeaders = { "Cf-Access-Jwt-Assertion": "valid" };

describe("secrets broker", () => {
  it("returns all secrets to an Access-authenticated request", async () => {
    const req = new Request("https://secrets.tjw.dev/secrets", { headers: goodHeaders });
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(200);
    const body = await res.json<Record<string, string>>();
    expect(body.JWT_SECRET).toBeTruthy();
    expect(body.ENCRYPTION_KEY).toBeTruthy();
  });

  it("rejects a request with no Access assertion (401)", async () => {
    const req = new Request("https://secrets.tjw.dev/secrets");
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(401);
  });

  it("404s on any path other than /secrets", async () => {
    const req = new Request("https://secrets.tjw.dev/", { headers: goodHeaders });
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(404);
  });
});
