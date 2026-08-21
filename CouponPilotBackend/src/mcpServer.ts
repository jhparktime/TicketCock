import { timingSafeEqual } from "node:crypto";
import { pathToFileURL } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { createMcpExpressApp } from "@modelcontextprotocol/sdk/server/express.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import type { Request, Response } from "express";
import { z } from "zod";
import { searchOfficialBenefits } from "./benefitRag.js";
import { calculateOptions, matchingBenefitRules, type RecommendationInput } from "./calculator.js";
import { initializeObservability, traceHttpRequest, traceOperation } from "./observability.js";
import { fetchNearbySuwonStores, SUWON_STORE_DATA_SOURCE } from "./server.js";
import { verifyStoreWithExternalMaps } from "./externalMapsMcp.js";

const MAX_MONEY_WON = 1_000_000;

const couponSchema = z.object({
  id: z.string().trim().min(1).max(128),
  brand: z.string().trim().min(1).max(100),
  title: z.string().trim().min(1).max(200),
  discountType: z.enum(["fixedAmount", "percentage"]),
  discountValue: z.number().int().min(0).max(MAX_MONEY_WON),
  minimumOrderAmount: z.number().int().min(0).max(MAX_MONEY_WON),
  maximumDiscount: z.number().int().min(0).max(MAX_MONEY_WON).optional(),
  expiresAt: z.string().datetime().optional(),
  combinableWithCard: z.boolean(),
  referencePrice: z.number().int().min(1).max(MAX_MONEY_WON).optional()
}).strict().superRefine((coupon, context) => {
  if (coupon.discountType === "percentage" && coupon.discountValue > 100) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["discountValue"],
      message: "percentage discountValue must be between 0 and 100"
    });
  }
});

const profileSchema = z.object({
  carrier: z.enum(["SKT", "KT", "LG U+", "없음"]),
  membershipGrade: z.string().trim().min(1).max(50).optional(),
  monthlyBenefitStatus: z.enum(["available", "used", "unknown"]).optional(),
  cards: z.array(z.object({
    issuer: z.enum(["신한카드", "KB국민카드", "현대카드"]),
    productId: z.string().trim().min(1).max(100),
    productName: z.string().trim().min(1).max(100),
    previousMonthSpendQualified: z.boolean(),
    monthlyBenefitRemainingAmount: z.number().int().min(0).max(MAX_MONEY_WON)
  }).strict()).max(10).optional()
}).strict();

const benefitRuleSchema = z.object({
  provider: z.string().trim().min(1).max(100),
  appliesTo: z.enum(["carrier", "card"]),
  discountPercent: z.number().min(0).max(100).optional(),
  fixedDiscount: z.number().int().min(0).max(MAX_MONEY_WON).optional(),
  maximumDiscount: z.number().int().min(0).max(MAX_MONEY_WON).optional(),
  minimumOrderAmount: z.number().int().min(0).max(MAX_MONEY_WON).optional(),
  combinableWithCoupon: z.boolean(),
  eligibleGrades: z.array(z.string().trim().min(1).max(50)).max(20).optional(),
  requiresAvailableThisMonth: z.boolean().optional(),
  eligibleStoreKeywords: z.array(z.string().trim().min(1).max(100)).min(1).max(50),
  cardProductId: z.string().trim().min(1).max(100).optional(),
  requiresPreviousMonthSpend: z.boolean().optional(),
  eligibleHoursKST: z.array(z.number().int().min(0).max(23)).max(24).optional()
}).strict().superRefine((rule, context) => {
  if ((rule.discountPercent ?? 0) <= 0 && (rule.fixedDiscount ?? 0) <= 0) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["discountPercent"],
      message: "a positive discountPercent or fixedDiscount is required"
    });
  }
  if (rule.appliesTo === "card" && !rule.cardProductId) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["cardProductId"],
      message: "cardProductId is required for card benefit rules"
    });
  }
});

