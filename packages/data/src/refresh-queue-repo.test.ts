import { createClient } from "@supabase/supabase-js";
import { describe, expect, it } from "vitest";
import type { Database, RefreshJobRow } from "./db";
import type { JsonValue } from "./evidence";
import { RefreshQueueRepo, type EnqueueRefreshInput } from "./refresh-queue-repo";

/** Isolated PostgREST boundary: the unique key and ignore-duplicate behavior are real consumers. */
function isolatedQueue() {
  const rows = new Map<string, RefreshJobRow>();
  const client = createClient<Database>("https://queue.example.test", "isolated-anon", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: async (input, init) => {
        const url = new URL(String(input));
        if (
          url.origin !== "https://queue.example.test" ||
          url.pathname !== "/rest/v1/refresh_jobs"
        ) {
          throw new Error("Unexpected external request in isolated queue test");
        }
        if (init?.method === "POST") {
          const inserted = JSON.parse(String(init.body)) as RefreshJobRow;
          if (rows.has(inserted.idempotency_key)) return Response.json([]);
          const now = "2026-11-07T01:00:00.000Z";
          const row: RefreshJobRow = {
            ...inserted,
            id: `job-${rows.size + 1}`,
            status: "queued",
            claimed_by: null,
            claimed_at: null,
            lease_expires_at: null,
            attempts: 0,
            last_error: null,
            result: null,
            created_at: now,
            updated_at: now,
            completed_at: null,
          };
          rows.set(row.idempotency_key, row);
          return Response.json([row]);
        }
        const key = url.searchParams.get("idempotency_key")?.replace(/^eq\./, "");
        const row = key ? rows.get(key) : undefined;
        if (!row) throw new Error("Unexpected lookup outside the isolated queue");
        return Response.json(row);
      },
    },
  });
  return { queue: new RefreshQueueRepo(client), rows };
}

function coverage(center: readonly [number, number], radiusMeters = 1500): EnqueueRefreshInput {
  return {
    featureKeys: [],
    query: { center, radiusMeters, experienceAnchors: [] },
    reason: "coverage_gap",
    urgency: "background",
    demandScore: 0.8,
    decisionImpact: 0.7,
    uncertainty: 1,
    staleness: 1,
    estimatedCost: 0.5,
    budgetClass: "coverage_backfill",
    bucketSeconds: 21600,
    now: "2026-11-07T01:00:00.000Z",
  };
}

const invalidCoverageQueries: readonly (JsonValue | undefined)[] = [
  undefined,
  { center: [98, 18] },
  { center: [98, 18], radiusMeters: 10001 },
];

describe("regional refresh queue persistence", () => {
  it("returns the requested region's job instead of an earlier region's job", async () => {
    const { queue, rows } = isolatedQueue();
    const chiangMai = await queue.enqueue(coverage([98.9853, 18.7883]));
    const vientiane = await queue.enqueue(coverage([102.6093, 17.9633]));
    const widerChiangMai = await queue.enqueue(coverage([98.9853, 18.7883], 10000));
    expect(rows.size).toBe(3);
    expect(new Set([chiangMai.id, vientiane.id, widerChiangMai.id]).size).toBe(3);
    expect(chiangMai.query).toEqual({
      center: [98.9855, 18.7885],
      radiusMeters: 1500,
      experienceAnchors: [],
    });
    expect(vientiane.query).toEqual({
      center: [102.6095, 17.9635],
      radiusMeters: 1500,
      experienceAnchors: [],
    });
    expect(widerChiangMai.query).toEqual({
      center: [98.9855, 18.7885],
      radiusMeters: 10000,
      experienceAnchors: [],
    });
  });

  it("persists the canonical region for both equivalent requests and the returned job", async () => {
    const { queue, rows } = isolatedQueue();
    const first = await queue.enqueue(coverage([98.9853, 18.7883]));
    const jitter = await queue.enqueue(coverage([98.985301, 18.788301], 1500.01));
    expect(rows.size).toBe(1);
    expect(jitter.id).toBe(first.id);
    expect(jitter.query).toEqual({
      center: [98.9855, 18.7885],
      radiusMeters: 1500,
      experienceAnchors: [],
    });
  });

  it("keeps a refresh on the requested side of the worker's clipped dateline", async () => {
    const { queue, rows } = isolatedQueue();
    const east = await queue.enqueue(coverage([179.9999, 10], 100));
    const west = await queue.enqueue(coverage([-179.9999, 10], 100));
    expect(rows.size).toBe(2);
    expect(east.id).not.toBe(west.id);
    expect(east.query).toEqual({
      center: [180, 10],
      radiusMeters: 100,
      experienceAnchors: [],
    });
    expect(west.query).toEqual({
      center: [-180, 10],
      radiusMeters: 100,
      experienceAnchors: [],
    });
  });

  it("keeps existing place-scoped refresh identity and query semantics", async () => {
    const { queue, rows } = isolatedQueue();
    const request: EnqueueRefreshInput = {
      ...coverage([98, 18]),
      placeId: "place-1",
      featureKeys: ["opening_hours.regular"],
      reason: "soft_stale",
      query: { placeName: "Existing place", coordinates: [98.9853, 18.7883] },
    };
    const first = await queue.enqueue(request);
    const repeated = await queue.enqueue(request);
    expect(rows.size).toBe(1);
    expect(repeated.id).toBe(first.id);
    expect(repeated.query).toEqual(request.query);
    expect(first.idempotency_key).toBe(
      "place-1:opening_hours.regular:soft_stale:2026-11-07T00:00:00.000Z",
    );
  });

  it.each(invalidCoverageQueries)(
    "rejects incomplete or unbounded coverage before any queue row can be written: %j",
    async (query) => {
      const { queue, rows } = isolatedQueue();
      await expect(queue.enqueue({ ...coverage([98, 18]), query })).rejects.toThrow(/region/i);
      expect(rows.size).toBe(0);
    },
  );
});
