import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { test } from "node:test";
import { nomadsNetworkHeaders } from "../../apps/web/src/lib/nomads-proxy.ts";
import { trustedClientIp } from "../../apps/web/src/lib/client-ip.ts";

const secret = "synthetic-shared-proxy-key-for-tests";
const time = 1900000000000;

test("Cloudflare ingress signs its client IP and ignores forged Vercel/XFF/proof headers", async () => {
  const headers = await nomadsNetworkHeaders(
    new Headers({
      "cf-connecting-ip": "203.0.113.21",
      "x-forwarded-for": "192.0.2.99",
      "x-vercel-forwarded-for": "192.0.2.98",
      "x-nomads-network-ip": "192.0.2.97",
      "x-nomads-network-time": "0",
      "x-nomads-network-signature": "forged",
    }),
    secret,
    time,
    "cloudflare-tunnel",
  );
  assert.equal(headers.get("x-nomads-network-ip"), "203.0.113.21");
  assert.equal(headers.get("x-nomads-network-time"), String(time));
  assert.equal(
    headers.get("x-nomads-network-signature"),
    createHmac("sha256", secret)
      .update(time + "\n203.0.113.21")
      .digest("hex"),
  );
  assert.ok(![...headers.values()].includes(secret));
});

test("Cloudflare ingress fails closed instead of falling back to client-supplied XFF", async () => {
  for (const value of [undefined, "203.0.113.21, 192.0.2.99", "invalid-ip"]) {
    const headers = new Headers({ "x-forwarded-for": "192.0.2.99" });
    if (value) headers.set("cf-connecting-ip", value);
    await assert.rejects(nomadsNetworkHeaders(headers, secret, time, "cloudflare-tunnel"));
  }
});

test("Cloudflare ingress preserves IPv6 attribution", async () => {
  const headers = await nomadsNetworkHeaders(
    new Headers({ "cf-connecting-ip": "2001:db8::1" }),
    secret,
    time,
    "cloudflare-tunnel",
  );
  assert.equal(headers.get("x-nomads-network-ip"), "2001:db8::1");
});

test("unknown deployment modes cannot silently select another trust boundary", async () => {
  await assert.rejects(
    nomadsNetworkHeaders(new Headers({ "x-forwarded-for": "203.0.113.21" }), secret, time, "unknown"),
  );
});

test("the shared IP selector rejects invalid addresses and preserves the Vercel deployment", () => {
  for (const value of ["999.999.999.999", "...", "abcd", "2001:db8:::1"]) {
    assert.equal(trustedClientIp(new Headers({ "cf-connecting-ip": value }), "cloudflare-tunnel"), null);
  }
  assert.equal(
    trustedClientIp(new Headers({ "x-forwarded-for": "203.0.113.21", "cf-connecting-ip": "192.0.2.99" })),
    "203.0.113.21",
  );
});
