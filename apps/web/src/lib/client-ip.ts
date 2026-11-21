/** The deployment selects its trusted ingress; request headers cannot select it. */
export function trustedClientIp(incoming: Headers, ingress = "vercel"): string | null {
  if (ingress !== "vercel" && ingress !== "cloudflare-tunnel") return null;
  const ip =
    ingress === "cloudflare-tunnel"
      ? incoming.get("cf-connecting-ip")?.trim()
      : incoming.get("x-forwarded-for")?.split(",")[0]?.trim();
  if (!ip || !/^[0-9a-f:.]{3,64}$/i.test(ip)) return null;
  if (/^(?:\d{1,3}\.){3}\d{1,3}$/.test(ip)) {
    return ip.split(".").every((part) => Number(part) <= 255) ? ip : null;
  }
  if (ip.includes(":")) {
    try {
      // WHATWG URL validates IPv6 in both the middleware and Node runtimes.
      new URL(`http://[${ip}]/`);
      return ip;
    } catch {
      return null;
    }
  }
  return null;
}
