import { randomUUID } from "node:crypto";
import type { APIGatewayProxyEventV2WithLambdaAuthorizer, APIGatewayProxyStructuredResultV2 } from "aws-lambda";
import { error, json } from "../lib/http.ts";
import { kmsSigner } from "../lib/kms.ts";
import { AUDIENCE, ISSUER, TOKEN_TTL_SECONDS, issueToken, type DerSigner } from "../lib/token.ts";

export interface BuyerContext {
  buyerId: string;
  tokenId: string;
}

type SessionEvent = APIGatewayProxyEventV2WithLambdaAuthorizer<BuyerContext>;
const nowSeconds = (): number => Math.floor(Date.now() / 1000);

export function makeSessionHandler(sign: DerSigner, now: () => number = nowSeconds) {
  return async (event: SessionEvent): Promise<APIGatewayProxyStructuredResultV2> => {
    const region = process.env.AWS_REGION ?? "unknown";
    try {
      switch (event.routeKey) {
        // Anonymous buyers get a short-lived signed token (like joining the queue)
        case "POST /session": {
          const iat = now();
          const buyerId = randomUUID();
          const token = await issueToken(sign, {
            iss: ISSUER,
            aud: AUDIENCE,
            sub: buyerId,
            iat,
            exp: iat + TOKEN_TTL_SECONDS,
            jti: randomUUID(),
          });
          return json(201, { region, buyerId, token, expiresAt: iat + TOKEN_TTL_SECONDS });
        }

        // Protected by the authorizer: proves a token works (in either region)
        case "GET /me": {
          const buyer = event.requestContext.authorizer?.lambda;
          if (!buyer?.buyerId) return error(401, "UNAUTHENTICATED", "No buyer on this request");
          return json(200, { region, buyerId: buyer.buyerId });
        }

        default:
          return error(404, "ROUTE_NOT_FOUND", `No route ${event.routeKey}`);
      }
    } catch (err) {
      console.error(JSON.stringify({ msg: "session failed", routeKey: event.routeKey, error: String(err) }));
      return error(500, "INTERNAL", "Something went wrong");
    }
  };
}

export const handler = makeSessionHandler(kmsSigner(process.env.SIGNING_KEY_ID ?? ""));