import { test } from "node:test";
import assert from "node:assert/strict";
import { effectiveStatus, seatLayout, summarize, toPublicSeat, type SeatItem } from "./seats.ts";

const seat = (over: Partial<SeatItem> = {}): SeatItem => ({
  eventId: "e",
  seatId: "A01",
  row: "A",
  number: 1,
  status: "available",
  version: 0,
  ...over,
});

test("seatLayout builds rows A.. with zero-padded seat numbers", () => {
  const seats = seatLayout(2, 3);
  assert.deepEqual(
    seats.map((s) => s.seatId),
    ["A01", "A02", "A03", "B01", "B02", "B03"],
  );
});

test("seatLayout rejects impossible layouts", () => {
  assert.throws(() => seatLayout(0, 10), RangeError);
  assert.throws(() => seatLayout(27, 10), RangeError);
  assert.throws(() => seatLayout(10, 1.5), RangeError);
});

test("an expired hold counts as available; an active hold stays held", () => {
  const now = 1_000;
  assert.equal(effectiveStatus(seat({ status: "held", holdExpiresAt: 999 }), now), "available");
  assert.equal(effectiveStatus(seat({ status: "held", holdExpiresAt: 1_000 }), now), "available");
  assert.equal(effectiveStatus(seat({ status: "held", holdExpiresAt: 1_001 }), now), "held");
  assert.equal(effectiveStatus(seat({ status: "sold" }), now), "sold");
});

test("the public view never exposes who holds a seat", () => {
  const pub = toPublicSeat(seat({ status: "held", holderId: "buyer-1", holdId: "h1", holdExpiresAt: 9_999 }), 1);
  assert.deepEqual(Object.keys(pub).sort(), ["number", "row", "seatId", "status"]);
  assert.equal(pub.status, "held");
});

test("summarize counts each status", () => {
  const summary = summarize([
    { seatId: "A01", row: "A", number: 1, status: "available" },
    { seatId: "A02", row: "A", number: 2, status: "held" },
    { seatId: "A03", row: "A", number: 3, status: "sold" },
    { seatId: "A04", row: "A", number: 4, status: "available" },
  ]);
  assert.deepEqual(summary, { total: 4, available: 2, held: 1, sold: 1 });
});