import express, { type NextFunction, type Request, type Response } from "express";
import { getApps, initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";
import { searchOfficialBenefits, type CalculatorBenefitRule } from "./benefitRag.js";

export const app = express();
app.use(express.json());

const SUWON_BOUNDS = { minLat: 37.18, maxLat: 37.34, minLon: 126.90, maxLon: 127.15 };
const DATA_GO_KR_BASE_URL = "https://apis.data.go.kr/B553077/api/open/sdsc2/storeListInRadius";
const GEMINI_MODEL = "gemini-2.5-flash";
const FRANCHISE_DISCOVERY_PAGE_COUNT = 20;
const STORE_DIRECTORY_CACHE_TTL_MS = 10 * 60 * 1_000;
const STORE_DIRECTORY_CACHE = new Map<string, { expiresAt: number; stores: ReturnedStore[] }>();
const DATA_GO_REQUEST_TIMEOUT_MS = 6_000;

type PublicStore = {
  bizesId: string; bizesNm: string; brchNm?: string; indsLclsNm?: string; indsMclsNm?: string;
  signguNm?: string; rdnmAdr?: string; lon: string | number; lat: string | number;
};

type ReturnedStore = {
  id: string; name: string; category: string; address: string; latitude: number; longitude: number; distanceMeters: number;
};

type AuthenticatedRequest = Request & { firebaseUID?: string };

type PersistedStoreDirectory = {
  expiresAtMillis: number;
  stores: ReturnedStore[];
};

/** Cloud Run is public only as a transport; every business endpoint verifies a Firebase ID token here. */
async function requireFirebaseAuth(req: AuthenticatedRequest, res: Response, next: NextFunction) {
  if (process.env.NODE_ENV === "test") {
    req.firebaseUID = "test-user";
    return next();
  }
  // Only the API Gateway service account can invoke this private Cloud Run service. After
  // Gateway verifies the Firebase JWT, it forwards the verified Firebase payload in this header.
  const gatewayUserInfo = req.header("x-apigateway-api-userinfo");
  if (gatewayUserInfo) {
    try {
      const payload = JSON.parse(Buffer.from(gatewayUserInfo, "base64url").toString("utf8")) as { user_id?: string; sub?: string };
      const uid = payload.user_id ?? payload.sub;
      if (uid) {
        req.firebaseUID = uid;
        return next();
      }
    } catch { /* Fall through to direct Firebase token verification. */ }
  }
  // Direct calls are useful for local development; production traffic is normally Gateway-routed.
  const header = req.header("x-forwarded-authorization") ?? req.header("authorization") ?? "";
  const idToken = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  if (!idToken) return res.status(401).json({ error: "Firebase ID token is required" });
  try {
    if (!getApps().length) initializeApp();
    req.firebaseUID = (await getAuth().verifyIdToken(idToken, true)).uid;
    next();
  } catch (error) {
    console.warn("Rejected Firebase token", error instanceof Error ? error.message : error);
    res.status(401).json({ error: "Invalid or revoked Firebase ID token" });
  }
}

app.use("/v1", requireFirebaseAuth);

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
      source: "data.go.kr",
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

function fallbackExplanation(option: { title: string; savings: number }) {
  return `${option.title} 조합이 계산기 기준으로 ${option.savings.toLocaleString("ko-KR")}원을 절약해 가장 유리합니다.`;
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
async function createRecommendationExplanation(input: { storeName: string; option: { title: string; savings: number; finalPrice: number }; benefitContext: string }) {
  if (!process.env.VERTEX_PROJECT_ID) return fallbackExplanation(input.option);
  try {
    const client = await geminiClient();
    const response = await client.models.generateContent({
      model: GEMINI_MODEL,
      contents: `매장: ${input.storeName}\n계산기로 확정된 추천: ${input.option.title}\n절약액: ${input.option.savings}원\n최종가: ${input.option.finalPrice}원\n공식 혜택 RAG 근거:\n${input.benefitContext || "등록된 공식 혜택 문서 없음"}`,
      config: {
        temperature: 0.1,
        maxOutputTokens: 160,
        thinkingConfig: { thinkingBudget: 0 },
        systemInstruction: "당신은 쿠폰 추천 결과를 한 문장 한국어로 설명합니다. 공식 혜택 RAG 근거는 출처 문구를 확인하는 데만 활용하고, 제공된 계산기 결과만 사용하세요. 할인액, 최종가, 순위, 중복 가능 여부를 새로 추정하거나 바꾸지 마세요."
      }
    });
    const explanation = typeof response.text === "string" ? response.text.trim() : "";
    return explanation.length >= 12 && explanation.includes("원") ? explanation : fallbackExplanation(input.option);
  } catch (error) {
    console.error("Gemini explanation fallback", error);
    return fallbackExplanation(input.option);
  }
}

/** iPhone Vision OCR의 raw text만 받아 쿠폰 스키마로 정규화합니다. 이미지는 서버에 전달하지 않습니다. */
async function normalizeCouponRawText(rawText: string) {
  const client = await geminiClient();
  const response = await client.models.generateContent({
    model: GEMINI_MODEL,
    contents: `다음은 쿠폰에서 기기 내 OCR로 추출한 텍스트입니다.\n---\n${rawText}\n---`,
    config: {
      temperature: 0,
      maxOutputTokens: 700,
      thinkingConfig: { thinkingBudget: 0 },
      responseMimeType: "application/json",
      systemInstruction: "쿠폰 OCR raw text를 아래 JSON 형식으로만 변환하세요. 확인할 수 없는 값은 null로 두고 requiresConfirmation을 true로 설정합니다. 할인 금액이나 조건을 추측하지 마세요. {brand:string|null, productName:string|null, discountType:'fixedAmount'|'percentage'|'productVoucher'|'unknown', discountValue:number|null, minimumOrderAmount:number|null, expiresAt:'YYYY-MM-DD'|null, conditions:string[], requiresConfirmation:boolean}"
    }
  });
  const text = typeof response.text === "string" ? response.text.trim() : "";
  if (!text) throw new Error("Gemini returned no coupon JSON");
  return JSON.parse(text);
}

/** 공공데이터 키를 Cloud Run에서만 사용해 수원시 매장을 반환합니다. */
async function fetchNearbySuwonStores(lat: number, lon: number, radius: number, query?: string) {
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

type Coupon = { id: string; brand: string; title: string; discountType: "fixedAmount" | "percentage"; discountValue: number; minimumOrderAmount: number; combinableWithCard: boolean; referencePrice?: number };
type RequestBody = {
  storeId: string;
  storeName?: string;
  expectedPrice: number;
  profile: { carrier: string; membershipGrade?: string; monthlyBenefitStatus?: "available" | "used" | "unknown" };
  coupons: Coupon[];
};

function normalizedBrand(value: string) {
  return value.toLocaleLowerCase("ko-KR").replace(/[^\p{L}\p{N}]/gu, "");
}

/** iOS의 SupportedFranchise와 같은 10개 대상 매장 별칭입니다. */
const SUPPORTED_FRANCHISE_ALIASES: Record<string, string[]> = {
  "스타벅스": ["스타벅스", "starbucks"],
  "투썸플레이스": ["투썸플레이스", "투썸", "twosomeplace", "twosome"],
  "메가MGC커피": ["메가mgc커피", "메가커피", "megacoffee", "mgccoffee"],
  "이디야": ["이디야", "이디야커피", "ediya"],
  "컴포즈커피": ["컴포즈커피", "컴포즈", "composecoffee"],
  "빽다방": ["빽다방", "paikscoffee", "paikdabang"],
  "할리스": ["할리스", "할리스커피", "hollys"],
  "커피빈": ["커피빈", "coffeebean"],
  "공차": ["공차", "gongcha"],
  "더벤티": ["더벤티", "theventi"],
  "베스킨라빈스": ["베스킨라빈스", "배스킨라빈스", "baskinrobbins", "baskin"],
  "파리바게뜨": ["파리바게뜨", "파리바게트", "parisbaguette"],
  "뚜레쥬르": ["뚜레쥬르", "touslesjours"],
  "애슐리 퀸즈": ["애슐리퀸즈", "애슐리 퀸즈", "ashleyqueens", "ashley"]
};

function isSupportedFranchiseStore(storeName: string) {
  const store = normalizedBrand(storeName);
  return Object.values(SUPPORTED_FRANCHISE_ALIASES)
    .flat()
    .map(normalizedBrand)
    .some((alias) => store.includes(alias));
}

function couponMatchesStore(coupon: Coupon, storeName: string) {
  const brand = normalizedBrand(coupon.brand);
  const store = normalizedBrand(storeName);
  if (brand.length < 2 || ["기타", "전체", "all"].includes(brand)) return false;
  const supported = Object.entries(SUPPORTED_FRANCHISE_ALIASES).find(([, aliases]) => aliases.map(normalizedBrand).some((alias) => brand.includes(alias) || alias.includes(brand)));
  if (supported) return supported[1].map(normalizedBrand).some((alias) => store.includes(alias));
  if (store.includes(brand) || brand.includes(store)) return true;
  return false;
}

function savingFromRule(rule: CalculatorBenefitRule, price: number, couponSaving: number) {
  if (price < (rule.minimumOrderAmount ?? 0)) return 0;
  if (couponSaving > 0 && !rule.combinableWithCoupon) return 0;
  const base = price - couponSaving;
  const raw = rule.fixedDiscount ?? (rule.discountPercent ? Math.floor(base * rule.discountPercent / 100) : 0);
  return Math.max(0, Math.min(raw, rule.maximumDiscount ?? raw));
}

function matchingBenefitRules(profile: RequestBody["profile"], storeName: string, chunks: Awaited<ReturnType<typeof searchOfficialBenefits>>) {
  const unique = new Map<string, CalculatorBenefitRule>();
  for (const chunk of chunks) {
    const rule = chunk.rule;
    const matchesCarrier = rule && profile.carrier === rule.provider;
    const matchesGrade = !rule?.eligibleGrades?.length || rule.eligibleGrades.includes(profile.membershipGrade ?? "확인 필요");
    const matchesAvailability = !rule?.requiresAvailableThisMonth || profile.monthlyBenefitStatus === "available";
    const normalizedStore = normalizedBrand(storeName);
    const matchesStore = !rule?.eligibleStoreKeywords?.length || rule.eligibleStoreKeywords.some((keyword) => normalizedStore.includes(normalizedBrand(keyword)));
    if (matchesCarrier && matchesGrade && matchesAvailability && matchesStore) unique.set(`${rule!.appliesTo}:${rule!.provider}:${rule!.eligibleStoreKeywords?.join("-") ?? "all"}`, rule!);
  }
  return [...unique.values()];
}

/** 결정론적 계산기 Tool: LLM이 할인액 또는 순위를 추정하지 않도록 분리한다. */
function calculateOptions(input: RequestBody, benefitRules: CalculatorBenefitRule[]) {
  const { expectedPrice, coupons } = input;
  const options = coupons.map((coupon) => {
    const basePrice = Number.isInteger(coupon.referencePrice) && coupon.referencePrice! > 0 ? coupon.referencePrice! : expectedPrice;
    const couponSaving = basePrice >= coupon.minimumOrderAmount
      ? coupon.discountType === "fixedAmount" ? coupon.discountValue : Math.min(Math.floor(basePrice * coupon.discountValue / 100), 2_000)
      : 0;
    const applicableRules = benefitRules.map((rule) => ({ rule, saving: savingFromRule(rule, basePrice, couponSaving) })).filter((entry) => entry.saving > 0);
    const bestBenefit = applicableRules.sort((a, b) => b.saving - a.saving)[0];
    const benefitSaving = bestBenefit?.saving ?? 0;
    const benefitTitle = bestBenefit ? ` + ${bestBenefit.rule.provider}` : "";
    return { id: coupon.id, title: `${coupon.title}${benefitTitle}`, originalPrice: basePrice, finalPrice: basePrice - couponSaving - benefitSaving, savings: couponSaving + benefitSaving, badges: bestBenefit ? ["쿠폰", "통신사 공식혜택"] : ["쿠폰"] };
  });
  for (const rule of benefitRules) {
    const saving = savingFromRule(rule, expectedPrice, 0);
    if (saving > 0) options.push({ id: `benefit-${rule.appliesTo}-${rule.provider}`, title: `${rule.provider} 공식 혜택`, originalPrice: expectedPrice, finalPrice: expectedPrice - saving, savings: saving, badges: ["통신사 공식혜택"] });
  }
  return options.sort((a, b) => b.savings - a.savings);
}

app.get("/health", (_req, res) => res.json({ ok: true }));

app.get("/v1/stores/nearby", async (req, res) => {
  const latitude = Number(req.query.lat);
  const longitude = Number(req.query.lng);
  const radius = Math.min(Math.max(Number(req.query.radius ?? 1_000), 100), 1_500);
  const query = typeof req.query.query === "string" ? req.query.query : undefined;
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude) || !isWithinSuwon(latitude, longitude)) {
    return res.status(400).json({ error: "lat and lng must point inside Suwon city" });
  }

  try {
    const stores = await fetchNearbySuwonStores(latitude, longitude, radius, query);
    res.json({ region: "수원시", source: "data.go.kr", radius, discovery: { mode: "supported-franchise", pagesScanned: FRANCHISE_DISCOVERY_PAGE_COUNT }, stores });
  } catch (error) {
    console.error(error);
    res.status(503).json({ error: "store directory is temporarily unavailable" });
  }
});

app.get("/v1/benefits/search", async (req, res) => {
  const query = typeof req.query.query === "string" ? req.query.query.trim() : "";
  if (!query || query.length > 500) return res.status(400).json({ error: "query must be between 1 and 500 characters" });
  try {
    const matches = await searchOfficialBenefits(query);
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

app.post("/v1/recommendations", async (req, res) => {
  const input = req.body as RequestBody;
  if (!input.storeId || !Number.isInteger(input.expectedPrice) || input.expectedPrice <= 0) return res.status(400).json({ error: "storeId and positive integer expectedPrice are required" });
  const storeName = input.storeName ?? input.storeId;
  const matchedCoupons = input.coupons.filter((coupon) => couponMatchesStore(coupon, storeName));
  if (!matchedCoupons.length) return res.status(422).json({ error: "no registered coupon matches this store" });
  const matchedInput = { ...input, coupons: matchedCoupons };

  let benefitChunks: Awaited<ReturnType<typeof searchOfficialBenefits>> = [];
  if (process.env.BENEFITS_BUCKET) {
    try {
      benefitChunks = await searchOfficialBenefits([input.profile.carrier, input.profile.membershipGrade ?? "", storeName].join(" "));
    } catch (error) {
      // A temporary RAG outage never lets the LLM invent a discount; coupon-only calculation continues.
      console.error("Benefit RAG unavailable for recommendation", error);
    }
  }
  const [recommendedOption, ...alternatives] = calculateOptions(matchedInput, matchingBenefitRules(input.profile, storeName, benefitChunks));
  if (!recommendedOption) return res.status(400).json({ error: "at least one coupon is required" });

  const benefitContext = benefitChunks.map((chunk) => `[${chunk.provider}] ${chunk.text.slice(0, 280)} (${chunk.sourceURL})`).join("\n");
  const explanation = await createRecommendationExplanation({ storeName, option: recommendedOption, benefitContext });
  res.json({ storeName, originalPrice: recommendedOption.originalPrice, recommendedOption, alternatives, explanation, benefitSources: benefitChunks.map((chunk) => ({ title: chunk.title, provider: chunk.provider, sourceURL: chunk.sourceURL })) });
});

if (process.env.NODE_ENV !== "test") {
  app.listen(process.env.PORT || 8080, () => console.log("CouponPilot API listening"));
}
