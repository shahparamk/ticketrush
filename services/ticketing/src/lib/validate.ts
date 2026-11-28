// Input formats accepted by the API (anything else is a 400 before touching the database)
export const EVENT_ID = /^[a-z0-9-]{1,64}$/;
export const SEAT_ID = /^[A-Z][0-9]{2}$/; // e.g. A01
export const IDEMPOTENCY_KEY = /^[A-Za-z0-9_-]{8,64}$/;