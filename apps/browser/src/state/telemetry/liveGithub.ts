import type { ConsentToken } from "./choice";
import { consentOrNow, countFor } from "./countFor";

const NONE = { sent: 0, held: 0, rateLimited: 0, detailsFetched: 0, detailsReused: 0, blockedListings: 0, restFallbacks: 0, restRecovered: 0, restFailed: 0 };
let counts = { ...NONE };

export const noteLiveGithubRequest = (outcome: "sent" | "held" | "rateLimited") => void counts[outcome]++;

export const noteLiveGithubBlocked = (consent?: ConsentToken | null) => countFor(consentOrNow(consent), () => void counts.blockedListings++);

export function noteLiveGithubDetails(fetched: number, reused: number) {
  counts.detailsFetched += fetched;
  counts.detailsReused += reused;
}

export function noteLiveGithubRest(recovered: number) {
  counts.restFallbacks++;
  counts.restRecovered += recovered;
  if (!recovered) counts.restFailed++;
}

export function takeLiveGithubCounts() {
  const taken = {
    live_github_requests: counts.sent,
    live_github_requests_held: counts.held,
    live_github_rate_limited: counts.rateLimited,
    live_github_details_fetched: counts.detailsFetched,
    live_github_details_reused: counts.detailsReused,
    live_github_blocked_listings: counts.blockedListings,
    live_github_rest_fallbacks: counts.restFallbacks,
    live_github_rest_recovered: counts.restRecovered,
    live_github_rest_failed: counts.restFailed,
  };
  counts = { ...NONE };
  return taken;
}
