/** Private research contracts. V2 plans never enter legacy itinerary LWW sync. */
export type TravelJSON =
  null | boolean | string | number | TravelJSON[] | { [key: string]: TravelJSON };
export interface TravelDateScope {
  kind: "dated" | "undated";
  startDate?: string;
  endDate?: string;
  timezone?: string;
}
export interface TravelStopTime {
  kind: "unscheduled" | "window" | "fixed";
  instant?: string;
  timezone?: string;
  startLocal?: string;
  endLocal?: string;
}
export interface TravelPlace {
  ref: string;
  name: string;
  /** WGS84 GeoJSON [longitude, latitude]. */
  coordinates: number[];
  timezone?: string;
}
export interface TravelStop {
  id: string;
  title: string;
  candidateRef?: string;
  experienceRef?: string;
  place?: TravelPlace;
  time: TravelStopTime;
  durationMinutes?: number;
  claimRefs: string[];
  lockedFields: string[];
}
export interface TravelDay {
  id: string;
  date?: string;
  label: string;
  stops: TravelStop[];
}
export interface TravelPlanInput {
  stablePlanId: string;
  title: string;
  dateScope: TravelDateScope;
  days: TravelDay[];
  assumptions: string[];
}
export interface TravelDraft {
  id: string;
  version: number;
  plan: TravelPlanInput;
  baseItinerary?: TravelJSON;
}
export type TravelResultStatus =
  "ok" | "empty" | "partial" | "blocked" | "conflict" | "unavailable" | "uncertain";
export interface TravelCoverage {
  kind: "complete" | "partial" | "metadata_only" | "unknown";
  missing: string[];
}
export interface TravelProblem {
  code: string;
  message?: string;
  retryable: boolean;
  nextAction?: string;
}
export interface TravelResult<T> {
  contractVersion: 1;
  status: TravelResultStatus;
  data: T;
  coverage: TravelCoverage;
  usage?: { sourceReads: number };
  observedAt?: string;
  error?: TravelProblem | null;
}
export const TRAVEL_MODEL_TOOLS = [
  "get_travel_context",
  "read_source",
  "web_search",
  "search_places",
  "get_place_evidence",
  "estimate_route",
  "save_research",
  "get_research",
  "get_itinerary",
  "save_itinerary_draft",
  "preview_itinerary_changes",
  "list_calendar_events",
  "preview_calendar_changes",
  "get_operation",
] as const;
export type TravelModelTool = (typeof TRAVEL_MODEL_TOOLS)[number];
