import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  GetCommand,
  QueryCommand,
  TransactWriteCommand,
  type TransactWriteCommandInput,
} from "@aws-sdk/lib-dynamodb";
import type { BuyerHolds } from "./holds.ts";
import type { SeatItem } from "./seats.ts";

export interface BuyerItem {
  eventId: string;
  buyerId: string;
  holds?: BuyerHolds;
  version: number;
}

export interface IdempotencyItem {
  idempotencyKey: string; // "<buyerId>#<Idempotency-Key header>"
  requestHash: string;
  statusCode: number;
  body: string;
  expiresAt: number; // TTL
}

// Which part of a transaction failed its condition ("CONFLICT" = another transaction touched an item; retry)
export type TxFailure = "SEAT" | "BUYER" | "IDEMPOTENCY" | "CONFLICT";
export type TxResult = { ok: true } | { ok: false; failed: TxFailure };

export interface HoldTx {
  eventId: string;
  seatId: string;
  buyerId: string;
  holdId: string;
  nowSeconds: number;
  expiresAt: number;
  buyerVersion: number | undefined; // undefined = the buyer record doesn't exist yet
  newHolds: BuyerHolds;
  buyerTtl: number;
  idempotency: IdempotencyItem;
}

export interface ReleaseTx {
  eventId: string;
  seatId: string;
  buyerId: string;
  buyerVersion: number;
  newHolds: BuyerHolds;
}

export interface HoldRepo {
  getIdempotency(key: string): Promise<IdempotencyItem | undefined>;
  getBuyer(eventId: string, buyerId: string): Promise<BuyerItem | undefined>;
  getSeat(eventId: string, seatId: string): Promise<SeatItem | undefined>;
  // Seats that can still be held right now: available, or held with an expired hold
  countAvailable(eventId: string, nowSeconds: number): Promise<number>;
  holdSeat(tx: HoldTx): Promise<TxResult>;
  releaseSeat(tx: ReleaseTx): Promise<TxResult>;
}

export interface HoldTables {
  seats: string;
  buyers: string;
  idempotency: string;
}

type TransactItems = NonNullable<TransactWriteCommandInput["TransactItems"]>;

export class DynamoHoldRepo implements HoldRepo {
  private readonly doc: DynamoDBDocumentClient;
  private readonly tables: HoldTables;

  constructor(tables: HoldTables, client: DynamoDBClient = new DynamoDBClient({})) {
    this.tables = tables;
    this.doc = DynamoDBDocumentClient.from(client, { marshallOptions: { removeUndefinedValues: true } });
  }

  async getIdempotency(key: string): Promise<IdempotencyItem | undefined> {
    const res = await this.doc.send(
      new GetCommand({ TableName: this.tables.idempotency, Key: { idempotencyKey: key }, ConsistentRead: true }),
    );
    return res.Item as IdempotencyItem | undefined;
  }

  async getBuyer(eventId: string, buyerId: string): Promise<BuyerItem | undefined> {
    const res = await this.doc.send(
      new GetCommand({ TableName: this.tables.buyers, Key: { eventId, buyerId }, ConsistentRead: true }),
    );
    return res.Item as BuyerItem | undefined;
  }

  async getSeat(eventId: string, seatId: string): Promise<SeatItem | undefined> {
    const res = await this.doc.send(
      new GetCommand({ TableName: this.tables.seats, Key: { eventId, seatId }, ConsistentRead: true }),
    );
    return res.Item as SeatItem | undefined;
  }

  // Counts only (Select COUNT): DynamoDB returns a number, not the items
  async countAvailable(eventId: string, nowSeconds: number): Promise<number> {
    let count = 0;
    let start: Record<string, unknown> | undefined;
    do {
      const res = await this.doc.send(
        new QueryCommand({
          TableName: this.tables.seats,
          KeyConditionExpression: "eventId = :e",
          FilterExpression: "#status = :available OR (#status = :held AND holdExpiresAt <= :now)",
          ExpressionAttributeNames: { "#status": "status" },
          ExpressionAttributeValues: { ":e": eventId, ":available": "available", ":held": "held", ":now": nowSeconds },
          Select: "COUNT",
          ExclusiveStartKey: start,
        }),
      );
      count += res.Count ?? 0;
      start = res.LastEvaluatedKey;
    } while (start);
    return count;
  }

