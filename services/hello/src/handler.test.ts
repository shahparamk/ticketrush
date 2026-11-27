import { test } from "node:test";
import assert from "node:assert/strict";
import type { APIGatewayProxyEventV2 } from "aws-lambda";
import { handler } from "./handler.ts";

const fakeEvent = { requestContext: { requestId: "req-123" } } as unknown as APIGatewayProxyEventV2;

test("returns 200 with JSON and the region it ran in", async () => {
  process.env.AWS_REGION = "us-west-2";
  process.env.APP_VERSION = "abc1234";

  const res = await handler(fakeEvent);

  assert.equal(res.statusCode, 200);
  assert.equal(res.headers?.["content-type"], "application/json");
  const body = JSON.parse(res.body ?? "{}");
  assert.equal(body.region, "us-west-2");
  assert.equal(body.version, "abc1234");
  assert.equal(body.requestId, "req-123");
});

test("falls back safely when the environment is missing", async () => {
  delete process.env.AWS_REGION;
  delete process.env.APP_VERSION;

  const res = await handler({} as APIGatewayProxyEventV2);
  const body = JSON.parse(res.body ?? "{}");

  assert.equal(body.region, "unknown");
  assert.equal(body.version, "dev");
  assert.equal(body.requestId, null);
});