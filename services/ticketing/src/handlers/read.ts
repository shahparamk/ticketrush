import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2 } from "aws-lambda";
import { error, json } from "../lib/http.ts";
import { DynamoTicketingRepo, type EventItem, type TicketingRepo } from "../lib/repository.ts";
import { summarize, toPublicSeat } from "../lib/seats.ts";

const EVENT_ID = /^[a-z0-9-]{1,64}$/;
const nowSeconds = (): number => Math.floor(Date.now() / 1000);

function publicEvent(e: EventItem) {
  return {
    eventId: e.eventId,
    name: e.name,
    venue: e.venue,
    startsAt: e.startsAt,
    seatCount: e.seatCount,
    priceCents: e.priceCents,
  };
}

// Built from a repository, so tests can use an in-memory fake instead of DynamoDB
export function makeReadHandler(repo: TicketingRepo, now: () => number = nowSeconds) {
  return async (event: APIGatewayProxyEventV2): Promise<APIGatewayProxyStructuredResultV2> => {
    const region = process.env.AWS_REGION ?? "unknown";
    const eventId = event.pathParameters?.eventId ?? "";
    if (!EVENT_ID.test(eventId)) {
      return error(400, "BAD_EVENT_ID", "eventId must be 1-64 lowercase letters, digits or dashes");
    }

    try {
      const found = await repo.getEvent(eventId);
      if (!found) {
        return error(404, "EVENT_NOT_FOUND", `No event ${eventId}`);
      }

      switch (event.routeKey) {
        case "GET /events/{eventId}":
          return json(200, { region, event: publicEvent(found) });

        case "GET /events/{eventId}/seats": {
          const t = now();
          const seats = (await repo.listSeats(eventId)).map((s) => toPublicSeat(s, t));
          return json(200, { region, eventId, summary: summarize(seats), seats });
        }

        default:
          return error(404, "ROUTE_NOT_FOUND", `No route ${event.routeKey}`);
      }
    } catch (err) {
      console.error(JSON.stringify({ msg: "read failed", eventId, error: String(err) }));
      return error(500, "INTERNAL", "Something went wrong");
    }
  };
}

export const handler = makeReadHandler(
  new DynamoTicketingRepo({
    events: process.env.EVENTS_TABLE ?? "",
    seats: process.env.SEATS_TABLE ?? "",
  }),
);