import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import type { SeatItem } from "./seats.ts";

export interface EventItem {
  eventId: string;
  name: string;
  venue: string;
  startsAt: string;
  rows: number;
  seatsPerRow: number;
  seatCount: number;
  priceCents: number;
}

// Handlers depend on this interface, so tests can pass an in-memory fake
export interface TicketingRepo {
  getEvent(eventId: string): Promise<EventItem | undefined>;
  listSeats(eventId: string): Promise<SeatItem[]>;
}

export interface TableNames {
  events: string;
  seats: string;
}

export class DynamoTicketingRepo implements TicketingRepo {
  private readonly doc: DynamoDBDocumentClient;
  private readonly tables: TableNames;

  constructor(tables: TableNames, client: DynamoDBClient = new DynamoDBClient({})) {
    this.tables = tables;
    this.doc = DynamoDBDocumentClient.from(client);
  }

  async getEvent(eventId: string): Promise<EventItem | undefined> {
    const res = await this.doc.send(
      new GetCommand({ TableName: this.tables.events, Key: { eventId }, ConsistentRead: true }),
    );
    return res.Item as EventItem | undefined;
  }

  async listSeats(eventId: string): Promise<SeatItem[]> {
    const seats: SeatItem[] = [];
    let startKey: Record<string, unknown> | undefined;
    do {
      const res = await this.doc.send(
        new QueryCommand({
          TableName: this.tables.seats,
          KeyConditionExpression: "eventId = :e",
          ExpressionAttributeValues: { ":e": eventId },
          ConsistentRead: true,
          ExclusiveStartKey: startKey,
        }),
      );
      seats.push(...((res.Items ?? []) as SeatItem[]));
      startKey = res.LastEvaluatedKey;
    } while (startKey);
    return seats;
  }
}