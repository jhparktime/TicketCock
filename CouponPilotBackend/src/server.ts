import express, { type NextFunction, type Request, type Response } from "express";
import { pathToFileURL } from "node:url";
import { getApps, initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getAppCheck } from "firebase-admin/app-check";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { createHash } from "node:crypto";
import { z } from "zod";
import { searchOfficialBenefits } from "./benefitRag.js";
import {
  calculateOptions,
  couponIsActive,
  couponMatchesStore,
  isSupportedFranchiseStore,
  matchingBenefitRules,
  type RecommendationInput
} from "./calculator.js";
import { initializeObservability, recordAIUsage, requestCorrelationID, traceHttpRequest, traceOperation } from "./observability.js";
import { adkResultMatchesCalculator, configuredAdkMode, runAdkOrchestration, shouldRunAdk } from "./adkClient.js";
import { redactSensitiveText } from "./privacy.js";
import { checkModelArmorText, configuredDlpMode, configuredModelArmorMode, deidentifyTextForModel } from "./cloudSafety.js";

export const app = express();
app.use(express.json({ limit: "32kb" }));
app.use(traceHttpRequest);

const SUWON_BOUNDS = { minLat: 37.18, maxLat: 37.34, minLon: 126.90, maxLon: 127.15 };
const DATA_GO_KR_BASE_URL = "https://apis.data.go.kr/B553077/api/open/sdsc2/storeListInRadius";
const GEMINI_MODEL = "gemini-2.5-flash";
const FRANCHISE_DISCOVERY_PAGE_COUNT = 20;
const STORE_DIRECTORY_CACHE_TTL_MS = 10 * 60 * 1_000;
const STORE_DIRECTORY_CACHE = new Map<string, { expiresAt: number; stores: ReturnedStore[] }>();
const DATA_GO_REQUEST_TIMEOUT_MS = 6_000;

/**
 * Public-data provenance is part of the recommendation contract. The client and MCP Agent may
 * cite this metadata, but it must never turn a public store listing into a discount claim.
 */
export const SUWON_STORE_DATA_SOURCE = Object.freeze({
  id: "data.go.kr",
  datasetId: "15012005",
  title: "소상공인시장진흥공단_상가(상권)정보_API",
  officialURL: "https://www.data.go.kr/data/15012005/openapi.do",
  apiVersion: "sdsc2",
  scope: "수원시",
  refreshPolicy: "live-query with 10-minute server cache",
  usage: "store-identification-only"
});

type PublicStore = {
  bizesId: string; bizesNm: string; brchNm?: string; indsLclsNm?: string; indsMclsNm?: string;
  signguNm?: string; rdnmAdr?: string; lon: string | number; lat: string | number;
};

type ReturnedStore = {
  id: string; name: string; category: string; address: string; latitude: number; longitude: number; distanceMeters: number;
};

type AuthenticatedRequest = Request & { firebaseUID?: string; couponcokRequestId?: string };

const couponRequestSchema = z.object({
  id: z.string().min(1).max(128),
  brand: z.string().min(1).max(100),
  title: z.string().min(1).max(200),
  discountType: z.enum(["fixedAmount", "percentage"]),
  discountValue: z.number().int().min(0).max(1_000_000),
  minimumOrderAmount: z.number().int().min(0).max(1_000_000),
  maximumDiscount: z.number().int().min(0).max(1_000_000).optional(),
  expiresAt: z.string().datetime().optional(),
  combinableWithCard: z.boolean(),
  referencePrice: z.number().int().min(1).max(1_000_000).optional()
}).strict();

const recommendationRequestSchema = z.object({
  storeId: z.string().min(1).max(150),
  storeName: z.string().min(1).max(150).optional(),
  expectedPrice: z.number().int().min(1).max(1_000_000),
  profile: z.object({
    id: z.string().max(128).optional(),
    carrier: z.enum(["SKT", "KT", "LG U+", "없음"]),
    membershipGrade: z.string().max(50).optional(),
    monthlyBenefitStatus: z.enum(["available", "used", "unknown"]).optional(),
    cards: z.array(z.object({
      issuer: z.enum(["신한카드", "KB국민카드", "현대카드"]),
      productId: z.string().min(1).max(100),
      productName: z.string().min(1).max(100),
      previousMonthSpendQualified: z.boolean(),
      monthlyBenefitRemainingAmount: z.number().int().min(0).max(1_000_000)
    }).strict()).max(10).optional()
  }).strict(),
  coupons: z.array(couponRequestSchema).min(1).max(100)
}).strict();