const storeOutputSchema = z.object({
  id: z.string().min(1),
  name: z.string().min(1),
  category: z.string(),
  address: z.string(),
  latitude: z.number().min(37.18).max(37.34),
  longitude: z.number().min(126.90).max(127.15),
  distanceMeters: z.number().nonnegative()
}).strict();

const storeSourceMetadataSchema = z.object({
  id: z.literal("data.go.kr"),
  datasetId: z.literal("15012005"),
  title: z.string().min(1),
  officialURL: z.string().url(),
  apiVersion: z.literal("sdsc2"),
  scope: z.literal("수원시"),
  refreshPolicy: z.string().min(1),
  usage: z.literal("store-identification-only"),
  retrievedAt: z.string().datetime()
}).strict();

const benefitMatchOutputSchema = z.object({
  id: z.string().min(1),
  documentId: z.string().min(1),
  title: z.string().min(1),
  provider: z.string().min(1),
  sourceURL: z.string().url(),
  text: z.string().min(1),
  rule: benefitRuleSchema.optional(),
  lifecycleStatus: z.enum(["draft", "reviewed", "active", "expired", "withdrawn", "retired"]).optional(),
  checkedAt: z.string().optional(),
  staleAfter: z.string().optional(),
  effectiveFrom: z.string().optional(),
  effectiveTo: z.string().optional(),
  version: z.string().optional(),
  reviewer: z.string().optional(),
  license: z.string().optional(),
  contentHash: z.string().optional(),
  retiredAt: z.string().optional(),
  retirementReason: z.string().optional(),
  score: z.number().min(-1).max(1)
}).strict();

const calculatedOptionOutputSchema = z.object({
  id: z.string().min(1),
  title: z.string().min(1),
  originalPrice: z.number().int().min(1).max(MAX_MONEY_WON),
  finalPrice: z.number().int().min(0).max(MAX_MONEY_WON),
  savings: z.number().int().min(0).max(MAX_MONEY_WON),
  badges: z.array(z.string().min(1)).max(10)
}).strict();

/** Every Tool result is parsed again at the producer boundary before an Agent can consume it. */
const storeSearchOutputSchema = z.object({
  region: z.literal("수원시"),
  source: z.literal("data.go.kr"),
  sourceMetadata: storeSourceMetadataSchema,
  stores: z.array(storeOutputSchema).max(500)
}).strict();

const benefitSearchOutputSchema = z.object({
  matches: z.array(benefitMatchOutputSchema).max(8),
  policy: z.string().min(1)
}).strict();

const calculationOutputSchema = z.object({
  recommendedOption: calculatedOptionOutputSchema.nullable(),
  alternatives: z.array(calculatedOptionOutputSchema).max(129),
  policy: z.string().min(1)
}).strict();

const externalPlaceVerificationOutputSchema = z.object({
  provider: z.enum(["google-maps-mcp", "kakao-local-api", "unavailable"]),
  status: z.enum(["verified", "fallback_verified", "not_configured", "unavailable"]),
  query: z.string().min(1).max(200),
  coarseLatitude: z.number().min(37.18).max(37.34),
  coarseLongitude: z.number().min(126.90).max(127.15),
  attributionURLs: z.array(z.string().url()).max(5),
  candidateCount: z.number().int().min(0).max(20),
  policy: z.string().min(1)
}).strict();

function toolResult<T>(schema: z.ZodType<T>, value: unknown) {
  const parsed = schema.parse(value);
  return {
    content: [{ type: "text" as const, text: JSON.stringify(parsed) }],
    structuredContent: parsed as Record<string, unknown>
  };
}

