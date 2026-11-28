import { test } from "node:test";
import assert from "node:assert/strict";
import { makeHoldHandler } from "./hold.ts";
import type { BuyerItem, HoldRepo, HoldTx, IdempotencyItem, ReleaseTx, TxResult } from "../lib/hold-repository.ts";
import type { SeatItem } from "../lib/seats.ts";

// In-memory stand-in for DynamoDB. Each transaction checks ALL its conditions and applies them in one
// synchronous step (no await in between), so it is atomic exactly like a DynamoDB transaction.
class FakeHoldRepo implements HoldRepo {
  seats = new Map<string, SeatItem>();
  buyers = new Map<string, BuyerItem>();
  idem = new Map<string, IdempotencyItem>();

  constructor(eventId: string, seatIds: string[]) {
    for (const seatId of seatIds) {
      this.seats.set(`${eventId}|${seatId}`, {
        eventId,
        seatId,
        row: seatId[0] ?? "A",
        number: Number(seatId.slice(1)),
        status: "available",
        version: 0,
      });
    }
  }

  async getIdempotency(key: string) {
    return this.idem.get(key);
  }
  async getBuyer(eventId: string, buyerId: string) {
    const b = this.buyers.get(`${eventId}|${buyerId}`);
    return b ? structuredClone(b) : undefined;
  }
  async getSeat(eventId: string, seatId: string) {
    return this.seats.get(`${eventId}|${seatId}`);
  }

  async holdSeat(tx: HoldTx): Promise<TxResult> {
    const seat = this.seats.get(`${tx.eventId}|${tx.seatId}`);
    const buyer = this.buyers.get(`${tx.eventId}|${tx.buyerId}`);
    if (this.idem.has(tx.idempotency.idempotencyKey)) return { ok: false, failed: "IDEMPOTENCY" };
    const seatOk =
      !!seat && (seat.status === "available" || (seat.status === "held" && (seat.holdExpiresAt ?? 0) <= tx.nowSeconds));
    if (!seatOk) return { ok: false, failed: "SEAT" };
    const buyerOk = tx.buyerVersion === undefined ? !buyer : buyer?.version === tx.buyerVersion;
    if (!buyerOk) return { ok: false, failed: "BUYER" };

    Object.assign(seat, { status: "held", holderId: tx.buyerId, holdId: tx.holdId, holdExpiresAt: tx.expiresAt, version: seat.version + 1 });
    this.buyers.set(`${tx.eventId}|${tx.buyerId}`, {
      eventId: tx.eventId,
      buyerId: tx.buyerId,
      holds: tx.newHolds,
      version: (buyer?.version ?? 0) + 1,
    });
    this.idem.set(tx.idempotency.idempotencyKey, tx.idempotency);
    return { ok: true };
  }

  async releaseSeat(tx: ReleaseTx): Promise<TxResult> {
    const seat = this.seats.get(`${tx.eventId}|${tx.seatId}`);
    const buyer = this.buyers.get(`${tx.eventId}|${tx.buyerId}`);
    if (!seat || seat.status !== "held" || seat.holderId !== tx.buyerId) return { ok: false, failed: "SEAT" };
    if (buyer?.version !== tx.buyerVersion) return { ok: false, failed: "BUYER" };
    seat.status = "available";
    delete seat.holderId;
    delete seat.holdId;
    delete seat.holdExpiresAt;
    seat.version += 1;
    this.buyers.set(`${tx.eventId}|${tx.buyerId}`, { ...buyer, holds: tx.newHolds, version: buyer.version + 1 });
    return { ok: true };
  }
}

const SEATS = ["A01", "A02", "A03", "A04", "A05", "A06"];
let clock = 1_000;
let ids = 0;

function setup(regionRole = "primary") {
  const repo = new FakeHoldRepo("demo", SEATS);
  const handler = makeHoldHandler({
    repo,
    now: () => clock,
    newId: () => `hold-${++ids}`,
    sleep: async () => {},
    regionRole: () => regionRole,
  });
  const call = (method: "POST" | "DELETE", seatId: string, buyerId: string, key?: string) =>
    handler({
      routeKey: `${method} /events/{eventId}/seats/{seatId}/hold`,
      pathParameters: { eventId: "demo", seatId },
      headers: key ? { "idempotency-key": key } : {},
      requestContext: { authorizer: { lambda: { buyerId, tokenId: "t" } } },
    } as unknown as Parameters<typeof handler>[0]);
  return { repo, call };
}

const code = (res: { body?: string }) => JSON.parse(res.body ?? "{}").error?.code;

