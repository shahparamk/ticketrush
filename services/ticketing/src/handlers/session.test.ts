import { test } from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, sign as cryptoSign } from "node:crypto";
import { makeSessionHandler } from "./session.ts";
import { verifyToken, type DerSigner } from "../lib/token.ts";

const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const derSigner: DerSigner = async (data) => cryptoSign("sha256", data, privateKey);
const handler = makeSessionHandler(derSigner, () => 10_000);

const call = (event: unknown) => handler(event as Parameters<typeof handler>[0]);

test("POST /session returns 201 with a verifiable token for a new buyer", async () => {
  const res = await call({ routeKey: "POST /session", requestContext: {} });
  assert.equal(res.statusCode, 201);
  const body = JSON.parse(res.body ?? "{}");
  const result = verifyToken(body.token, publicKey, 10_000);
  assert.equal(result.ok, true);
  assert.equal(result.ok && result.claims.sub, body.buyerId);
  assert.equal(body.expiresAt, 10_000 + 1_800);
});

test("GET /me returns the buyer from the authorizer context", async () => {
  const res = await call({
    routeKey: "GET /me",
    requestContext: { authorizer: { lambda: { buyerId: "buyer-42", tokenId: "t" } } },
  });
  assert.equal(res.statusCode, 200);
  assert.equal(JSON.parse(res.body ?? "{}").buyerId, "buyer-42");
});

test("GET /me without an authorizer context is 401; unknown routes are 404", async () => {
  assert.equal((await call({ routeKey: "GET /me", requestContext: {} })).statusCode, 401);
  assert.equal((await call({ routeKey: "GET /nope", requestContext: {} })).statusCode, 404);
});

test("a signing failure returns a clean 500", async () => {
  const broken = makeSessionHandler(async () => {
    throw new Error("KMS down");
  });
  const res = await broken({ routeKey: "POST /session", requestContext: {} } as unknown as Parameters<typeof broken>[0]);
  assert.equal(res.statusCode, 500);
});