function createCouponCockMcpServer() {
  const server = new McpServer({ name: "couponcok-tools", version: "1.0.0" });

  server.registerTool("search_nearby_stores", {
    title: "수원 매장 검색",
    description: "수원시 좌표 주변에서 쿠폰콕 지원 프랜차이즈 매장을 검색합니다. 사용자의 쿠폰·바코드 정보는 전달하지 마세요.",
    inputSchema: z.object({
      latitude: z.number().min(37.18).max(37.34),
      longitude: z.number().min(126.90).max(127.15),
      radiusMeters: z.number().int().min(100).max(1_500).default(1_000),
      query: z.string().trim().min(1).max(100).optional()
    }).strict(),
    outputSchema: storeSearchOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
  }, async ({ latitude, longitude, radiusMeters, query }) => {
    const stores = await traceOperation("mcp.search_nearby_stores", {
      "couponcok.region": "수원시",
      "couponcok.radius_m": radiusMeters
    }, () => fetchNearbySuwonStores(latitude, longitude, radiusMeters, query));
    return toolResult(storeSearchOutputSchema, {
      region: "수원시",
      source: SUWON_STORE_DATA_SOURCE.id,
      sourceMetadata: { ...SUWON_STORE_DATA_SOURCE, retrievedAt: new Date().toISOString() },
      stores
    });
  });

  server.registerTool("verify_store_with_external_maps", {
    title: "외부 지도 MCP 매장 검증",
    description: "Google Maps 공식 MCP로 매장명을 보조 검증하고, 응답 불가 시 카카오 공식 Local REST API를 fallback으로 사용합니다. 정밀 GPS·쿠폰·바코드는 외부로 전송하지 않습니다.",
    inputSchema: z.object({
      storeName: z.string().trim().min(1).max(150),
      latitude: z.number().min(37.18).max(37.34),
      longitude: z.number().min(126.90).max(127.15),
      radiusMeters: z.number().int().min(100).max(1_500).default(1_000)
    }).strict(),
    outputSchema: externalPlaceVerificationOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
  }, async (input) => {
    const result = await traceOperation("mcp.verify_store_with_external_maps", {
      "couponcok.region": "수원시",
      "couponcok.maps.precision": "0.01-degree-grid"
    }, () => verifyStoreWithExternalMaps(input));
    return toolResult(externalPlaceVerificationOutputSchema, result);
  });

  server.registerTool("retrieve_carrier_benefits", {
    title: "통신사·카드 공식 혜택 검색",
    description: "통신사와 등록 카드의 공식 혜택 문서에서 매장·등급·카드 상품에 맞는 근거와 구조화 규칙을 검색합니다.",
    inputSchema: z.object({
      carrier: z.enum(["SKT", "KT", "LG U+", "없음"]),
      membershipGrade: z.string().trim().min(1).max(50).optional(),
      cardProducts: z.array(z.string().trim().min(1).max(100)).max(10).optional(),
      storeName: z.string().trim().min(1).max(150),
      limit: z.number().int().min(1).max(8).default(4)
    }).strict(),
    outputSchema: benefitSearchOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false }
  }, async ({ carrier, membershipGrade, cardProducts, storeName, limit }) => {
    const chunks = await traceOperation("mcp.retrieve_carrier_benefits", {
      "couponcok.carrier": carrier,
      "couponcok.store": storeName
    }, () => searchOfficialBenefits([carrier, membershipGrade ?? "", ...(cardProducts ?? []), storeName].join(" "), limit));
    return toolResult(benefitSearchOutputSchema, {
      matches: chunks.map(({ embedding, ...chunk }) => chunk),
      policy: "공식 문서에 구조화된 rule이 있는 혜택만 Calculator 입력으로 사용할 수 있습니다."
    });
  });

  server.registerTool("calculate_best_discount", {
    title: "쿠폰·통신사·카드 혜택 최종가 계산",
    description: "쿠폰과 검증된 통신사·카드 혜택 규칙으로 최종가와 절약액을 결정론적으로 계산합니다. 가격·순위 결정의 유일한 도구입니다.",
    inputSchema: z.object({
      storeId: z.string().trim().min(1).max(150),
      storeName: z.string().trim().min(1).max(150),
      expectedPrice: z.number().int().min(1).max(MAX_MONEY_WON),
      profile: profileSchema,
      coupons: z.array(couponSchema).min(1).max(100)
    }).strict(),
    outputSchema: calculationOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false }
  }, async (recommendation) => {
    const input = recommendation as RecommendationInput;
    // The Agent never supplies monetary benefit rules. Resolve a fresh set from the active,
    // reviewed official RAG index inside this server boundary, then filter it against the
    // authenticated user's declared carrier/card product and the current store.
    const benefitQuery = [
      input.profile.carrier,
      input.profile.membershipGrade ?? "",
      ...(input.profile.cards?.flatMap((card) => [card.productId, card.productName]) ?? []),
      input.storeName ?? input.storeId
    ].filter(Boolean).join(" ");
    let officialChunks: Awaited<ReturnType<typeof searchOfficialBenefits>> = [];
    try {
      officialChunks = await traceOperation("mcp.resolve_approved_benefit_rules", {
        "couponcok.store": input.storeName ?? input.storeId,
        "couponcok.carrier": input.profile.carrier
      }, () => searchOfficialBenefits(benefitQuery, 8));
    } catch (error) {
      // A temporary official-index outage must not make the Agent invent a rule or block a
      // deterministic coupon-only comparison. The lack of a benefit rule is fail-closed.
      console.error("Approved benefit lookup unavailable for Calculator MCP", error);
    }
    const benefitRules = matchingBenefitRules(input.profile, input.storeName ?? input.storeId, officialChunks);
    const options = await traceOperation("mcp.calculate_best_discount", {
      "couponcok.store": input.storeName ?? input.storeId,
      "couponcok.coupon_count": input.coupons.length,
      "couponcok.benefit_rule_count": benefitRules.length
    }, async () => calculateOptions(input, benefitRules));
    return toolResult(calculationOutputSchema, {
      recommendedOption: options[0] ?? null,
      alternatives: options.slice(1),
      policy: "할인 규칙은 활성·승인된 공식 RAG 문서에서 서버가 다시 조회합니다. LLM은 금액·순위·중복 가능 여부를 변경하거나 규칙을 주입할 수 없습니다."
    });
  });

  return server;
}