type PersistedStoreDirectory = {
  expiresAtMillis: number;
  stores: ReturnedStore[];
};

function appCheckMode() {
  const value = process.env.APP_CHECK_ENFORCEMENT_MODE;
  return value === "enforce" || value === "off" ? value : "monitor";
}

async function verifyAppCheck(req: Request, res: Response) {
  if (process.env.NODE_ENV === "test" || appCheckMode() === "off") return true;
  const token = req.header("x-firebase-appcheck")?.trim();
  try {
    if (!token) throw new Error("missing token");
    if (!getApps().length) initializeApp();
    await getAppCheck().verifyToken(token);
    return true;
  } catch (error) {
    console.warn(JSON.stringify({
      severity: "WARNING",
      event: "security.app_check_rejected",
      mode: appCheckMode(),
      path: req.path,
      reason: error instanceof Error ? error.message : "invalid token"
    }));
    if (appCheckMode() === "enforce") {
      res.status(401).json({ error: "Valid Firebase App Check token is required" });
      return false;
    }
    res.setHeader("x-couponcok-app-check", "monitor-rejected");
    return true;
  }
}

/** Cloud Run is public only as a transport; every business endpoint verifies a Firebase ID token here. */
async function requireFirebaseAuth(req: AuthenticatedRequest, res: Response, next: NextFunction) {
  if (process.env.NODE_ENV === "test") {
    req.firebaseUID = "test-user";
    return next();
  }
  const accept = async (uid: string) => {
    req.firebaseUID = uid;
    if (await verifyAppCheck(req, res)) next();
  };
  // Only the API Gateway service account can invoke this private Cloud Run service. After
  // Gateway verifies the Firebase JWT, it forwards the verified Firebase payload in this header.
  const gatewayUserInfo = req.header("x-apigateway-api-userinfo");
  if (gatewayUserInfo) {
    try {
      const payload = JSON.parse(Buffer.from(gatewayUserInfo, "base64url").toString("utf8")) as { user_id?: string; sub?: string };
      const uid = payload.user_id ?? payload.sub;
      if (uid) {
        await accept(uid);
        return;
      }
    } catch { /* Fall through to direct Firebase token verification. */ }
  }
  // Direct calls are useful for local development; production traffic is normally Gateway-routed.
  const header = req.header("x-forwarded-authorization") ?? req.header("authorization") ?? "";
  const idToken = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  if (!idToken) return res.status(401).json({ error: "Firebase ID token is required" });
  try {
    if (!getApps().length) initializeApp();
    await accept((await getAuth().verifyIdToken(idToken, true)).uid);
  } catch (error) {
    console.warn("Rejected Firebase token", error instanceof Error ? error.message : error);
    res.status(401).json({ error: "Invalid or revoked Firebase ID token" });
  }
}

app.use("/v1", requireFirebaseAuth);

const endpointQuotas: Record<string, { windowMs: number; limit: number }> = {
  "GET /v1/stores/nearby": { windowMs: 60 * 60 * 1_000, limit: 120 },
  "GET /v1/benefits/search": { windowMs: 24 * 60 * 60 * 1_000, limit: 120 },
  "POST /v1/coupons/normalize": { windowMs: 24 * 60 * 60 * 1_000, limit: 30 },
  "POST /v1/recommendations": { windowMs: 24 * 60 * 60 * 1_000, limit: 120 }
};

