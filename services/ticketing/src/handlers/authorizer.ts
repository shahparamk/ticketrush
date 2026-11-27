import type { KeyObject } from "node:crypto";
import type {
  APIGatewayRequestAuthorizerEventV2,
  APIGatewaySimpleAuthorizerResult,
  APIGatewaySimpleAuthorizerWithContextResult,
} from "aws-lambda";
import { cachedKmsPublicKey } from "../lib/kms.ts";
import { verifyToken } from "../lib/token.ts";
import type { BuyerContext } from "./session.ts";

type AuthorizerResult = APIGatewaySimpleAuthorizerResult | APIGatewaySimpleAuthorizerWithContextResult<BuyerContext>;

const DENY: APIGatewaySimpleAuthorizerResult = { isAuthorized: false };
const nowSeconds = (): number => Math.floor(Date.now() / 1000);

export function makeAuthorizer(getPublicKey: () => Promise<KeyObject>, now: () => number = nowSeconds) {
  return async (event: APIGatewayRequestAuthorizerEventV2): Promise<AuthorizerResult> => {
    const header = event.headers?.authorization ?? "";
    const match = /^Bearer\s+(\S+)$/i.exec(header);
    if (!match?.[1]) return DENY;

    try {
      const result = verifyToken(match[1], await getPublicKey(), now());
      if (!result.ok) {
        console.log(JSON.stringify({ msg: "token rejected", reason: result.reason }));
        return DENY;
      }
      return { isAuthorized: true, context: { buyerId: result.claims.sub, tokenId: result.claims.jti } };
    } catch (err) {
      // e.g. KMS unreachable: fail CLOSED (deny), never open
      console.error(JSON.stringify({ msg: "authorizer failed", error: String(err) }));
      return DENY;
    }
  };
}

export const handler = makeAuthorizer(cachedKmsPublicKey(process.env.SIGNING_KEY_ID ?? ""));