function hasValidInternalToken(req: Request) {
  if (process.env.NODE_ENV === "test") return true;
  const expected = process.env.MCP_INTERNAL_TOKEN;
  if (!expected) return false;
  const actual = req.header("x-couponcok-mcp-token") ?? "";
  const left = Buffer.from(actual);
  const right = Buffer.from(expected);
  return left.length === right.length && timingSafeEqual(left, right);
}

export function createMcpApp() {
  const host = process.env.NODE_ENV === "test" ? "127.0.0.1" : process.env.MCP_HOST ?? "0.0.0.0";
  const app = createMcpExpressApp({ host });
  app.use(traceHttpRequest);
  app.post("/mcp", async (req: Request, res: Response) => {
    if (!hasValidInternalToken(req)) {
      return res.status(401).json({ jsonrpc: "2.0", error: { code: -32001, message: "Internal MCP authentication required" }, id: null });
    }
    const server = createCouponCockMcpServer();
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
    try {
      await server.connect(transport);
      await transport.handleRequest(req, res, req.body);
    } catch (error) {
      console.error("MCP request failed", error);
      if (!res.headersSent) res.status(500).json({ jsonrpc: "2.0", error: { code: -32603, message: "Internal MCP error" }, id: null });
    } finally {
      await transport.close();
      await server.close();
    }
  });
  app.get("/health", (_req, res) => res.json({ ok: true, service: "couponcok-mcp", tools: 4 }));
  app.all("/mcp", (_req, res) => res.status(405).json({ jsonrpc: "2.0", error: { code: -32000, message: "Method not allowed" }, id: null }));
  return app;
}

if (process.env.NODE_ENV !== "test" && process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await initializeObservability();
  createMcpApp().listen(process.env.PORT || 8080, () => console.log("CouponCock MCP server listening"));
}
