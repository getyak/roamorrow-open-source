import { NextResponse } from "next/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Process/source readiness only; this endpoint never queries private data. */
export function GET(): NextResponse {
  return NextResponse.json(
    {
      status: "ready",
      revision: process.env.ROAMORROW_WEB_REVISION ?? "development",
      publicConfigSha256: process.env.ROAMORROW_WEB_PUBLIC_CONFIG_SHA256 ?? "unconfigured",
    },
    { headers: { "Cache-Control": "no-store" } },
  );
}