test("a buyer can hold an available seat", async () => {
  const { repo, call } = setup();
  const res = await call("POST", "A01", "buyer-1", "key-00001");
  assert.equal(res.statusCode, 201);
  assert.equal(repo.seats.get("demo|A01")?.holderId, "buyer-1");
});

test("50 buyers racing for ONE seat: exactly 1 wins, 49 get SEAT_TAKEN", async () => {
  const { repo, call } = setup();
  const results = await Promise.all(
    Array.from({ length: 50 }, (_, i) => call("POST", "A02", `buyer-${i}`, `race-key-${i}`)),
  );
  assert.equal(results.filter((r) => r.statusCode === 201).length, 1);
  assert.equal(results.filter((r) => code(r) === "SEAT_TAKEN").length, 49);
  assert.equal(repo.seats.get("demo|A02")?.status, "held");
});

test("one buyer firing 6 parallel holds gets at most 4 (the limit holds under concurrency)", async () => {
  const { repo, call } = setup();
  const results = await Promise.all(SEATS.map((s, i) => call("POST", s, "greedy", `greedy-key-${i}`)));
  assert.equal(results.filter((r) => r.statusCode === 201).length, 4);
  assert.equal(results.filter((r) => code(r) === "HOLD_LIMIT_REACHED").length, 2);
  assert.equal([...repo.seats.values()].filter((s) => s.holderId === "greedy").length, 4);
});

test("the same Idempotency-Key replays the original answer and never holds twice", async () => {
  const { repo, call } = setup();
  const first = await call("POST", "A03", "buyer-1", "same-key-1");
  const again = await call("POST", "A03", "buyer-1", "same-key-1");
  assert.equal(again.statusCode, 201);
  assert.equal(again.body, first.body);
  assert.equal(again.headers?.["idempotent-replayed"], "true");
  assert.equal(repo.seats.get("demo|A03")?.version, 1); // written once
});

test("reusing an Idempotency-Key for a different seat is rejected (422)", async () => {
  const { call } = setup();
  await call("POST", "A01", "buyer-1", "reused-key");
  const res = await call("POST", "A02", "buyer-1", "reused-key");
  assert.equal(res.statusCode, 422);
  assert.equal(code(res), "IDEMPOTENCY_KEY_REUSED");
});

test("a missing or malformed Idempotency-Key is a 400", async () => {
  const { call } = setup();
  assert.equal(code(await call("POST", "A01", "buyer-1")), "IDEMPOTENCY_KEY_REQUIRED");
  assert.equal(code(await call("POST", "A01", "buyer-1", "short")), "IDEMPOTENCY_KEY_REQUIRED");
});

test("an expired hold can be taken by someone else, and stops counting against the limit", async () => {
  const { repo, call } = setup();
  clock = 1_000;
  await call("POST", "A04", "buyer-1", "exp-key-01");
  assert.equal(code(await call("POST", "A04", "buyer-2", "exp-key-02")), "SEAT_TAKEN");
  clock = 1_000 + 301; // 5 minutes + 1 second later
  const res = await call("POST", "A04", "buyer-2", "exp-key-03");
  assert.equal(res.statusCode, 201);
  assert.equal(repo.seats.get("demo|A04")?.holderId, "buyer-2");
  clock = 1_000;
});

test("holding a seat you already hold says so", async () => {
  const { call } = setup();
  await call("POST", "A05", "buyer-1", "mine-key-1");
  assert.equal(code(await call("POST", "A05", "buyer-1", "mine-key-2")), "ALREADY_HELD_BY_YOU");
});

test("only the holder can release; then the seat is available again", async () => {
  const { repo, call } = setup();
  await call("POST", "A06", "buyer-1", "rel-key-01");
  assert.equal(code(await call("DELETE", "A06", "buyer-2")), "NOT_HELD_BY_YOU");
  const res = await call("DELETE", "A06", "buyer-1");
  assert.equal(res.statusCode, 200);
  assert.equal(repo.seats.get("demo|A06")?.status, "available");
  assert.equal(repo.seats.get("demo|A06")?.holderId, undefined);
});

test("unknown seats are 404; bad seat IDs are 400", async () => {
  const { call } = setup();
  assert.equal(code(await call("POST", "Z99", "buyer-1", "missing-key")), "SEAT_NOT_FOUND");
  assert.equal(code(await call("POST", "a1", "buyer-1", "badid-key-1")), "BAD_SEAT_ID");
});

test("the standby region refuses writes (503)", async () => {
  const { call } = setup("standby");
  const res = await call("POST", "A01", "buyer-1", "standby-key");
  assert.equal(res.statusCode, 503);
  assert.equal(code(res), "READ_ONLY_STANDBY");
});