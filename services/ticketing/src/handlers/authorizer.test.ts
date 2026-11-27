import { test } from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, sign as cryptoSign } from "node:crypto";
import { makeAuthorizer } from "./authorizer.ts";
import { AUDIENCE, ISSUER, issueToken, type DerSigner } from "../lib/token.ts";

const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const derSigner: DerSigner = async (data) => cryptoSign("sha256", data, privateKey);
const authorize = makeAuthorizer(async () => publicKey, () => 1_500);

const event = (authorization?: string) => ({ headers: authorization ? { authorization } : {} }) as unknown as Parameters<typeof authorize>[0];
const token = (exp = 2_800) => issueToken(derSigner, { iss: ISSUER, aud: AUDIENCE, sub: "buyer-7", iat: 1_000, exp, jti: "tok-7" });

test("a valid bearer token is authorized, with the buyer in the context", async () => {
  const res = await authorize(event(`Bearer ${await token()}`));
  assert.equal(res.isAuthorized, true);
  assert.deepEqual("context" in res ? res.context : undefined, { buyerId: "buyer-7", tokenId: "tok-7" });
});

test("missing, non-bearer, expired, or garbage tokens are denied", async () => {
  assert.equal((await authorize(event())).isAuthorized, false);
  assert.equal((await authorize(event(`Basic ${await token()}`))).isAuthorized, false);
  assert.equal((await authorize(event(`Bearer ${await token(1_000)}`))).isAuthorized, false);
  assert.equal((await authorize(event("Bearer not.a.token"))).isAuthorized, false);
});

test("if the public key can't be loaded, the authorizer fails closed", async () => {
  const broken = makeAuthorizer(async () => {
    throw new Error("KMS unreachable");
  });
  assert.equal((await broken(event(`Bearer ${await token()}`))).isAuthorized, false);
});