  // One all-or-nothing transaction: seat + buyer record + idempotency record
  async holdSeat(tx: HoldTx): Promise<TxResult> {
    const items: TransactItems = [
      {
        // THE no-overselling guarantee: only an available seat (or one whose hold expired) can be held
        Update: {
          TableName: this.tables.seats,
          Key: { eventId: tx.eventId, seatId: tx.seatId },
          UpdateExpression:
            "SET #status = :held, holderId = :buyer, holdId = :hold, holdExpiresAt = :exp ADD version :one",
          ConditionExpression:
            "attribute_exists(seatId) AND (#status = :available OR (#status = :held AND holdExpiresAt <= :now))",
          ExpressionAttributeNames: { "#status": "status" },
          ExpressionAttributeValues: {
            ":held": "held",
            ":available": "available",
            ":buyer": tx.buyerId,
            ":hold": tx.holdId,
            ":exp": tx.expiresAt,
            ":now": tx.nowSeconds,
            ":one": 1,
          },
        },
      },
      {
        // Optimistic lock: the buyer record must be exactly as we read it (stops parallel requests beating the limit)
        Update: {
          TableName: this.tables.buyers,
          Key: { eventId: tx.eventId, buyerId: tx.buyerId },
          UpdateExpression: "SET holds = :holds, expiresAt = :ttl ADD version :one",
          ConditionExpression: tx.buyerVersion === undefined ? "attribute_not_exists(buyerId)" : "version = :v",
          ExpressionAttributeValues: {
            ":holds": tx.newHolds,
            ":ttl": tx.buyerTtl,
            ":one": 1,
            ...(tx.buyerVersion === undefined ? {} : { ":v": tx.buyerVersion }),
          },
        },
      },
      {
        // The stored answer for this Idempotency-Key (only if the key is new)
        Put: {
          TableName: this.tables.idempotency,
          Item: tx.idempotency,
          ConditionExpression: "attribute_not_exists(idempotencyKey)",
        },
      },
    ];
    return this.transact(items, ["SEAT", "BUYER", "IDEMPOTENCY"]);
  }

  async releaseSeat(tx: ReleaseTx): Promise<TxResult> {
    const items: TransactItems = [
      {
        // Only the current holder can release
        Update: {
          TableName: this.tables.seats,
          Key: { eventId: tx.eventId, seatId: tx.seatId },
          UpdateExpression: "SET #status = :available REMOVE holderId, holdId, holdExpiresAt ADD version :one",
          ConditionExpression: "#status = :held AND holderId = :buyer",
          ExpressionAttributeNames: { "#status": "status" },
          ExpressionAttributeValues: { ":held": "held", ":available": "available", ":buyer": tx.buyerId, ":one": 1 },
        },
      },
      {
        Update: {
          TableName: this.tables.buyers,
          Key: { eventId: tx.eventId, buyerId: tx.buyerId },
          UpdateExpression: "SET holds = :holds ADD version :one",
          ConditionExpression: "version = :v",
          ExpressionAttributeValues: { ":holds": tx.newHolds, ":one": 1, ":v": tx.buyerVersion },
        },
      },
    ];
    return this.transact(items, ["SEAT", "BUYER"]);
  }

  private async transact(items: TransactItems, labels: TxFailure[]): Promise<TxResult> {
    try {
      await this.doc.send(new TransactWriteCommand({ TransactItems: items }));
      return { ok: true };
    } catch (err) {
      const e = err as { name?: string; CancellationReasons?: Array<{ Code?: string }> };
      if (e.name !== "TransactionCanceledException") throw err;
      const reasons = e.CancellationReasons ?? [];
      // Most meaningful first: a replayed key, then a taken seat, then a concurrent buyer change
      for (const label of ["IDEMPOTENCY", "SEAT", "BUYER"] as const) {
        const i = labels.indexOf(label);
        if (i >= 0 && reasons[i]?.Code === "ConditionalCheckFailed") return { ok: false, failed: label };
      }
      // e.g. "TransactionConflict": another transaction was touching the same item; safe to retry
      return { ok: false, failed: "CONFLICT" };
    }
  }
}