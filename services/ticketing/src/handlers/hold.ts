import { randomUUID } from "node:crypto";
import type { APIGatewayProxyEventV2WithLambdaAuthorizer, APIGatewayProxyStructuredResultV2 } from "aws-lambda";
import { error, json } from "../lib/http.ts";
import { DynamoHoldRepo, type HoldRepo, type IdempotencyItem } from "../lib/hold-repository.ts";
import {
  BUYER_TTL_SECONDS,
  HOLD_SECONDS,
  IDEMPOTENCY_TTL_SECONDS,
  MAX_HOLDS_PER_BUYER,
  activeHolds,
  requestHash,
  type BuyerHolds,
} from "../lib/holds.ts";
import { effectiveStatus } from "../lib/seats.ts";
import { EVENT_ID, IDEMPOTENCY_KEY, SEAT_ID } from "../lib/validate.ts";
import type { BuyerContext } from "./session.ts";

type HoldEvent = APIGatewayProxyEventV2WithLambdaAuthorizer<BuyerContext>;
type Result = APIGatewayProxyStructuredResultV2;

const MAX_ATTEMPTS = 6; // retries for buyer-record races and DynamoDB TransactionConflict under contention
const AVAILABILITY_CACHE_SECONDS = 2; // how long one container trusts its "seats left" count

export interface HoldDeps {
  repo: HoldRepo;
  now?: () => number;
  newId?: () => string;
  sleep?: (ms: number) => Promise<void>;
  regionRole?: () => string;
  maxHolds?: number;
  holdSeconds?: number;
}

const log = (fields: Record<string, unknown>) => console.log(JSON.stringify({ msg: "hold", ...fields }));

