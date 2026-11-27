import type { APIGatewayProxyStructuredResultV2 } from "aws-lambda";

export function json(
  statusCode: number,
  body: unknown,
  headers: Record<string, string> = {},
): APIGatewayProxyStructuredResultV2 {
  return {
    statusCode,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...headers },
    body: JSON.stringify(body),
  };
}

// Every error has the same shape, so clients can rely on error.code
export function error(statusCode: number, code: string, message: string): APIGatewayProxyStructuredResultV2 {
  return json(statusCode, { error: { code, message } });
}