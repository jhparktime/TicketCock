import { z } from "zod";

/**
 * External maps are evidence only. They never create discount rules, replace the
 * data.go.kr directory, or receive an iPhone's precise location.
 */
const GOOGLE_MAPS_MCP_ENDPOINT = "https://mapstools.googleapis.com/mcp";
const KAKAO_LOCAL_KEYWORD_ENDPOINT = "https://dapi.kakao.com/v2/local/search/keyword.json";
const REQUEST_TIMEOUT_MS = 4_000;

export type ExternalMapProvider = "google-maps-mcp" | "kakao-local-api" | "unavailable";
export type ExternalMapStatus = "verified" | "fallback_verified" | "not_configured" | "unavailable";

export type ExternalPlaceVerification = {
  provider: ExternalMapProvider;
  status: ExternalMapStatus;
  query: string;
  /** 0.01-degree grid (~1 km). The source never receives device-precision GPS. */
  coarseLatitude: number;
  coarseLongitude: number;
  attributionURLs: string[];
  candidateCount: number;
  policy: string;
};

export type ExternalPlaceInput = {
  storeName: string;
  latitude: number;
  longitude: number;
  radiusMeters: number;
};

const kakaoResponseSchema = z.object({
  documents: z.array(z.object({
    place_name: z.string().optional(),
    place_url: z.string().url().optional()
  }).passthrough()).max(45).default([])
}).passthrough();

function coarseCoordinate(value: number) {
  return Math.round(value * 100) / 100;
}

function buildQuery(storeName: string) {
  const normalized = storeName.replace(/\s+/gu, " ").trim();
  return `${normalized} 대한민국`;
}

function cappedRadius(radiusMeters: number) {
  return Math.min(1_500, Math.max(1_000, Math.round(radiusMeters)));
}

function emptyResult(input: ExternalPlaceInput, status: ExternalMapStatus, policy: string): ExternalPlaceVerification {
  return {
    provider: "unavailable",
    status,
    query: buildQuery(input.storeName),
    coarseLatitude: coarseCoordinate(input.latitude),
    coarseLongitude: coarseCoordinate(input.longitude),
    attributionURLs: [],
    candidateCount: 0,
    policy
  };
}

/** Extract only citation URLs from untrusted MCP text; never pass its free-form prose to an Agent. */
function mapURLs(value: unknown) {
  const serialized = JSON.stringify(value);
  const urls = serialized.match(/https:\/\/[^\s"\\]+/gu) ?? [];
  return [...new Set(urls.filter((url) => {
    try {
      const hostname = new URL(url).hostname;
      return hostname === "maps.google.com" || hostname.endsWith("google.com");
    } catch {
      return false;
    }
  }))].slice(0, 5);
}

async function googleMapsMcpSearch(input: ExternalPlaceInput, apiKey: string): Promise<ExternalPlaceVerification> {
  const query = buildQuery(input.storeName);
  const response = await fetch(GOOGLE_MAPS_MCP_ENDPOINT, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
      "x-goog-api-key": apiKey
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: "couponcok-place-verification",
      method: "tools/call",
      params: {
        name: "search_places",
        arguments: {
          textQuery: query,
          languageCode: "ko",
          regionCode: "KR",
          locationBias: {
            circle: {
              center: { latitude: coarseCoordinate(input.latitude), longitude: coarseCoordinate(input.longitude) },
              radiusMeters: cappedRadius(input.radiusMeters)
            }
          }
        }
      }
    }),
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS)
  });
  if (!response.ok) throw new Error(`Google Maps MCP HTTP ${response.status}`);
  const body = await response.json() as { result?: { content?: unknown[] }; error?: unknown };
  if (body.error || !Array.isArray(body.result?.content)) throw new Error("Google Maps MCP returned no tool result");
  return {
    provider: "google-maps-mcp",
    status: "verified",
    query,
    coarseLatitude: coarseCoordinate(input.latitude),
    coarseLongitude: coarseCoordinate(input.longitude),
    attributionURLs: mapURLs(body.result.content),
    candidateCount: body.result.content.length,
    policy: "Google Maps 외부 MCP는 매장 식별 보조 근거입니다. data.go.kr 매장 원본과 할인 계산 결과를 변경할 수 없습니다."
  };
}

async function kakaoFallbackSearch(input: ExternalPlaceInput, restApiKey: string): Promise<ExternalPlaceVerification> {
  const query = buildQuery(input.storeName);
  const url = new URL(KAKAO_LOCAL_KEYWORD_ENDPOINT);
  url.searchParams.set("query", query);
  url.searchParams.set("x", String(coarseCoordinate(input.longitude)));
  url.searchParams.set("y", String(coarseCoordinate(input.latitude)));
  url.searchParams.set("radius", String(cappedRadius(input.radiusMeters)));
  url.searchParams.set("size", "5");
  const response = await fetch(url, {
    headers: { Authorization: `KakaoAK ${restApiKey}` },
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS)
  });
  if (!response.ok) throw new Error(`Kakao Local API HTTP ${response.status}`);
  const body = kakaoResponseSchema.parse(await response.json());
  return {
    provider: "kakao-local-api",
    status: "fallback_verified",
    query,
    coarseLatitude: coarseCoordinate(input.latitude),
    coarseLongitude: coarseCoordinate(input.longitude),
    attributionURLs: body.documents.flatMap((document) => document.place_url ? [document.place_url] : []).slice(0, 5),
    candidateCount: body.documents.length,
    policy: "카카오 공식 Local REST API fallback입니다. data.go.kr 매장 원본과 할인 계산 결과를 변경할 수 없습니다."
  };
}

export async function verifyStoreWithExternalMaps(input: ExternalPlaceInput): Promise<ExternalPlaceVerification> {
  const googleMapsApiKey = process.env.GOOGLE_MAPS_API_KEY?.trim();
  const kakaoRestApiKey = process.env.KAKAO_REST_API_KEY?.trim();
  if (googleMapsApiKey) {
    try {
      return await googleMapsMcpSearch(input, googleMapsApiKey);
    } catch (error) {
      console.warn("Google Maps MCP verification unavailable", error instanceof Error ? error.message : "unknown");
    }
  }
  if (kakaoRestApiKey) {
    try {
      return await kakaoFallbackSearch(input, kakaoRestApiKey);
    } catch (error) {
      console.warn("Kakao Local fallback unavailable", error instanceof Error ? error.message : "unknown");
    }
  }
  return emptyResult(
    input,
    googleMapsApiKey || kakaoRestApiKey ? "unavailable" : "not_configured",
    "외부 지도 소스가 없거나 응답하지 않아 매장 식별은 data.go.kr 원본만 사용합니다."
  );
}
