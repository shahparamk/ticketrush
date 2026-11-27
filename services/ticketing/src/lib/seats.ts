export type SeatStatus = "available" | "held" | "sold";

// A seat as stored in DynamoDB
export interface SeatItem {
  eventId: string;
  seatId: string;
  row: string;
  number: number;
  status: SeatStatus;
  holderId?: string;
  holdId?: string;
  holdExpiresAt?: number; // epoch seconds
  version: number;
}

// A seat as shown to buyers: never reveals who holds it
export interface PublicSeat {
  seatId: string;
  row: string;
  number: number;
  status: SeatStatus;
}

export interface SeatSummary {
  total: number;
  available: number;
  held: number;
  sold: number;
}

export const MAX_ROWS = 26; // rows are lettered A-Z
export const MAX_SEATS_PER_ROW = 50;

// Rows A, B, C... with seats 01, 02, ... -> seat IDs like "A01"
export function seatLayout(rows: number, seatsPerRow: number): Array<Pick<SeatItem, "seatId" | "row" | "number">> {
  if (!Number.isInteger(rows) || rows < 1 || rows > MAX_ROWS) {
    throw new RangeError(`rows must be an integer from 1 to ${MAX_ROWS}`);
  }
  if (!Number.isInteger(seatsPerRow) || seatsPerRow < 1 || seatsPerRow > MAX_SEATS_PER_ROW) {
    throw new RangeError(`seatsPerRow must be an integer from 1 to ${MAX_SEATS_PER_ROW}`);
  }
  const seats: Array<Pick<SeatItem, "seatId" | "row" | "number">> = [];
  for (let r = 0; r < rows; r++) {
    const row = String.fromCharCode(65 + r);
    for (let n = 1; n <= seatsPerRow; n++) {
      seats.push({ seatId: `${row}${String(n).padStart(2, "0")}`, row, number: n });
    }
  }
  return seats;
}

// "Lazy expiry": a hold past its expiry time counts as available, so no cleanup job is needed
export function effectiveStatus(seat: SeatItem, nowSeconds: number): SeatStatus {
  if (seat.status === "held" && (seat.holdExpiresAt ?? 0) <= nowSeconds) {
    return "available";
  }
  return seat.status;
}

export function toPublicSeat(seat: SeatItem, nowSeconds: number): PublicSeat {
  return { seatId: seat.seatId, row: seat.row, number: seat.number, status: effectiveStatus(seat, nowSeconds) };
}

export function summarize(seats: PublicSeat[]): SeatSummary {
  const summary: SeatSummary = { total: seats.length, available: 0, held: 0, sold: 0 };
  for (const seat of seats) {
    summary[seat.status] += 1;
  }
  return summary;
}