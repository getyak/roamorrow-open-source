// Each deployment trusts only its ingress's overwritten client-IP header.
// Vercel: https://vercel.com/docs/headers/request-headers#x-forwarded-for
// A dedicated Cloudflare Tunnel reaches only the Mac's loopback listener:
// https://developers.cloudflare.com/fundamentals/reference/http-request-headers/#cf-connecting-ip
// The deployment selects this mode; a request header cannot select it.
import { trustedClientIp } from "./client-ip";

export async function nomadsNetworkHeaders(
  incoming: Headers,
  secret: string | undefined,
  now = Date.now(),
  ingress: string = "vercel",
): Promise<Headers> {
  const ip = trustedClientIp(incoming, ingress);
  if (!secret || secret.length < 16 || !ip) {
    throw new Error("Nomads network attribution is unavailable");
  }
  const stamp = String(now);
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(stamp + "\n" + ip)),
  );
  const headers = new Headers(incoming);
  headers.set("x-nomads-network-ip", ip);
  headers.set("x-nomads-network-time", stamp);
  headers.set(
    "x-nomads-network-signature",
    [...signature].map((value) => value.toString(16).padStart(2, "0")).join(""),
  );
  return headers;
}