async function enforceUsageQuota(req: AuthenticatedRequest, res: Response, next: NextFunction) {
  if (process.env.NODE_ENV === "test") return next();
  const policyKey = `${req.method} ${req.baseUrl}${req.path}`;
  const policy = endpointQuotas[policyKey];
  if (!policy || !req.firebaseUID) return next();
  const now = Date.now();
  const bucket = Math.floor(now / policy.windowMs);
  const subject = createHash("sha256").update(`${req.firebaseUID}:${policyKey}:${bucket}`).digest("hex");
  const reference = getFirestore().collection("apiRateLimits").doc(subject);
  try {
    const usage = await getFirestore().runTransaction(async (transaction) => {
      const snapshot = await transaction.get(reference);
      const count = Number(snapshot.data()?.count ?? 0);
      if (count >= policy.limit) return { allowed: false, count };
      transaction.set(reference, {
        count: count + 1,
        expiresAt: Timestamp.fromMillis((bucket + 2) * policy.windowMs)
      }, { merge: true });
      return { allowed: true, count: count + 1 };
    });
    res.setHeader("x-couponcok-quota-limit", String(policy.limit));
    res.setHeader("x-couponcok-quota-remaining", String(Math.max(0, policy.limit - usage.count)));
    if (!usage.allowed) {
      res.setHeader("Retry-After", String(Math.max(1, Math.ceil(((bucket + 1) * policy.windowMs - now) / 1_000))));
      return res.status(429).json({ error: "Request quota exceeded. Please try again later." });
    }
    next();
  } catch (error) {
    console.error("Rate limit store unavailable", error);
    res.status(503).json({ error: "Request protection is temporarily unavailable" });
  }
}

app.use("/v1", enforceUsageQuota);

function isWithinSuwon(lat: number, lon: number) {
  return lat >= SUWON_BOUNDS.minLat && lat <= SUWON_BOUNDS.maxLat && lon >= SUWON_BOUNDS.minLon && lon <= SUWON_BOUNDS.maxLon;
}

function filterStoresByQuery(stores: ReturnedStore[], query?: string) {
  const normalizedQuery = query?.trim().toLocaleLowerCase("ko-KR");
  return stores.filter((store) => !normalizedQuery || store.name.toLocaleLowerCase("ko-KR").includes(normalizedQuery));
}

/**
 * Firestore `storeDirectories` is the durable Suwon store table. The in-memory cache only
 * avoids a round-trip inside a warm Cloud Run instance; the table survives a new revision.
 * A missing IAM role deliberately degrades to live data.go.kr lookup rather than preventing
 * a store-entry recommendation.
 */
async function loadPersistedStoreDirectory(cacheKey: string): Promise<PersistedStoreDirectory | undefined> {
  try {
    if (!getApps().length) initializeApp();
    const snapshot = await getFirestore().collection("storeDirectories").doc(cacheKey).get();
    const data = snapshot.data();
    if (!data || typeof data.expiresAtMillis !== "number" || data.expiresAtMillis <= Date.now() || !Array.isArray(data.stores)) return undefined;
    return { expiresAtMillis: data.expiresAtMillis, stores: data.stores as ReturnedStore[] };
  } catch (error) {
    console.warn("Firestore store directory cache unavailable", error instanceof Error ? error.message : error);
    return undefined;
  }
}

async function savePersistedStoreDirectory(cacheKey: string, stores: ReturnedStore[], expiresAtMillis: number) {
  try {
    if (!getApps().length) initializeApp();
    await getFirestore().collection("storeDirectories").doc(cacheKey).set({
      region: "수원시",
      source: SUWON_STORE_DATA_SOURCE.id,
      sourceMetadata: SUWON_STORE_DATA_SOURCE,
      updatedAtMillis: Date.now(),
      expiresAtMillis,
      stores
    });
  } catch (error) {
    console.warn("Firestore store directory cache write unavailable", error instanceof Error ? error.message : error);
  }
}

function distanceMeters(fromLat: number, fromLon: number, toLat: number, toLon: number) {
  const radius = 6_371_000;
  const radians = (degrees: number) => degrees * Math.PI / 180;
  const latitudeDelta = radians(toLat - fromLat);
  const longitudeDelta = radians(toLon - fromLon);
  const a = Math.sin(latitudeDelta / 2) ** 2 + Math.cos(radians(fromLat)) * Math.cos(radians(toLat)) * Math.sin(longitudeDelta / 2) ** 2;
  return Math.round(radius * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a)));
}

