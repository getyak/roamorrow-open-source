import type { FeatureKey, ResolvedPlaceFeature } from "./evidence";

export type RefreshReason =
  "coverage_gap" | "soft_stale" | "hard_constraint" | "user_report" | "source_release" | "manual";
export type RefreshUrgency = "background" | "interactive";
export type RefreshAction = "none" | "enqueue" | "blocking" | "exclude";

export interface RefreshPriorityInput {
  readonly demandScore: number;
  readonly decisionImpact: number;
  readonly uncertainty: number;
  readonly staleness: number;
  readonly estimatedCost: number;
  readonly urgency: RefreshUrgency;
}

export interface FeatureRefreshDecisionInput {
  readonly feature?: ResolvedPlaceFeature;
  readonly hardConstraint: boolean;
  readonly viableAlternativeCount: number;
  readonly now?: string;
}

export interface FeatureRefreshDecision {
  readonly action: RefreshAction;
  readonly enqueue: boolean;
  readonly reason?: RefreshReason;
  readonly explanation: string;
}

export interface CoverageRefreshRegion {
  readonly center: readonly [longitude: number, latitude: number];
  readonly radiusMeters: number;
}

export function calculateRefreshPriority(input: RefreshPriorityInput): number {
  const demand = probability(input.demandScore, "demandScore");
  const impact = probability(input.decisionImpact, "decisionImpact");
  const uncertainty = probability(input.uncertainty, "uncertainty");
  const staleness = probability(input.staleness, "staleness");
  if (!Number.isFinite(input.estimatedCost) || input.estimatedCost <= 0) {
    throw new Error("estimatedCost must be greater than zero");
  }
  const urgencyMultiplier = input.urgency === "interactive" ? 1.5 : 1;
  const raw =
    (demand * impact * uncertainty * staleness * urgencyMultiplier) /
    Math.max(input.estimatedCost, 0.05);
  return Math.min(1000, Math.round(raw * 100));
}

export function decideFeatureRefresh(input: FeatureRefreshDecisionInput): FeatureRefreshDecision {
  const nowMs = Date.parse(input.now ?? new Date().toISOString());
  if (!Number.isFinite(nowMs)) throw new Error("now must be a valid ISO 8601 timestamp");
  const feature = input.feature;

  if (!feature || feature.status === "unknown") {
    return hardGapDecision(input, "Required evidence is unknown");
  }
  const expired = feature.freshUntil !== undefined && Date.parse(feature.freshUntil) <= nowMs;
  if (feature.status === "conflicted") {
    return hardGapDecision(input, "Independent sources conflict");
  }
  if (feature.status === "stale" || expired) {
    return hardGapDecision(input, "Evidence is stale");
  }
  return {
    action: "none",
    enqueue: false,
    explanation: "Materialized evidence is fresh enough for this decision",
  };
}

function hardGapDecision(
  input: FeatureRefreshDecisionInput,
  explanation: string,
): FeatureRefreshDecision {
  if (!input.hardConstraint) {
    return { action: "enqueue", enqueue: true, reason: "soft_stale", explanation };
  }
  if (input.viableAlternativeCount > 0) {
    return {
      action: "exclude",
      enqueue: true,
      reason: "hard_constraint",
      explanation: `${explanation}; exclude this candidate and refresh in the background`,
    };
  }
  return {
    action: "blocking",
    enqueue: true,
    reason: "hard_constraint",
    explanation: `${explanation}; verify synchronously because no viable fallback exists`,
  };
}

export function makeRefreshIdempotencyKey(input: {
  readonly placeId?: string;
  readonly region?: CoverageRefreshRegion;
  readonly featureKeys: readonly FeatureKey[];
  readonly reason: RefreshReason;
  readonly bucketSeconds?: number;
  readonly now?: string;
}): string {
  const nowMs = Date.parse(input.now ?? new Date().toISOString());
  if (!Number.isFinite(nowMs)) throw new Error("now must be a valid ISO 8601 timestamp");
  const bucketSeconds = input.bucketSeconds ?? 60 * 60;
  if (!Number.isFinite(bucketSeconds) || bucketSeconds <= 0) {
    throw new Error("bucketSeconds must be greater than zero");
  }
  const bucketMs = bucketSeconds * 1000;
  const bucket = new Date(Math.floor(nowMs / bucketMs) * bucketMs).toISOString();
  const features = [...new Set(input.featureKeys)].sort().join(",");
  let scope = input.placeId ?? "region";
  if (input.placeId == null && input.reason === "coverage_gap") {
    const region = normalizeCoverageRefreshRegion(input.region);
    scope = `region-v2:${region.center[0]}:${region.center[1]}:${region.radiusMeters}`;
  }
  return [scope, features || "coverage", input.reason, bucket].join(":");
}

/** Match the map's ~55m cache cells; store this same region in the queued query. */
export function normalizeCoverageRefreshRegion(value: unknown): CoverageRefreshRegion {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("coverage region requires a center and radiusMeters");
  }
  const { center, radiusMeters } = value as Record<string, unknown>;
  if (
    !Array.isArray(center) ||
    center.length !== 2 ||
    typeof center[0] !== "number" ||
    typeof center[1] !== "number" ||
    !Number.isFinite(center[0]) ||
    !Number.isFinite(center[1]) ||
    Math.abs(center[0]) > 180 ||
    Math.abs(center[1]) > 90 ||
    typeof radiusMeters !== "number" ||
    !Number.isFinite(radiusMeters) ||
    radiusMeters < 100 ||
    radiusMeters > 10000
  ) {
    throw new Error("coverage region must have bounded geographic coordinates and radiusMeters");
  }
  const quantise = (coordinate: number) => Math.round(coordinate * 2000) / 2000 || 0;
  // The worker clips provider bounds at the dateline rather than wrapping them.
  // Keep east/west identities distinct so normalization cannot move a query across it.
  return {
    center: [quantise(center[0]), quantise(center[1])],
    radiusMeters: Math.round(radiusMeters),
  };
}

function probability(value: number, label: string): number {
  if (!Number.isFinite(value) || value < 0 || value > 1) {
    throw new Error(`${label} must be between 0 and 1`);
  }
  return value;
}
