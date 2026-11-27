import { verify as cryptoVerify, type KeyObject } from "node:crypto";

export const ISSUER = "ticketrush";
export const AUDIENCE = "ticketrush-api";
export const TOKEN_TTL_SECONDS = 30 * 60;
export const KEY_ID = "ticketrush-dev-signing";

export interface BuyerClaims {
  iss: string;
  aud: string;
  sub: string; // the buyer ID
  iat: number; // issued at (epoch seconds)
  exp: number; // expires at (epoch seconds)
  jti: string; // unique token ID
}

// Signs bytes and returns a DER-encoded ECDSA signature (the format KMS returns)
export type DerSigner = (data: Uint8Array) => Promise<Uint8Array>;

export type VerifyFailure = "MALFORMED" | "BAD_ALGORITHM" | "BAD_SIGNATURE" | "BAD_CLAIMS" | "EXPIRED" | "NOT_YET_VALID";
export type VerifyResult = { ok: true; claims: BuyerClaims } | { ok: false; reason: VerifyFailure };

const b64url = (data: Uint8Array | string): string => Buffer.from(data).toString("base64url");
const fromB64url = (s: string): Buffer => Buffer.from(s, "base64url");
const fail = (reason: VerifyFailure): VerifyResult => ({ ok: false, reason });

// KMS signs ECDSA in DER (a SEQUENCE of two INTEGERs, r and s). JWTs (ES256) need r and s as
// two fixed 32-byte numbers side by side (64 bytes). This converts one to the other.
export function derToJose(der: Uint8Array, size = 32): Buffer {
  let i = 0;
  if (der[i++] !== 0x30) throw new Error("Not a DER signature");
  const seqLen = der[i++] ?? 0;
  if (seqLen & 0x80) i += seqLen & 0x7f; // long-form length (not expected for P-256, but tolerated)

  const readInt = (): Buffer => {
    if (der[i++] !== 0x02) throw new Error("Expected a DER INTEGER");
    const len = der[i++] ?? 0;
    let value = Buffer.from(der.subarray(i, i + len));
    i += len;
    while (value.length > size && value[0] === 0) value = value.subarray(1); // strip DER's sign-padding zero
    if (value.length > size) throw new Error("DER integer too long");
    return Buffer.concat([Buffer.alloc(size - value.length), value]); // left-pad to a fixed size
  };

  return Buffer.concat([readInt(), readInt()]);
}

export async function issueToken(sign: DerSigner, claims: BuyerClaims): Promise<string> {
  const header = b64url(JSON.stringify({ alg: "ES256", typ: "JWT", kid: KEY_ID }));
  const payload = b64url(JSON.stringify(claims));
  const signingInput = `${header}.${payload}`;
  const signature = derToJose(await sign(Buffer.from(signingInput)));
  return `${signingInput}.${b64url(signature)}`;
}

export function verifyToken(token: string, publicKey: KeyObject, nowSeconds: number, clockSkewSeconds = 30): VerifyResult {
  const parts = token.split(".");
  if (parts.length !== 3 || parts.some((p) => p.length === 0)) return fail("MALFORMED");
  const [h, p, s] = parts as [string, string, string];

  let header: { alg?: unknown };
  let claims: Partial<BuyerClaims>;
  try {
    header = JSON.parse(fromB64url(h).toString("utf8"));
    claims = JSON.parse(fromB64url(p).toString("utf8"));
  } catch {
    return fail("MALFORMED");
  }

  // Only ES256: never accept "none" or anything else the token claims for itself
  if (header.alg !== "ES256") return fail("BAD_ALGORITHM");

  const signature = fromB64url(s);
  if (signature.length !== 64) return fail("BAD_SIGNATURE");
  const valid = cryptoVerify("sha256", Buffer.from(`${h}.${p}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, signature);
  if (!valid) return fail("BAD_SIGNATURE");

  if (
    claims.iss !== ISSUER ||
    claims.aud !== AUDIENCE ||
    typeof claims.sub !== "string" ||
    typeof claims.jti !== "string" ||
    typeof claims.iat !== "number" ||
    typeof claims.exp !== "number"
  ) {
    return fail("BAD_CLAIMS");
  }
  if (claims.exp <= nowSeconds - clockSkewSeconds) return fail("EXPIRED");
  if (claims.iat > nowSeconds + clockSkewSeconds) return fail("NOT_YET_VALID");

  return { ok: true, claims: claims as BuyerClaims };
}