type ExplanationOption = { savings: number; finalPrice: number; badges?: string[] };
type ExplanationSource = { provider: string; sourceURL: string };

function safeRecommendationExplanation(option: ExplanationOption, sources: ExplanationSource[], agentValidated = false) {
  const officialBenefitApplied = option.badges?.some((badge) => badge.includes("공식혜택")) === true;
  const allowedProviders = [...new Set(sources.map((source) => source.provider))].slice(0, 2);
  const evidence = officialBenefitApplied && allowedProviders.length
    ? `${allowedProviders.join("·")} 공식 혜택 조건과 등록 쿠폰을 계산기가 비교했습니다.`
    : "등록 쿠폰의 확인된 조건만 계산기에 반영했습니다.";
  const validation = agentValidated ? " AI 에이전트 결과도 같은 금액인지 검증했습니다." : "";
  return `${evidence} 최종가는 ${option.finalPrice.toLocaleString("ko-KR")}원이며 ${option.savings.toLocaleString("ko-KR")}원 절약됩니다.${validation}`;
}

async function geminiClient(): Promise<any> {
  const project = process.env.VERTEX_PROJECT_ID;
  if (!project) throw new Error("VERTEX_PROJECT_ID is not configured");
  const { GoogleGenAI } = await import("@google/genai");
  return new GoogleGenAI({ vertexai: true, project, location: process.env.VERTEX_LOCATION ?? "global" });
}

/** Public-data requests are deliberately bounded; a slow page must not block a live store entry. */
async function fetchDataGoWithRetry(url: string) {
  let lastError: unknown;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const response = await fetch(url, { signal: AbortSignal.timeout(DATA_GO_REQUEST_TIMEOUT_MS) });
      if (response.ok || (response.status !== 429 && response.status < 500) || attempt === 1) return response;
    } catch (error) {
      lastError = error;
      // A network timeout is handled at the page level below. Retrying it makes an initial
      // location lookup feel stuck for too long, whereas another page may already contain a
      // nearby supported franchise.
      throw error;
    }
    // Error 23 means the public-data gateway's per-second limit was reached.
    // Retry once with a modest delay instead of returning an empty store directory.
    await new Promise((resolve) => setTimeout(resolve, 900));
  }
  throw lastError ?? new Error("data.go.kr request failed");
}

/** Gemini는 계산기 결과를 설명할 뿐, 가격·할인 순위를 변경할 수 없습니다. */
async function createRecommendationExplanation(input: { storeName: string; option: ExplanationOption; benefitSources: ExplanationSource[] }) {
  const fallback = safeRecommendationExplanation(input.option, input.benefitSources);
  if (!process.env.VERTEX_PROJECT_ID) return fallback;
  try {
    await checkModelArmorText(JSON.stringify({
      storeName: input.storeName,
      officialSourceURLs: input.benefitSources.map((source) => source.sourceURL),
      officialBenefitApplied: input.option.badges?.some((badge) => badge.includes("공식혜택")) === true
    }), "prompt");
    const client = await geminiClient();
    const response = await client.models.generateContent({
      model: GEMINI_MODEL,
      contents: JSON.stringify({
        storeName: input.storeName,
        officialSourceURLs: input.benefitSources.map((source) => source.sourceURL),
        officialBenefitApplied: input.option.badges?.some((badge) => badge.includes("공식혜택")) === true
      }),
      config: {
        temperature: 0,
        maxOutputTokens: 100,
        thinkingConfig: { thinkingBudget: 0 },
        responseMimeType: "application/json",
        systemInstruction: "검증 상태를 분류하는 역할입니다. 숫자·금액·할인 조건·자유 설명을 생성하지 마세요. JSON {reasonCode:'coupon_only'|'coupon_with_official_benefit', sourceURLs:string[]}만 반환하고 sourceURLs는 입력에 있는 URL만 선택하세요."
      }
    });
    const usage = response.usageMetadata as { promptTokenCount?: number; candidatesTokenCount?: number; totalTokenCount?: number } | undefined;
    recordAIUsage({
      operation: "recommendation_evidence_classification",
      model: GEMINI_MODEL,
      promptTokens: usage?.promptTokenCount,
      outputTokens: usage?.candidatesTokenCount,
      totalTokens: usage?.totalTokenCount
    });
    const raw = typeof response.text === "string" ? response.text.trim() : "";
    await checkModelArmorText(raw, "response");
    const parsed = JSON.parse(raw) as { reasonCode?: unknown; sourceURLs?: unknown };
    const expectedReason = input.option.badges?.some((badge) => badge.includes("공식혜택")) === true
      ? "coupon_with_official_benefit"
      : "coupon_only";
    const allowedURLs = new Set(input.benefitSources.map((source) => source.sourceURL));
    const selectedURLs = Array.isArray(parsed.sourceURLs) && parsed.sourceURLs.every((url) => typeof url === "string" && allowedURLs.has(url));
    return parsed.reasonCode === expectedReason && selectedURLs
      ? `${fallback} AI는 검증된 근거의 적용 유형만 분류했습니다.`
      : fallback;
  } catch (error) {
    console.error("Gemini explanation fallback", error);
    return fallback;
  }
}

