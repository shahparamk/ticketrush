// Contention test ("the rush"): N buyers try to hold seats of one event at the same moment,
// then every "you got it" answer is checked against the seats table itself.
// Usage: npm run rush -- <apiBaseUrl> [eventId=rush-test] [buyers=1000]
import { performance } from "node:perf_hooks";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, QueryCommand } from "@aws-sdk/lib-dynamodb";

interface Buyer {
  buyerId: string;
  token: string;
}
interface Win {
  buyerId: string;
  seatId: string;
  holdId: string;
}
interface ApiBody {
  token?: string;
  buyerId?: string;
  holdId?: string;
  seats?: Array<{ seatId: string; status: string }>;
  error?: { code?: string };
}
interface SeatRow {
  seatId: string;
  status: string;
  holderId?: string;
  holdId?: string;
  holdExpiresAt?: number;
}

const [baseUrlArg, eventId = "rush-test", buyersArg = "1000"] = process.argv.slice(2);
if (!baseUrlArg?.startsWith("https://")) {
  console.error("Usage: npm run rush -- <apiBaseUrl> [eventId] [buyers]");
  process.exit(1);
}
const baseUrl = baseUrlArg.replace(/\/$/, "");
const BUYERS = Number(buyersArg);
const SEAT_TRIES = 10; // different seats one buyer tries before giving up
const RETRIES = 6; // retries of ONE request on 429 / 5xx / network error (same Idempotency-Key every time)
const SEATS_TABLE = "ticketrush-dev-seats";

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
const backoff = (attempt: number) => sleep(100 * 2 ** attempt + Math.random() * 100);
const pct = (sorted: number[], p: number): number =>
  sorted.length ? (sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))] ?? 0) : 0;

// status 0 = the request never got an HTTP answer (connection reset, timeout): retried like a 5xx
async function call(path: string, init: RequestInit = {}): Promise<{ status: number; body: ApiBody; ms: number }> {
  const start = performance.now();
  try {
    const res = await fetch(`${baseUrl}${path}`, init);
    const body = (await res.json().catch(() => ({}))) as ApiBody;
    return { status: res.status, body, ms: performance.now() - start };
  } catch {
    return { status: 0, body: {}, ms: performance.now() - start };
  }
}

// 1. The seats on sale
const map = await call(`/events/${eventId}/seats`);
if (map.status !== 200 || !map.body.seats) {
  console.error(`Can't read event ${eventId} (HTTP ${map.status}). Seed it first: npm run seed -- ${eventId} 10 10`);
  process.exit(1);
}
const seatIds = map.body.seats.map((s) => s.seatId);
const available = map.body.seats.filter((s) => s.status === "available").length;
console.log(`Event ${eventId}: ${seatIds.length} seats, ${available} available. Buyers: ${BUYERS}`);
if (available !== seatIds.length) console.warn("Warning: not every seat is available; re-seed for a clean run.");

// 2. One token per buyer, created in batches so the session route isn't throttled
console.log("Creating buyer sessions...");
const buyers: Buyer[] = [];
for (let i = 0; i < BUYERS; i += 50) {
  const batch = await Promise.all(
    Array.from({ length: Math.min(50, BUYERS - i) }, async (): Promise<Buyer> => {
      for (let a = 0; a <= RETRIES; a++) {
        const r = await call("/session", { method: "POST" });
        if (r.status === 201 && r.body.token && r.body.buyerId) return { buyerId: r.body.buyerId, token: r.body.token };
        await backoff(a);
      }
      throw new Error("Could not create a session");
    }),
  );
  buyers.push(...batch);
}
console.log(`${buyers.length} buyers ready. GO!`);

// 3. The rush: every buyer starts at the same moment
const stats = {
  requests: 0,
  won: 0,
  taken: 0,
  soldOut: 0,
  alreadyMine: 0,
  throttled429: 0,
  busy5xx: 0,
  network: 0,
  unexpected: 0,
  noSeat: 0,
};
const latencies: number[] = [];
const wins: Win[] = [];

