import { test } from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, sign as cryptoSign } from "node:crypto";
import { AUDIENCE, ISSUER, derToJose, issueToken, verifyToken, type BuyerClaims, type DerSigner } from "./token.ts";

// A local P-256 key stands in for KMS. node:crypto signs in DER by default, exactly like KMS.
const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const other = generateKeyPairSync("ec", { namedCurve: "P-256" });
const derSigner: DerSigner = async (data) => cryptoSign("sha256", data, privateKey);

const claims = (over: Partial<BuyerClaims> = {}): BuyerClaims => ({
  iss: ISSUER,
  aud: AUDIENCE,
  sub: "buyer-1",
  iat: 1_000,
  exp: 2_800,
  jti: "token-1",
  ...over,
});

test("a token issued with a DER signer verifies (run many times to hit DER padding edge cases)", async () => {
  for (let i = 0; i < 100; i++) {
    const token = await issueToken(derSigner, claims({ jti: `t${i}` }));
    const result = verifyToken(token, publicKey, 1_500);
    assert.equal(result.ok, true, `iteration ${i}`);
  }
});

test("derToJose always produces 64 bytes", async () => {
  for (let i = 0; i < 100; i++) {
    assert.equal(derToJose(await derSigner(Buffer.from(`msg-${i}`))).length, 64);
  }
});

test("a tampered payload fails the signature check", async () => {
  const [h, , s] = (await issueToken(derSigner, claims())).split(".");
  const forged = Buffer.from(JSON.stringify(claims({ sub: "attacker" }))).toString("base64url");
  assert.deepEqual(verifyToken(`${h}.${forged}.${s}`, publicKey, 1_500), { ok: false, reason: "BAD_SIGNATURE" });
});

test("a token signed by a different key is rejected", async () => {
  const token = await issueToken(async (d) => cryptoSign("sha256", d, other.privateKey), claims());
  assert.deepEqual(verifyToken(token, publicKey, 1_500), { ok: false, reason: "BAD_SIGNATURE" });
});

test("alg 'none' (or anything but ES256) is rejected", async () => {
  const [, p, s] = (await issueToken(derSigner, claims())).split(".");
  const none = Buffer.from(JSON.stringify({ alg: "none", typ: "JWT" })).toString("base64url");
  assert.deepEqual(verifyToken(`${none}.${p}.${s}`, publicKey, 1_500), { ok: false, reason: "BAD_ALGORITHM" });
});

test("expired and not-yet-valid tokens are rejected (with 30 s clock skew)", async () => {
  const token = await issueToken(derSigner, claims({ iat: 1_000, exp: 2_800 }));
  assert.equal(verifyToken(token, publicKey, 2_820).ok, true); // within skew
  assert.deepEqual(verifyToken(token, publicKey, 2_900), { ok: false, reason: "EXPIRED" });
  assert.deepEqual(verifyToken(token, publicKey, 900), { ok: false, reason: "NOT_YET_VALID" });
});

test("wrong issuer or audience is rejected", async () => {
  assert.deepEqual(verifyToken(await issueToken(derSigner, claims({ aud: "someone-else" })), publicKey, 1_500), {
    ok: false,
    reason: "BAD_CLAIMS",
  });
  assert.deepEqual(verifyToken(await issueToken(derSigner, claims({ iss: "evil" })), publicKey, 1_500), {
    ok: false,
    reason: "BAD_CLAIMS",
  });
});

test("garbage is MALFORMED, not a crash", () => {
  for (const bad of ["", "abc", "a.b", "a..c", "!!!.???.###"]) {
    assert.deepEqual(verifyToken(bad, publicKey, 1_500), { ok: false, reason: "MALFORMED" }, bad);
  }
});