/** iPhone Vision OCR의 raw text만 받아 쿠폰 스키마로 정규화합니다. 이미지는 서버에 전달하지 않습니다. */
async function normalizeCouponRawText(rawText: string) {
  const redacted = await deidentifyTextForModel(rawText);
  if (!redacted.text.replace(/\[REDACTED_[A-Z_]+\]/gu, "").trim()) {
    throw new Error("OCR text contained only sensitive values");
  }
  await checkModelArmorText(redacted.text, "prompt");
  const client = await geminiClient();
  const response = await client.models.generateContent({
    model: GEMINI_MODEL,
    contents: `다음은 쿠폰에서 기기 내 OCR로 추출하고 비밀 숫자·연락처를 제거한 텍스트입니다.\n---\n${redacted.text}\n---`,
    config: {
      temperature: 0,
      maxOutputTokens: 700,
      thinkingConfig: { thinkingBudget: 0 },
      responseMimeType: "application/json",
      systemInstruction: "쿠폰 OCR raw text를 아래 JSON 형식으로만 변환하세요. 확인할 수 없는 값은 null로 두고 requiresConfirmation을 true로 설정합니다. 할인 금액이나 조건을 추측하지 마세요. {brand:string|null, productName:string|null, discountType:'fixedAmount'|'percentage'|'productVoucher'|'unknown', discountValue:number|null, minimumOrderAmount:number|null, expiresAt:'YYYY-MM-DD'|null, conditions:string[], requiresConfirmation:boolean}"
    }
  });
  const usage = response.usageMetadata as { promptTokenCount?: number; candidatesTokenCount?: number; totalTokenCount?: number } | undefined;
  recordAIUsage({
    operation: "coupon_ocr_normalization",
    model: GEMINI_MODEL,
    promptTokens: usage?.promptTokenCount,
    outputTokens: usage?.candidatesTokenCount,
    totalTokens: usage?.totalTokenCount
  });
  const text = typeof response.text === "string" ? response.text.trim() : "";
  if (!text) throw new Error("Gemini returned no coupon JSON");
  await checkModelArmorText(text, "response");
  return JSON.parse(text);
}