async function rush(b: Buyer): Promise<void> {
  const tried = new Set<string>();
  for (let s = 0; s < SEAT_TRIES; s++) {
    const options = seatIds.filter((id) => !tried.has(id));
    const seatId = options[Math.floor(Math.random() * options.length)];
    if (!seatId) break;
    tried.add(seatId);
    const key = `rush-${b.buyerId.slice(0, 8)}-${seatId}`; // the SAME key on every retry of this request

    for (let a = 0; a <= RETRIES; a++) {
      const r = await call(`/events/${eventId}/seats/${seatId}/hold`, {
        method: "POST",
        headers: { authorization: `Bearer ${b.token}`, "idempotency-key": key },
      });
      stats.requests++;
      latencies.push(r.ms);
      if (r.status === 201) {
        stats.won++;
        wins.push({ buyerId: b.buyerId, seatId, holdId: r.body.holdId ?? "" });
        return;
      }
      if (r.status === 409) {
        const errorCode = r.body.error?.code;
        if (errorCode === "SOLD_OUT") {
          stats.soldOut++; // nothing left: stop trying altogether
          stats.noSeat++;
          return;
        }
        if (errorCode === "ALREADY_HELD_BY_YOU") stats.alreadyMine++;
        else stats.taken++;
        break; // try a different seat
      }
      if (r.status === 429) stats.throttled429++;
      else if (r.status >= 500) stats.busy5xx++;
      else if (r.status === 0) stats.network++;
      else {
        stats.unexpected++;
        console.error(`Unexpected HTTP ${r.status}: ${JSON.stringify(r.body)}`);
        return;
      }
      await backoff(a); // then retry the SAME request
    }
  }
  stats.noSeat++;
}

const t0 = performance.now();
await Promise.all(buyers.map(rush));
const seconds = (performance.now() - t0) / 1000;

// 4. Verify against the table itself (strongly consistent read in the primary region)
const now = Math.floor(Date.now() / 1000);
async function heldSeats(region: string, consistent: boolean): Promise<Map<string, SeatRow>> {
  const doc = DynamoDBDocumentClient.from(new DynamoDBClient({ region }));
  const held = new Map<string, SeatRow>();
  let start: Record<string, unknown> | undefined;
  do {
    const page = await doc.send(
      new QueryCommand({
        TableName: SEATS_TABLE,
        KeyConditionExpression: "eventId = :e",
        ExpressionAttributeValues: { ":e": eventId },
        ConsistentRead: consistent,
        ExclusiveStartKey: start,
      }),
    );
    for (const item of (page.Items ?? []) as SeatRow[]) {
      if (item.status === "held" && (item.holdExpiresAt ?? 0) > now) held.set(item.seatId, item);
    }
    start = page.LastEvaluatedKey;
  } while (start);
  return held;
}

const table = await heldSeats("us-east-1", true);
const winsPerSeat = new Map<string, number>();
for (const w of wins) winsPerSeat.set(w.seatId, (winsPerSeat.get(w.seatId) ?? 0) + 1);
const oversold = [...winsPerSeat.values()].filter((n) => n > 1).length;
const mismatches = wins.filter((w) => {
  const seat = table.get(w.seatId);
  return !seat || seat.holderId !== w.buyerId || seat.holdId !== w.holdId;
}).length;

await sleep(3000); // give Global Tables replication a moment
const replica = await heldSeats("us-west-2", false);

const sorted = [...latencies].sort((a, b) => a - b);
const pass = oversold === 0 && mismatches === 0 && wins.length === table.size && stats.unexpected === 0;

console.log(`
=== RUSH RESULTS: ${eventId} ===
Buyers ${BUYERS} | seats ${seatIds.length} | rush lasted ${seconds.toFixed(1)} s
Hold requests: ${stats.requests} (${(stats.requests / seconds).toFixed(0)}/s average)
  201 got a seat ........ ${stats.won}
  409 seat taken ........ ${stats.taken}
  409 SOLD OUT .......... ${stats.soldOut}  (buyer stopped trying)
  409 already mine ...... ${stats.alreadyMine}
  429 throttled ......... ${stats.throttled429}  (retried with the same Idempotency-Key)
  5xx busy .............. ${stats.busy5xx}  (retried with the same Idempotency-Key)
  network errors ........ ${stats.network}  (retried with the same Idempotency-Key)
  unexpected ............ ${stats.unexpected}
Buyers left without a seat: ${stats.noSeat}
Hold latency (ms): p50 ${pct(sorted, 50).toFixed(0)} | p95 ${pct(sorted, 95).toFixed(0)} | p99 ${pct(sorted, 99).toFixed(0)} | max ${pct(sorted, 100).toFixed(0)}

=== VERIFIED AGAINST THE TABLE ===
Held seats in the us-east-1 table ............ ${table.size} / ${seatIds.length}
"You got it" answers matching the table ...... ${wins.length - mismatches} / ${wins.length}
Seats with two "winners" (OVERSOLD) .......... ${oversold}
Held seats in the us-west-2 replica (3 s) .... ${replica.size}

VERDICT: ${pass ? "PASS: no seat oversold, every 201 matches the table" : "FAIL"}
`);
process.exit(pass ? 0 : 1);