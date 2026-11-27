// Creates (or resets) an event and all its seats as "available".
// Usage: npm run seed -- <eventId> [rows] [seatsPerRow]
// Writes to the PRIMARY region only; Global Tables replicate to us-west-2 on their own.
// Re-running it resets every seat, which is handy for resetting a demo.
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { BatchWriteCommand, DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";
import { seatLayout } from "../src/lib/seats.ts";

const [eventId = "demo-boston", rowsArg = "10", perRowArg = "10"] = process.argv.slice(2);
if (!/^[a-z0-9-]{1,64}$/.test(eventId)) {
  throw new Error("eventId must be 1-64 lowercase letters, digits or dashes");
}

const rows = Number(rowsArg);
const seatsPerRow = Number(perRowArg);
const layout = seatLayout(rows, seatsPerRow); // validates the numbers too

const region = "us-east-1";
const tables = { events: "ticketrush-dev-events", seats: "ticketrush-dev-seats" };
const doc = DynamoDBDocumentClient.from(new DynamoDBClient({ region }));

const startsAt = new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString();
await doc.send(
  new PutCommand({
    TableName: tables.events,
    Item: {
      eventId,
      name: "TicketRush Demo Concert",
      venue: "Boston, MA",
      startsAt,
      rows,
      seatsPerRow,
      seatCount: layout.length,
      priceCents: 7500,
      createdAt: new Date().toISOString(),
    },
  }),
);

// BatchWrite takes at most 25 items per request; retry anything DynamoDB couldn't process
let written = 0;
for (let i = 0; i < layout.length; i += 25) {
  let requests: NonNullable<ConstructorParameters<typeof BatchWriteCommand>[0]["RequestItems"]>[string] = layout
    .slice(i, i + 25)
    .map((s) => ({ PutRequest: { Item: { eventId, ...s, status: "available", version: 0 } } }));

  for (let attempt = 0; requests.length > 0; attempt++) {
    if (attempt > 5) throw new Error("DynamoDB kept returning unprocessed items");
    if (attempt > 0) await new Promise((r) => setTimeout(r, 200 * 2 ** attempt));
    const res = await doc.send(new BatchWriteCommand({ RequestItems: { [tables.seats]: requests } }));
    written += requests.length - (res.UnprocessedItems?.[tables.seats]?.length ?? 0);
    requests = res.UnprocessedItems?.[tables.seats] ?? [];
  }
}

console.log(`Seeded ${eventId}: ${layout.length} seats (${rows} rows x ${seatsPerRow}) in ${region}; wrote ${written} items.`);