/** 공공데이터 키를 Cloud Run에서만 사용해 수원시 매장을 반환합니다. */
export async function fetchNearbySuwonStores(lat: number, lon: number, radius: number, query?: string) {
  const configuredServiceKey = process.env.DATA_GO_KR_SERVICE_KEY?.trim();
  if (!configuredServiceKey) throw new Error("DATA_GO_KR_SERVICE_KEY is not configured");

  // data.go.kr offers both an Encoding key and a Decoding key. Normalise either form once,
  // then URLSearchParams encodes it exactly once for the outbound request.
  let serviceKey = configuredServiceKey;
  try { serviceKey = decodeURIComponent(configuredServiceKey); } catch { /* Keep an already-decoded malformed percent literal unchanged. */ }

  // The radius endpoint is paginated by business ID rather than by distance. A single page can
  // contain no coffee franchise at all, even when one is nearby. Scan a bounded set of pages,
  // then cache the resulting target-only directory for the same approximate location.
  const cacheKey = `${lat.toFixed(3)}:${lon.toFixed(3)}:${radius}`;
  const cached = STORE_DIRECTORY_CACHE.get(cacheKey);
  const now = Date.now();
  if (cached && cached.expiresAt > now) {
    return filterStoresByQuery(cached.stores, query);
  }

  const persisted = await loadPersistedStoreDirectory(cacheKey);
  if (persisted) {
    STORE_DIRECTORY_CACHE.set(cacheKey, { expiresAt: persisted.expiresAtMillis, stores: persisted.stores });
    return filterStoresByQuery(persisted.stores, query);
  }

  const fetchPage = async (pageNo: number): Promise<PublicStore[]> => {
    const params = new URLSearchParams({ serviceKey, cx: String(lon), cy: String(lat), radius: String(radius), pageNo: String(pageNo), numOfRows: "100", type: "json" });
    const response = await fetchDataGoWithRetry(`${DATA_GO_KR_BASE_URL}?${params}`);
    if (!response.ok) {
      // Never log the key or full request URL. The encoding classification is enough to diagnose
      // the common Encoding-key double-escape failure.
      console.error("data.go.kr store request rejected", { status: response.status, configuredKeyWasEncoded: configuredServiceKey.includes("%") });
      throw new Error(`data.go.kr request failed: ${response.status}`);
    }
    const payload = await response.json() as { body?: { items?: PublicStore[] | { item?: PublicStore[] } } };
    const rawItems = payload.body?.items;
    return Array.isArray(rawItems) ? rawItems : rawItems?.item ?? [];
  };

  const pages = Array.from({ length: FRANCHISE_DISCOVERY_PAGE_COUNT }, (_, index) => index + 1);
  const pageItems: PublicStore[] = [];
  let successfulPageCount = 0;
  // The portal enforces a strict per-second cap per key. A sequential, paced scan is slower only
  // on the first request for an area; the 10-minute cache and iOS-side location throttle keep it
  // from recurring while a user is moving around the same neighbourhood.
  for (const [index, page] of pages.entries()) {
    try {
      pageItems.push(...await fetchPage(page));
      successfulPageCount += 1;
    } catch (error) {
      // The portal can time out on an individual page. Preserve successful pages instead of
      // turning a real nearby-store result into a 503; MapKit is the immediate device fallback.
      console.warn("data.go.kr store page skipped", { page, reason: error instanceof Error ? error.message : "unknown" });
    }
    if (index < pages.length - 1) await new Promise((resolve) => setTimeout(resolve, 1_050));
  }

  if (successfulPageCount === 0) throw new Error("data.go.kr returned no readable store pages");

  const stores = pageItems
    .map((item) => ({ id: item.bizesId, name: [item.bizesNm, item.brchNm].filter(Boolean).join(" "), category: item.indsMclsNm ?? item.indsLclsNm ?? "기타", address: item.rdnmAdr ?? "", latitude: Number(item.lat), longitude: Number(item.lon) }))
    .filter((store) => Number.isFinite(store.latitude) && Number.isFinite(store.longitude))
    .filter((store) => isWithinSuwon(store.latitude, store.longitude))
    // Only register geofences for franchises whose coupons can be matched in this MVP.
    .filter((store) => isSupportedFranchiseStore(store.name))
    .map((store) => ({ ...store, distanceMeters: distanceMeters(lat, lon, store.latitude, store.longitude) }))
    .sort((left, right) => left.distanceMeters - right.distanceMeters);
  const expiresAt = now + STORE_DIRECTORY_CACHE_TTL_MS;
  STORE_DIRECTORY_CACHE.set(cacheKey, { expiresAt, stores });
  await savePersistedStoreDirectory(cacheKey, stores, expiresAt);
  return filterStoresByQuery(stores, query);
}

