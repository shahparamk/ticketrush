import { test } from "node:test";
import assert from "node:assert/strict";
import type { APIGatewayProxyEventV2 } from "aws-lambda";
import { makeReadHandler } from "./read.ts";
import type { EventItem, TicketingRepo } from "../lib/repository.ts";
import type { SeatItem } from "../lib/seats.ts";

const demoEvent: EventItem = {
  eventId: "demo",
  name: "Demo",
  venue: "Boston",
  startsAt: "2026-12-31T20:00:00Z",
  rows: 1,
  seatsPerRow: 2,
  seatCount: 2,
  priceCents: 7500,
};

const demoSeats: SeatItem[] = [
  { eventId: "demo", seatId: "A01", row: "A", number: 1, status: "available", version: 0 },
  { eventId: "demo", seatId: "A02", row: "A", number: 2, status: "held", holderId: "secret", holdExpiresAt: 5_000, version: 1 },
];

const fakeRepo: TicketingRepo = {
  getEvent: async (id) => (id === "demo" ? demoEvent : undefined),
  listSeats: async () => demoSeats,
};

const call = (routeKey: string, eventId: string | undefined) =>
  makeReadHandler(fakeRepo, () => 1_000)({ routeKey, pathParameters: eventId ? { eventId } : undefined } as unknown as APIGatewayProxyEventV2);

test("GET event returns public event details", async () => {
  const res = await call("GET /events/{eventId}", "demo");
  assert.equal(res.statusCode, 200);
  const body = JSON.parse(res.body ?? "{}");
  assert.equal(body.event.name, "Demo");
  assert.equal(body.event.rows, undefined); // internal layout fields aren't exposed
});

test("GET seats returns the map with a summary, and hides holders", async () => {
  const res = await call("GET /events/{eventId}/seats", "demo");
  assert.equal(res.statusCode, 200);
  const body = JSON.parse(res.body ?? "{}");
  assert.deepEqual(body.summary, { total: 2, available: 1, held: 1, sold: 0 });
  assert.equal(JSON.stringify(body).includes("secret"), false);
});

test("unknown event -> 404, bad id -> 400", async () => {
  assert.equal((await call("GET /events/{eventId}", "nope")).statusCode, 404);
  assert.equal((await call("GET /events/{eventId}", "Bad_ID!")).statusCode, 400);
  assert.equal((await call("GET /events/{eventId}", undefined)).statusCode, 400);
});

test("a repository failure returns a clean 500, not a crash", async () => {
  const broken: TicketingRepo = {
    getEvent: async () => {
      throw new Error("boom");
    },
    listSeats: async () => [],
  };
  const res = await makeReadHandler(broken)({
    routeKey: "GET /events/{eventId}",
    pathParameters: { eventId: "demo" },
  } as unknown as APIGatewayProxyEventV2);
  assert.equal(res.statusCode, 500);
  assert.equal(JSON.parse(res.body ?? "{}").error.code, "INTERNAL");
});