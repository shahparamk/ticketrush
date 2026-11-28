import { createHash } from "node:crypto";

export const HOLD_SECONDS = 5 * 60;
export const MAX_HOLDS_PER_BUYER = 4;
export const IDEMPOTENCY_TTL_SECONDS = 24 * 3600; // DynamoDB TTL deletes old idempotency records
export const BUYER_TTL_SECONDS = 7 * 24 * 3600;

// seatId -> hold expiry (epoch seconds)
export type BuyerHolds = Record<string, number>;

// Holds still in force: expired ones don't count against the limit (same rule as the seat's lazy expiry)
export function activeHolds(holds: BuyerHolds | undefined, nowSeconds: number, exceptSeat?: string): BuyerHolds {
  const active: BuyerHolds = {};
  for (const [seatId, expiresAt] of Object.entries(holds ?? {})) {
    if (seatId !== exceptSeat && expiresAt > nowSeconds) active[seatId] = expiresAt;
  }
  return active;
}

// Fingerprint of a request, so an idempotency key can't be reused for a DIFFERENT request
export function requestHash(...parts: string[]): string {
  return createHash("sha256").update(parts.join("|")).digest("hex");
}