app.get("/health", (_req, res) => res.json({ ok: true, service: "couponcok-api" }));

/**
 * Liveness stays independent of optional AI components. Candidate deployment checks this route
 * before it receives traffic, while /health remains safe for platform restarts and probes.
 * Values deliberately expose configuration booleans only: no secret names or endpoints leak.
 */
app.get("/ready", (_req, res) => {
  const adkMode = configuredAdkMode();
  const checks = {
    dataGo: Boolean(process.env.DATA_GO_KR_SERVICE_KEY),
    vertexAI: Boolean(process.env.VERTEX_PROJECT_ID),
    benefitRag: Boolean(process.env.BENEFITS_BUCKET),
    adk: adkMode === "off" || Boolean(process.env.ADK_ORCHESTRATOR_URL && process.env.ADK_INTERNAL_TOKEN),
    dlp: configuredDlpMode() !== "enforce" || Boolean(process.env.DLP_PROJECT_ID ?? process.env.VERTEX_PROJECT_ID),
    modelArmor: configuredModelArmorMode() !== "enforce" || Boolean(process.env.MODEL_ARMOR_TEMPLATE)
  };
  const ready = Object.values(checks).every(Boolean);
  res.status(ready ? 200 : 503).json({ ok: ready, service: "couponcok-api", adkMode, checks });
});

app.get("/v1/stores/nearby", async (req, res) => {
  const latitude = Number(req.query.lat);
  const longitude = Number(req.query.lng);
  const radius = Math.min(Math.max(Number(req.query.radius ?? 1_000), 100), 1_500);
  const query = typeof req.query.query === "string" ? req.query.query : undefined;
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude) || !isWithinSuwon(latitude, longitude)) {
    return res.status(400).json({ error: "lat and lng must point inside Suwon city" });
  }

  try {
    const stores = await traceOperation("tool.search_nearby_stores", {
      "couponcok.region": "수원시",
      "couponcok.radius_m": radius
    }, () => fetchNearbySuwonStores(latitude, longitude, radius, query));
    res.json({
      region: "수원시",
      source: SUWON_STORE_DATA_SOURCE.id,
      sourceMetadata: { ...SUWON_STORE_DATA_SOURCE, retrievedAt: new Date().toISOString() },
      radius,
      discovery: { mode: "supported-franchise", pagesScanned: FRANCHISE_DISCOVERY_PAGE_COUNT },
      stores
    });
  } catch (error) {
    console.error(error);
    res.status(503).json({ error: "store directory is temporarily unavailable" });
  }
});

app.get("/v1/benefits/search", async (req, res) => {
  const query = typeof req.query.query === "string" ? req.query.query.trim() : "";
  if (!query || query.length > 500) return res.status(400).json({ error: "query must be between 1 and 500 characters" });
  try {
    const matches = await traceOperation("tool.retrieve_carrier_benefits", {
      "couponcok.query_length": query.length
    }, () => searchOfficialBenefits(query));
    res.json({ matches: matches.map(({ embedding, ...match }) => match) });
  } catch (error) {
    console.error("Benefit RAG search failed", error);
    res.status(503).json({ error: "official benefits are temporarily unavailable" });
  }
});

app.post("/v1/coupons/normalize", async (req, res) => {
  const rawText = typeof req.body?.rawText === "string" ? req.body.rawText.trim() : "";
  if (!rawText || rawText.length > 5_000) return res.status(400).json({ error: "rawText must be between 1 and 5000 characters" });
  if (!process.env.VERTEX_PROJECT_ID) return res.status(503).json({ error: "coupon normalization is not configured" });
  try {
    res.json({ coupon: await normalizeCouponRawText(rawText) });
  } catch (error) {
    console.error("Coupon normalization failed", error);
    res.status(502).json({ error: "coupon normalization failed" });
  }
});

