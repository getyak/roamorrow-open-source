import { describe, expect, it } from "vitest";
import { FEATURE_KEYS, type ResolvedPlaceFeature } from "./evidence";
import {
  calculateRefreshPriority,
  decideFeatureRefresh,
  makeRefreshIdempotencyKey,
} from "./refresh-policy";

function feature(
  status: ResolvedPlaceFeature["status"],
  freshUntil = "2026-09-01T00:00:00.000Z",
): ResolvedPlaceFeature {
  return {
    placeId: "place",
    featureKey: FEATURE_KEYS.regularOpeningHours,
    value: "Mon-Fri 08:00-18:00",
    status,
    confidence: 0.8,
    latestObservedAt: "2026-08-30T00:00:00.000Z",
    freshUntil,
    supportingObservationIds: ["obs"],
    conflictingObservationIds: [],
    resolverVersion: "test",
    resolutionFingerprint: "test",
    resolvedAt: "2026-08-31T00:00:00.000Z",
  };
}

describe("refresh policy", () => {
  it("prioritizes high-impact uncertain evidence within a bounded score", () => {
    expect(
      calculateRefreshPriority({
        demandScore: 0.9,
        decisionImpact: 1,
        uncertainty: 0.8,
        staleness: 1,
        estimatedCost: 0.1,
        urgency: "interactive",
      }),
    ).toBe(1000);
    expect(
      calculateRefreshPriority({
        demandScore: 0.2,
        decisionImpact: 0.2,
        uncertainty: 0.2,
        staleness: 0.2,
        estimatedCost: 1,
        urgency: "background",
      }),
    ).toBe(0);
  });

  it("serves fresh materialized evidence without external work", () => {
    expect(
      decideFeatureRefresh({
        feature: feature("resolved"),
        hardConstraint: true,
        viableAlternativeCount: 0,
        now: "2026-08-31T00:00:00.000Z",
      }),
    ).toMatchObject({ action: "none", enqueue: false });
  });

  it("blocks only when a hard constraint has no viable fallback", () => {
    expect(
      decideFeatureRefresh({
        feature: feature("stale", "2026-08-01T00:00:00.000Z"),
        hardConstraint: true,
        viableAlternativeCount: 0,
        now: "2026-08-31T00:00:00.000Z",
      }),
    ).toMatchObject({ action: "blocking", enqueue: true, reason: "hard_constraint" });
  });

  it("excludes stale hard-constraint candidates when a fallback exists", () => {
    expect(
      decideFeatureRefresh({
        feature: feature("conflicted"),
        hardConstraint: true,
        viableAlternativeCount: 2,
        now: "2026-08-31T00:00:00.000Z",
      }),
    ).toMatchObject({ action: "exclude", enqueue: true });
  });

  it("deduplicates refresh jobs by sorted fields and time bucket", () => {
    const first = makeRefreshIdempotencyKey({
      placeId: "place",
      featureKeys: [FEATURE_KEYS.videoCallFit, FEATURE_KEYS.regularOpeningHours],
      reason: "hard_constraint",
      now: "2026-08-31T12:12:00.000Z",
    });
    const second = makeRefreshIdempotencyKey({
      placeId: "place",
      featureKeys: [FEATURE_KEYS.regularOpeningHours, FEATURE_KEYS.videoCallFit],
      reason: "hard_constraint",
      now: "2026-08-31T12:55:00.000Z",
    });
    expect(first).toBe(second);
  });
});

describe("regional coverage refresh identity", () => {
  function key(
    center: readonly [number, number],
    radiusMeters = 1500,
    now = "2026-11-07T01:00:00.000Z",
  ) {
    return makeRefreshIdempotencyKey({
      featureKeys: [],
      reason: "coverage_gap",
      bucketSeconds: 6 * 60 * 60,
      region: { center, radiusMeters },
      now,
    });
  }

  it("does not let a Chiang Mai job suppress Vientiane in the same time bucket", () => {
    expect(key([98.9853, 18.7883])).not.toBe(key([102.6093, 17.9633]));
  });

  it("does not let a small-radius job suppress a wider request", () => {
    expect(key([98.9853, 18.7883], 1500)).not.toBe(key([98.9853, 18.7883], 10000));
  });

  it("deduplicates sub-cell coordinate and sub-meter radius noise", () => {
    const keys = new Set(
      Array.from({ length: 101 }, (_, i) =>
        key([98.9853 + (i - 50) * 0.0000001, 18.7883], 1500 + i * 0.000001),
      ),
    );
    expect(keys.size).toBe(1);
  });

  it("normalizes signed zero but keeps the worker's clipped dateline sides distinct", () => {
    expect(key([-0, 0])).toBe(key([0, -0]));
    expect(key([180, 10])).not.toBe(key([-180, 10]));
  });

  it("deduplicates within a six-hour window and permits a new window", () => {
    const center = [98.9853, 18.7883] as const;
    expect(key(center, 1500, "2026-11-07T05:59:59.999Z")).toBe(key(center));
    expect(key(center, 1500, "2026-11-07T06:00:00.000Z")).not.toBe(key(center));
  });

  it.each([
    undefined,
    { center: [98, 18] },
    { center: ["98", 18], radiusMeters: 1500 },
    { center: [98, 18, 0], radiusMeters: 1500 },
    { center: [Number.NaN, 18], radiusMeters: 1500 },
    { center: [181, 18], radiusMeters: 1500 },
    { center: [98, 91], radiusMeters: 1500 },
    { center: [98, 18], radiusMeters: Number.POSITIVE_INFINITY },
    { center: [98, 18], radiusMeters: 99 },
    { center: [98, 18], radiusMeters: 10001 },
  ])("rejects an invalid region instead of creating a global coverage key: %j", (region) => {
    expect(() =>
      makeRefreshIdempotencyKey({
        featureKeys: [],
        reason: "coverage_gap",
        region: region as never,
      }),
    ).toThrow(/region/i);
  });
});
