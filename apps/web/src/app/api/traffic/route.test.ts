import { createHash } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ createClient: vi.fn(), getServerEnv: vi.fn() }));
vi.mock("@supabase/supabase-js", () => ({ createClient: mocks.createClient }));
vi.mock("@/lib/env", () => ({ getServerEnv: mocks.getServerEnv }));
import { POST } from "./route";

function request(headers: Record<string, string>): Request {
  return new Request("https://roamorrow.com/api/traffic", {
    method: "POST",
    headers: { "Content-Type": "application/json", "User-Agent": "synthetic-agent", ...headers },
    body: JSON.stringify({ experienceId: "synthetic-experience", lng: 98.98, lat: 18.78 }),
  });
}

describe("traffic attribution behind the local Cloudflare ingress", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.stubEnv("ROAMORROW_WEB_INGRESS", "cloudflare-tunnel");
    mocks.getServerEnv.mockReturnValue({
      SUPABASE_URL: "https://synthetic.supabase.co",
      SUPABASE_SERVICE_ROLE_KEY: "synthetic-server-key",
    });
  });
  afterEach(() => vi.unstubAllEnvs());

  it("acknowledges without constructing a DB client when a trusted address is missing", async () => {
    const response = await POST(request({ "x-forwarded-for": "192.0.2.99" }));
    expect(await response.json()).toEqual({ ok: true });
    expect(mocks.getServerEnv).not.toHaveBeenCalled();
    expect(mocks.createClient).not.toHaveBeenCalled();
  });

  it("does not write for an unknown ingress or malformed CF address", async () => {
    vi.stubEnv("ROAMORROW_WEB_INGRESS", "unknown");
    await POST(request({ "cf-connecting-ip": "203.0.113.21" }));
    vi.stubEnv("ROAMORROW_WEB_INGRESS", "cloudflare-tunnel");
    await POST(request({ "cf-connecting-ip": "999.999.999.999" }));
    expect(mocks.createClient).not.toHaveBeenCalled();
  });

  it("uses the trusted CF address for the scoped hash despite forged XFF", async () => {
    const upsert = vi.fn().mockResolvedValue({ error: null });
    mocks.createClient.mockReturnValue({
      from: (table: string) =>
        table === "traffic_pings"
          ? { upsert }
          : {
              select: () => ({
                eq: () => ({ maybeSingle: async () => ({ data: null, error: null }) }),
              }),
            },
    });
    await POST(request({ "cf-connecting-ip": "203.0.113.21", "x-forwarded-for": "192.0.2.99" }));
    expect(upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        experience_id: "synthetic-experience",
        anon_id: createHash("sha256")
          .update("203.0.113.21:synthetic-agent:synthetic-experience")
          .digest("hex"),
      }),
      { onConflict: "experience_id,anon_id" },
    );
  });
});