export function makeHoldHandler(deps: HoldDeps) {
  const now = deps.now ?? (() => Math.floor(Date.now() / 1000));
  const newId = deps.newId ?? randomUUID;
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const regionRole = deps.regionRole ?? (() => process.env.REGION_ROLE ?? "primary");
  const maxHolds = deps.maxHolds ?? MAX_HOLDS_PER_BUYER;
  const holdSeconds = deps.holdSeconds ?? HOLD_SECONDS;
  const repo = deps.repo;

  // Per-container cache of "seats left" per event, so a rush doesn't count the seats on every 409
  const availability = new Map<string, { checkedAt: number; available: number }>();

  return async (event: HoldEvent): Promise<Result> => {
    const region = process.env.AWS_REGION ?? "unknown";

    // Active-passive: only the primary region accepts writes (failover flips REGION_ROLE)
    if (regionRole() !== "primary") {
      return error(503, "READ_ONLY_STANDBY", "This region is a read-only standby; writes go to the primary region");
    }

    const buyerId = event.requestContext.authorizer?.lambda?.buyerId;
    if (!buyerId) return error(401, "UNAUTHENTICATED", "No buyer on this request");

    const eventId = event.pathParameters?.eventId ?? "";
    const seatId = event.pathParameters?.seatId ?? "";
    if (!EVENT_ID.test(eventId)) return error(400, "BAD_EVENT_ID", "Invalid eventId");
    if (!SEAT_ID.test(seatId)) return error(400, "BAD_SEAT_ID", "seatId must look like A01");

    try {
      switch (event.routeKey) {
        case "POST /events/{eventId}/seats/{seatId}/hold":
          return await hold(event, region, buyerId, eventId, seatId);
        case "DELETE /events/{eventId}/seats/{seatId}/hold":
          return await release(region, buyerId, eventId, seatId);
        default:
          return error(404, "ROUTE_NOT_FOUND", `No route ${event.routeKey}`);
      }
    } catch (err) {
      console.error(JSON.stringify({ msg: "hold failed", eventId, seatId, error: String(err) }));
      return error(500, "INTERNAL", "Something went wrong");
    }
  };

  async function hold(event: HoldEvent, region: string, buyerId: string, eventId: string, seatId: string): Promise<Result> {
    const key = event.headers?.["idempotency-key"] ?? "";
    if (!IDEMPOTENCY_KEY.test(key)) {
      return error(400, "IDEMPOTENCY_KEY_REQUIRED", "Send an Idempotency-Key header (8-64 letters, digits, - or _)");
    }
    const idempotencyKey = `${buyerId}#${key}`; // scoped per buyer: one buyer can't replay another's key
    const fingerprint = requestHash("hold", eventId, seatId);

    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
      // 1. Seen this key before? Return the original answer (a double click never holds a second seat)
      const previous = await repo.getIdempotency(idempotencyKey);
      if (previous) return replay(previous, fingerprint);

      // 2. Enforce the per-buyer limit (expired holds don't count)
      const t = now();
      const buyer = await repo.getBuyer(eventId, buyerId);
      const others = activeHolds(buyer?.holds, t, seatId);
      if (Object.keys(others).length >= maxHolds) {
        log({ outcome: "limit", eventId, seatId });
        return error(409, "HOLD_LIMIT_REACHED", `A buyer can hold at most ${maxHolds} seats at once`);
      }

      // 3. One all-or-nothing transaction: seat + buyer record + idempotency record
      const holdId = newId();
      const expiresAt = t + holdSeconds;
      const body = JSON.stringify({ region, eventId, seatId, holdId, expiresAt });
      const newHolds: BuyerHolds = { ...others, [seatId]: expiresAt };
      const result = await repo.holdSeat({
        eventId,
        seatId,
        buyerId,
        holdId,
        nowSeconds: t,
        expiresAt,
        buyerVersion: buyer?.version,
        newHolds,
        buyerTtl: t + BUYER_TTL_SECONDS,
        idempotency: { idempotencyKey, requestHash: fingerprint, statusCode: 201, body, expiresAt: t + IDEMPOTENCY_TTL_SECONDS },
      });

      if (result.ok) {
        log({ outcome: "held", eventId, seatId, attempt });
        return json(201, JSON.parse(body));
      }
      if (result.failed === "SEAT") return seatConflict(buyerId, eventId, seatId);
      // IDEMPOTENCY: a concurrent request with the same key just won -> loop replays it.
      // BUYER / CONFLICT: something changed under us -> wait a little (with jitter) and retry.
      if (result.failed !== "IDEMPOTENCY") await sleep(Math.floor(Math.random() * 20 * attempt));
    }

    log({ outcome: "contended", eventId, seatId });
    return error(503, "CONTENDED", "Too many simultaneous requests for this seat; please retry");
  }

  async function seatConflict(buyerId: string, eventId: string, seatId: string): Promise<Result> {
    const seat = await repo.getSeat(eventId, seatId);
    if (!seat) return error(404, "SEAT_NOT_FOUND", `No seat ${seatId} for event ${eventId}`);
    if (seat.holderId === buyerId && effectiveStatus(seat, now()) === "held") {
      return error(409, "ALREADY_HELD_BY_YOU", "You already hold this seat");
    }
    // Nothing left at all? Tell the buyer to stop trying (saves them, and us, thousands of requests)
    if ((await seatsLeft(eventId)) === 0) {
      log({ outcome: "sold_out", eventId, seatId });
      return error(409, "SOLD_OUT", "Every seat is held or sold. Held seats come back if not bought within 5 minutes.");
    }
    log({ outcome: "taken", eventId, seatId });
    return error(409, "SEAT_TAKEN", "Sorry, someone else just got this seat");
  }

  // Cached for a couple of seconds per container; -1 (unknown) if the count fails, so we never fail the request
  async function seatsLeft(eventId: string): Promise<number> {
    const t = now();
    const cached = availability.get(eventId);
    if (cached && t - cached.checkedAt < AVAILABILITY_CACHE_SECONDS) return cached.available;
    try {
      const available = await repo.countAvailable(eventId, t);
      availability.set(eventId, { checkedAt: t, available });
      return available;
    } catch (err) {
      console.error(JSON.stringify({ msg: "seat count failed", eventId, error: String(err) }));
      return -1;
    }
  }

  async function release(region: string, buyerId: string, eventId: string, seatId: string): Promise<Result> {
    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
      const buyer = await repo.getBuyer(eventId, buyerId);
      if (!buyer || !(seatId in (buyer.holds ?? {}))) {
        return error(409, "NOT_HELD_BY_YOU", "You don't hold this seat");
      }
      const { [seatId]: _released, ...rest } = buyer.holds ?? {};
      const result = await repo.releaseSeat({
        eventId,
        seatId,
        buyerId,
        buyerVersion: buyer.version,
        newHolds: activeHolds(rest, now()),
      });
      if (result.ok) {
        availability.delete(eventId); // a seat just came back
        log({ outcome: "released", eventId, seatId });
        return json(200, { region, eventId, seatId, released: true });
      }
      if (result.failed === "SEAT") return error(409, "NOT_HELD_BY_YOU", "You don't hold this seat");
      await sleep(Math.floor(Math.random() * 20 * attempt));
    }
    return error(503, "CONTENDED", "Please retry");
  }

  function replay(previous: IdempotencyItem, fingerprint: string): Result {
    if (previous.requestHash !== fingerprint) {
      return error(422, "IDEMPOTENCY_KEY_REUSED", "This Idempotency-Key was already used for a different request");
    }
    return {
      statusCode: previous.statusCode,
      headers: { "content-type": "application/json", "cache-control": "no-store", "idempotent-replayed": "true" },
      body: previous.body,
    };
  }
}

export const handler = makeHoldHandler({
  repo: new DynamoHoldRepo({
    seats: process.env.SEATS_TABLE ?? "",
    buyers: process.env.BUYERS_TABLE ?? "",
    idempotency: process.env.IDEMPOTENCY_TABLE ?? "",
  }),
});