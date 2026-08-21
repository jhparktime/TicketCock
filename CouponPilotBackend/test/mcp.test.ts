import assert from "node:assert/strict";
import { once } from "node:events";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { createMcpApp } from "../src/mcpServer.js";

const previousEnvironment = {
  NODE_ENV: process.env.NODE_ENV,
  MCP_HOST: process.env.MCP_HOST,
  MCP_INTERNAL_TOKEN: process.env.MCP_INTERNAL_TOKEN,
  GOOGLE_MAPS_API_KEY: process.env.GOOGLE_MAPS_API_KEY,
  KAKAO_REST_API_KEY: process.env.KAKAO_REST_API_KEY
};

process.env.NODE_ENV = "mcp-contract";
process.env.MCP_HOST = "127.0.0.1";
process.env.MCP_INTERNAL_TOKEN = "contract-test-token";
delete process.env.GOOGLE_MAPS_API_KEY;
delete process.env.KAKAO_REST_API_KEY;

const httpServer = createMcpApp().listen(0, "127.0.0.1");
await once(httpServer, "listening");
const address = httpServer.address();
assert(address && typeof address !== "string");
const baseURL = `http://127.0.0.1:${address.port}`;

function restoreEnvironment() {
  for (const [key, value] of Object.entries(previousEnvironment)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
}

function errorText(result: Awaited<ReturnType<Client["callTool"]>>) {
  if (!Array.isArray(result.content)) return "";
  const first = result.content[0] as { type?: unknown; text?: unknown } | undefined;
  return first?.type === "text" && typeof first.text === "string" ? first.text : "";
}

try {
  const health = await fetch(`${baseURL}/health`);
  assert.equal(health.status, 200);
  assert.deepEqual(await health.json(), { ok: true, service: "couponcok-mcp", tools: 4 });
  assert.match(health.headers.get("x-couponcok-request-id") ?? "", /^[0-9a-f-]{36}$/u);

  const unauthorized = await fetch(`${baseURL}/mcp`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} })
  });
  assert.equal(unauthorized.status, 401);
  assert.deepEqual(await unauthorized.json(), {
    jsonrpc: "2.0",
    error: { code: -32001, message: "Internal MCP authentication required" },
    id: null
  });

  const invalidToken = await fetch(`${baseURL}/mcp`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-couponcok-mcp-token": "wrong-token"
    },
    body: JSON.stringify({ jsonrpc: "2.0", id: 2, method: "initialize", params: {} })
  });
  assert.equal(invalidToken.status, 401);

  for (const method of ["GET", "PUT", "DELETE"]) {
    const methodResponse = await fetch(`${baseURL}/mcp`, { method });
    assert.equal(methodResponse.status, 405, `${method} /mcp must be rejected`);
    assert.deepEqual(await methodResponse.json(), {
      jsonrpc: "2.0",
      error: { code: -32000, message: "Method not allowed" },
      id: null
    });
  }

  const client = new Client({ name: "couponcok-mcp-contract-test", version: "1.0.0" });
  const transport = new StreamableHTTPClientTransport(new URL(`${baseURL}/mcp`), {
    requestInit: { headers: { "x-couponcok-mcp-token": "contract-test-token" } }
  });

  try {
    await client.connect(transport);
    const listed = await client.listTools();
    assert.deepEqual(listed.tools.map((tool) => tool.name).sort(), [
      "calculate_best_discount",
      "retrieve_carrier_benefits",
      "search_nearby_stores",
      "verify_store_with_external_maps"
    ]);
    for (const tool of listed.tools) {
      assert.equal(tool.inputSchema.type, "object", `${tool.name} must publish an object input schema`);
      assert.equal(tool.inputSchema.additionalProperties, false, `${tool.name} must reject unknown input properties`);
      assert.equal(tool.outputSchema?.type, "object", `${tool.name} must publish an object output schema`);
      assert.equal(tool.outputSchema?.additionalProperties, false, `${tool.name} must publish a closed output schema`);
      assert.equal(tool.annotations?.readOnlyHint, true, `${tool.name} must be read-only`);
      assert.equal(tool.annotations?.destructiveHint, false, `${tool.name} must not be destructive`);
    }
    const storeTool = listed.tools.find((tool) => tool.name === "search_nearby_stores");
    const storeOutputSchema = storeTool?.outputSchema as { properties?: Record<string, { type?: unknown; additionalProperties?: unknown }> } | undefined;
    assert.equal(storeOutputSchema?.properties?.sourceMetadata?.type, "object", "public store provenance must be exposed to the Agent");
    assert.equal(storeOutputSchema?.properties?.sourceMetadata?.additionalProperties, false, "public store provenance must remain schema-bound");

    const externalMaps = await client.callTool({
      name: "verify_store_with_external_maps",
      arguments: {
        storeName: "투썸플레이스 수원시청점",
        latitude: 37.2663,
        longitude: 127.0286,
        radiusMeters: 900
      }
    });
    assert.equal(externalMaps.isError, undefined);
    const externalMapsStructured = externalMaps.structuredContent as {
      provider: string; status: string; coarseLatitude: number; coarseLongitude: number; policy: string;
    };
    assert.equal(externalMapsStructured.provider, "unavailable");
    assert.equal(externalMapsStructured.status, "not_configured");
    assert.equal(externalMapsStructured.coarseLatitude, 37.27);
    assert.equal(externalMapsStructured.coarseLongitude, 127.03);
    assert.match(externalMapsStructured.policy, /data\.go\.kr/u);

    const calculation = await client.callTool({
      name: "calculate_best_discount",
      arguments: {
        storeId: "twosome-suwon",
        storeName: "투썸플레이스 수원점",
        expectedPrice: 5_100,
        profile: { carrier: "SKT", membershipGrade: "VIP", monthlyBenefitStatus: "available" },
        coupons: [{
          id: "twosome-americano",
          brand: "투썸플레이스",
          title: "아메리카노 2,000원 할인",
          discountType: "fixedAmount",
          discountValue: 2_000,
          minimumOrderAmount: 5_000,
          combinableWithCard: true,
          referencePrice: 5_100
        }]
      }
    });
    assert.equal(calculation.isError, undefined);
    const structured = calculation.structuredContent as {
      recommendedOption: { finalPrice: number; savings: number };
      alternatives: unknown[];
      policy: string;
    };
    assert.equal(structured.recommendedOption.finalPrice, 3_100);
    assert.equal(structured.recommendedOption.savings, 2_000);
    assert.deepEqual(structured.alternatives, []);
    assert.match(structured.policy, /LLM/u);
    assert.deepEqual(JSON.parse(errorText(calculation)), calculation.structuredContent);

    const unknownProperty = await client.callTool({
      name: "calculate_best_discount",
      arguments: {
        storeId: "twosome-suwon",
        storeName: "투썸플레이스 수원점",
        expectedPrice: 5_100,
        profile: { carrier: "SKT", leakedField: "must-not-pass" },
        coupons: [{
          id: "coupon",
          brand: "투썸플레이스",
          title: "테스트 쿠폰",
          discountType: "fixedAmount",
          discountValue: 500,
          minimumOrderAmount: 0,
          combinableWithCard: false
        }]
      }
    });
    assert.equal(unknownProperty.isError, true);
    assert.match(errorText(unknownProperty), /Input validation error/u);
    assert.match(errorText(unknownProperty), /unrecognized key/iu);

    const invalidPercentage = await client.callTool({
      name: "calculate_best_discount",
      arguments: {
        storeId: "twosome-suwon",
        storeName: "투썸플레이스 수원점",
        expectedPrice: 5_100,
        profile: { carrier: "없음" },
        coupons: [{
          id: "invalid-percentage",
          brand: "투썸플레이스",
          title: "잘못된 비율",
          discountType: "percentage",
          discountValue: 101,
          minimumOrderAmount: 0,
          combinableWithCard: false
        }]
      }
    });
    assert.equal(invalidPercentage.isError, true);
    assert.match(errorText(invalidPercentage), /percentage discountValue/u);

    const injectedBenefitRule = await client.callTool({
      name: "calculate_best_discount",
      arguments: {
        storeId: "twosome-suwon",
        storeName: "투썸플레이스 수원점",
        expectedPrice: 5_100,
        profile: { carrier: "SKT" },
        coupons: [{
          id: "coupon",
          brand: "투썸플레이스",
          title: "테스트 쿠폰",
          discountType: "fixedAmount",
          discountValue: 500,
          minimumOrderAmount: 0,
          combinableWithCard: false
        }],
        benefitRules: [{
          provider: "SKT",
          appliesTo: "carrier",
          discountPercent: 10,
          combinableWithCoupon: false
        }]
      }
    });
    assert.equal(injectedBenefitRule.isError, true);
    assert.match(errorText(injectedBenefitRule), /unrecognized key/iu, "Agents must not inject a calculator rule");

    const unknownTool = await client.callTool({ name: "redeem_coupon_without_user", arguments: {} });
    assert.equal(unknownTool.isError, true);
    assert.match(errorText(unknownTool), /not found/u);
  } finally {
    await client.close();
  }

  console.log("MCP contract tests passed");
} finally {
  httpServer.close();
  restoreEnvironment();
}
