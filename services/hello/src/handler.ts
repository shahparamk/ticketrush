import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2 } from "aws-lambda";

// Node.js 24 on Lambda supports async handlers only (callback-style handlers were removed).
export const handler = async (
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyStructuredResultV2> => {
  // Lambda sets AWS_REGION automatically, so the same code reports where it actually ran.
  const region = process.env.AWS_REGION ?? "unknown";

  return {
    statusCode: 200,
    headers: {
      "content-type": "application/json",
      "cache-control": "no-store",
    },
    body: JSON.stringify({
      message: "hello from TicketRush",
      region,
      version: process.env.APP_VERSION ?? "dev",
      requestId: event.requestContext?.requestId ?? null,
    }),
  };
};