import { createPublicKey, type KeyObject } from "node:crypto";
import { GetPublicKeyCommand, KMSClient, SignCommand } from "@aws-sdk/client-kms";
import type { DerSigner } from "./token.ts";

// Asks KMS to sign: the private key never leaves KMS
export function kmsSigner(keyId: string, client: KMSClient = new KMSClient({})): DerSigner {
  return async (data) => {
    const res = await client.send(
      new SignCommand({ KeyId: keyId, Message: data, MessageType: "RAW", SigningAlgorithm: "ECDSA_SHA_256" }),
    );
    if (!res.Signature) throw new Error("KMS returned no signature");
    return res.Signature;
  };
}

// Fetches the PUBLIC key once per Lambda container and reuses it, so verifying a token needs no KMS call
export function cachedKmsPublicKey(keyId: string, client: KMSClient = new KMSClient({})): () => Promise<KeyObject> {
  let cached: Promise<KeyObject> | undefined;
  return () => {
    cached ??= client
      .send(new GetPublicKeyCommand({ KeyId: keyId }))
      .then((res) => {
        if (!res.PublicKey) throw new Error("KMS returned no public key");
        return createPublicKey({ key: Buffer.from(res.PublicKey), format: "der", type: "spki" });
      })
      .catch((err: unknown) => {
        cached = undefined; // don't cache a failure; the next request retries
        throw err;
      });
    return cached;
  };
}