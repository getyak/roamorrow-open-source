import type { NextConfig } from "next";
import { withSentryConfig } from "@sentry/nextjs/config";
import path from "node:path";

const releaseRevision = process.env.ROAMORROW_WEB_REVISION;
const publicConfigHash = process.env.ROAMORROW_WEB_PUBLIC_CONFIG_SHA256;
if (
  (releaseRevision || publicConfigHash) &&
  (!/^[0-9a-f]{40}$/.test(releaseRevision ?? "") || !/^[0-9a-f]{64}$/.test(publicConfigHash ?? ""))
) {
  throw new Error("Web release source and configuration hashes must be supplied together");
}

const nextConfig: NextConfig = {
  reactStrictMode: true,
  output: "standalone",
  outputFileTracingRoot: path.join(process.cwd(), "../.."),
  ...(releaseRevision ? { generateBuildId: async () => releaseRevision } : {}),
  // These two nonsecret constants are compiled into the server. Runtime env
  // cannot make an old bundle claim a different source/configuration.
  env: {
    ROAMORROW_WEB_REVISION: releaseRevision ?? "development",
    ROAMORROW_WEB_PUBLIC_CONFIG_SHA256: publicConfigHash ?? "unconfigured",
  },
  transpilePackages: ["@solo-compass/core", "@solo-compass/ai", "@solo-compass/data"],
  // The independent Nomads worker owns its canonical directory slashes.
  // https://nextjs.org/docs/15/app/api-reference/file-conventions/middleware#advanced-middleware-flags
  skipTrailingSlashRedirect: true,
  async rewrites() {
    return {
      beforeFiles: [
        {
          source: "/nomads/:path*/",
          destination: "https://nomads.cubxxw.com/nomads/:path*/",
        },
        {
          source: "/nomads/:path*",
          destination: "https://nomads.cubxxw.com/nomads/:path*",
        },
      ],
      afterFiles: [],
      fallback: [],
    };
  },
};

export default withSentryConfig(nextConfig, { silent: true });