app.post("/v1/recommendations", async (req: AuthenticatedRequest, res) => {
  const parsed = recommendationRequestSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: "Invalid recommendation request" });
  const input = parsed.data as RecommendationInput;
  const storeName = input.storeName ?? input.storeId;
  const requestId = requestCorrelationID(req);
  const matchedCoupons = input.coupons.filter((coupon) => couponIsActive(coupon) && couponMatchesStore(coupon, storeName));
  if (!matchedCoupons.length) return res.status(422).json({ error: "no registered coupon matches this store" });
  const matchedInput = { ...input, coupons: matchedCoupons };

  let benefitChunks: Awaited<ReturnType<typeof searchOfficialBenefits>> = [];
  if (process.env.BENEFITS_BUCKET) {
    try {
      const benefitQuery = [
        input.profile.carrier,
        input.profile.membershipGrade ?? "",
        ...((input.profile.cards ?? []).flatMap((card) => [card.issuer, card.productName, card.productId])),
        storeName
      ].join(" ");
      benefitChunks = await traceOperation("tool.retrieve_benefits", {
        "couponcok.carrier": input.profile.carrier,
        "couponcok.card_count": input.profile.cards?.length ?? 0,
        "couponcok.store": storeName
      }, () => searchOfficialBenefits(benefitQuery));
    } catch (error) {
      // A temporary RAG outage never lets the LLM invent a discount; coupon-only calculation continues.
      console.error("Benefit RAG unavailable for recommendation", error);
    }
  }
  const [recommendedOption, ...alternatives] = await traceOperation("tool.calculate_best_discount", {
    "couponcok.store": storeName,
    "couponcok.coupon_count": matchedCoupons.length,
    "couponcok.benefit_source_count": benefitChunks.length,
    ...(requestId ? { "couponcok.request_id": requestId } : {})
  }, async () => calculateOptions(matchedInput, matchingBenefitRules(input.profile, storeName, benefitChunks)));
  if (!recommendedOption) return res.status(400).json({ error: "at least one coupon is required" });

  const benefitSources = benefitChunks.map((chunk) => ({
    title: chunk.title,
    provider: chunk.provider,
    sourceURL: chunk.sourceURL,
    checkedAt: chunk.checkedAt,
    effectiveFrom: chunk.effectiveFrom,
    effectiveTo: chunk.effectiveTo,
    version: chunk.version,
    contentHash: chunk.contentHash,
    license: chunk.license
  }));
  let explanation = await createRecommendationExplanation({ storeName, option: recommendedOption, benefitSources });
  const adkMode = configuredAdkMode();
  let agentRun: { mode: typeof adkMode; status: "disabled" | "sampled-out" | "completed" | "contract-rejected" | "failed" } = {
    mode: adkMode,
    status: "disabled"
  };
  const adkRequestId = requestId ?? `${req.firebaseUID ?? "anonymous"}:${storeName}`;
  if (adkMode === "shadow" && !shouldRunAdk(adkMode, adkRequestId)) {
    agentRun = { mode: adkMode, status: "sampled-out" };
  } else if (adkMode !== "off") {
    try {
      const adkResult = await runAdkOrchestration(matchedInput, req.firebaseUID ?? "anonymous", requestId);
      agentRun = { mode: adkMode, status: "completed" };
      if (adkMode === "explanation") {
        if (adkResultMatchesCalculator(adkResult.resultText, recommendedOption.savings, recommendedOption.finalPrice)) {
          explanation = safeRecommendationExplanation(recommendedOption, benefitSources, true);
        } else {
          agentRun = { mode: adkMode, status: "contract-rejected" };
        }
      }
    } catch (error) {
      // ADK is never allowed to break the proven deterministic MVP path.
      console.error("ADK orchestration fallback", error instanceof Error ? error.message : error);
      agentRun = { mode: adkMode, status: "failed" };
    }
  }
  res.json({
    storeName,
    originalPrice: recommendedOption.originalPrice,
    recommendedOption,
    alternatives,
    explanation,
    benefitSources,
    agentRun
  });
});

if (process.env.NODE_ENV !== "test" && process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await initializeObservability();
  app.listen(process.env.PORT || 8080, () => console.log("CouponPilot API listening"));
}
