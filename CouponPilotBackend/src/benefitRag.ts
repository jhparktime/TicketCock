import { Storage } from "@google-cloud/storage";

const INDEX_OBJECT = "benefits/index.json";
const EMBEDDING_MODEL = "gemini-embedding-001";

export type CalculatorBenefitRule = {
  provider: string;
  appliesTo: "carrier";
  discountPercent?: number;
  fixedDiscount?: number;
  maximumDiscount?: number;
  minimumOrderAmount?: number;
  combinableWithCoupon: boolean;
  eligibleGrades?: string[];
  requiresAvailableThisMonth?: boolean;
  eligibleStoreKeywords?: string[];
};

export type BenefitChunk = {
  id: string;
  documentId: string;
  title: string;
  provider: string;
  sourceURL: string;
  text: string;
  embedding: number[];
  rule?: CalculatorBenefitRule;
};

type BenefitDocument = {
  id: string;
  title: string;
  provider: string;
  sourceURL: string;
  content: string;
  rule?: CalculatorBenefitRule;
};

/**
 * Initial official sources for the demo. They are deliberately source-only: the advertised
 * offers are vouchers or product/period dependent, so a price calculator must not invent a won value.
 * Cloud Run persists their embedded chunks to the configured private bucket on first retrieval.
 */
const bundledCarrierBenefits: BenefitDocument[] = [
  {
    id: "skt-tmembership-grade-guide",
    title: "SKT T 멤버십 등급 및 혜택 이용 공식 안내",
    provider: "SKT",
    sourceURL: "https://sktmembership.tworld.co.kr/mps/pc-bff/grade/gradeinfo/gradeInfo.do",
    content: `확인일: 2026-08-11\n제공자: SK텔레콤\n적용 대상: SKT T 멤버십 고객\n\nSK텔레콤의 T 멤버십 공식 안내는 VIP, GOLD, SILVER 등급 체계와 고객별 현재 등급 확인 절차를 제공한다. 제휴 할인·적립과 T day 같은 기간 한정 혜택은 브랜드, 상품, 등급, 사용 횟수와 이벤트 기간에 따라 달라질 수 있다. 따라서 CouponPilot은 매장 진입 시 T 멤버십 공식 안내를 근거로 제시하되, 할인 금액이나 이용 가능 여부를 임의로 계산하지 않는다.\n\n사용자는 T 멤버십 앱 또는 공식 웹의 나의 등급과 해당 브랜드 혜택 페이지에서 이번 달 사용 가능 여부, 행사 기간, 제외 매장을 최종 확인해야 한다. 구조화된 공식 할인 규칙이 등록된 경우에만 계산기 도구가 가격 비교에 사용한다.`
  },
  {
    id: "uplus-vipkok-starbucks",
    title: "LG U+ VIP콕 스타벅스 공식 안내",
    provider: "LG U+",
    sourceURL: "https://m.lguplus.com/membership/intro",
    content: `확인일: 2026-08-10\n제공자: LG U+\n적용 대상: LG U+ VVIP 또는 VIP 멤버십 고객\n\nLG U+ 공식 멤버십 소개는 VVIP/VIP 고객이 매달 VIP콕 혜택 중 하나를 선택할 수 있으며, 선택 가능한 혜택에 스타벅스 아메리카노가 포함될 수 있음을 안내한다. VIP콕은 매달 선택하는 방식이며 영화 예매 등 다른 VIP콕 혜택과 동시에 사용할 수 없는 경우가 있다. 제공 상품, 수량, 선택 가능 여부 및 실제 사용 가능 상태는 월별로 달라질 수 있으므로 U+one 또는 U+멤버십 앱에서 최종 확인해야 한다.\n\n이 문서는 무료 교환권의 현금 가치를 임의로 계산하지 않는다. CouponPilot은 매장 진입 시 공식 근거와 확인 필요 조건을 안내하며, 사용자가 이번 달 선택 가능 상태를 직접 확인한 뒤 혜택을 사용한다.`
  },
  {
    id: "kt-megabox-membership",
    title: "KT 멤버십 메가박스 제휴 혜택",
    provider: "KT",
    sourceURL: "https://membership.kt.com/discount/partner/C23/67/PartnerDetail.do",
    content: `확인일: 2026-08-10\n제공자: KT\n적용 대상: KT 멤버십 고객\n\nKT 멤버십 공식 제휴 브랜드 안내는 메가박스 영화 예매와 매점 콤보에 대한 멤버십 혜택을 별도로 설명한다. 영화 예매 혜택은 상영관과 요일, 티켓 금액에 따라 할인 금액이 달라질 수 있고, 매점 콤보는 지정 상품과 주문 방식에 따라 적용 조건이 다르다. 따라서 CouponPilot은 가격 입력만으로 최대 할인 금액을 확정하지 않으며, KT 멤버십 앱 또는 웹에서 상품과 잔여 혜택을 최종 확인하도록 안내한다.\n\n이 문서는 공식 혜택의 출처와 조건을 검색하기 위한 RAG 문서다. 정확한 상품 종류·회차·월별 이용 한도가 모두 확인된 구조화 규칙이 등록될 때만 계산기에 할인 규칙을 연결한다.`
  }
];

let bundleSeedPromise: Promise<BenefitChunk[]> | undefined;
// Cloud Storage is the durable index. Keep a process-local copy only when a first-run
// write is blocked by IAM, so the user still receives official source links instead of
// an invented benefit. A later deployment or request retries durable seeding.
let runtimeMemoryIndex: BenefitChunk[] = [];

function bucketName() {
  const value = process.env.BENEFITS_BUCKET;
  if (!value) throw new Error("BENEFITS_BUCKET is not configured");
  return value;
}

function storage() { return new Storage(); }

function chunks(content: string, length = 900, overlap = 150) {
  const normalized = content.replace(/\r\n/g, "\n").trim();
  const results: string[] = [];
  for (let start = 0; start < normalized.length; start += length - overlap) {
    const part = normalized.slice(start, start + length).trim();
    if (part.length >= 60) results.push(part);
    if (start + length >= normalized.length) break;
  }
  return results;
}

async function embeddingsFor(values: string[]) {
  const project = process.env.VERTEX_PROJECT_ID;
  if (!project) throw new Error("VERTEX_PROJECT_ID is not configured");
  const { GoogleGenAI } = await import("@google/genai");
  const client = new GoogleGenAI({ vertexai: true, project, location: process.env.VERTEX_LOCATION ?? "global" });
  const response = await client.models.embedContent({
    model: EMBEDDING_MODEL,
    contents: values,
    config: { outputDimensionality: 768 }
  });
  const embeddings = response.embeddings ?? [];
  if (embeddings.length !== values.length) throw new Error("Unexpected embedding response");
  return embeddings.map((embedding) => embedding.values ?? []);
}

async function loadIndex(): Promise<BenefitChunk[]> {
  if (runtimeMemoryIndex.length) return runtimeMemoryIndex;
  try {
    const file = storage().bucket(bucketName()).file(INDEX_OBJECT);
    const [exists] = await file.exists();
    if (!exists) return [];
    const [body] = await file.download();
    const parsed = JSON.parse(body.toString("utf8")) as { chunks?: BenefitChunk[] };
    return Array.isArray(parsed.chunks) ? parsed.chunks : [];
  } catch (error) {
    console.warn("Benefit index read unavailable; attempting bundled official documents", error instanceof Error ? error.message : error);
    return [];
  }
}

async function saveIndex(index: BenefitChunk[]) {
  await storage().bucket(bucketName()).file(INDEX_OBJECT).save(JSON.stringify({ version: 1, updatedAt: new Date().toISOString(), chunks: index }), {
    contentType: "application/json",
    resumable: false
  });
}

function similarity(a: number[], b: number[]) {
  let dot = 0, normA = 0, normB = 0;
  for (let index = 0; index < Math.min(a.length, b.length); index += 1) {
    dot += a[index] * b[index]; normA += a[index] ** 2; normB += b[index] ** 2;
  }
  return dot / (Math.sqrt(normA) * Math.sqrt(normB) || 1);
}

/**
 * The recommendation flow always includes the profile's carrier in its query. When that
 * carrier is explicit, do not show a semantically-similar benefit from another carrier as
 * evidence. Generic queries still use the whole vector index.
 */
function explicitlyRequestedProviders(query: string) {
  const normalized = query.toLocaleLowerCase("ko-KR").replace(/[^\p{L}\p{N}]/gu, "");
  const lowercased = query.toLocaleLowerCase("ko-KR");
  const providers: string[] = [];
  if (["skt", "sk텔레콤", "t멤버십"].some((token) => normalized.includes(token))) providers.push("SKT");
  // Do not test normalized text for bare "kt": it is contained in "skt".
  if (normalized.includes("케이티") || normalized.includes("kt멤버십") || /(?:^|\s)kt(?:$|\s)/u.test(lowercased)) providers.push("KT");
  if (["lgu", "lg유플러스", "u멤버십", "uplus"].some((token) => normalized.includes(token))) providers.push("LG U+");
  return providers;
}

export async function searchOfficialBenefits(query: string, limit = 4) {
  let index = await loadIndex();
  if (!index.length) index = await seedBundledCarrierBenefits();
  if (!index.length) return [];
  const explicitProviders = explicitlyRequestedProviders(query);
  const candidates = explicitProviders.length
    ? index.filter((chunk) => explicitProviders.includes(chunk.provider))
    : index;
  const [queryEmbedding] = await embeddingsFor([query]);
  return candidates
    .map((chunk) => ({ ...chunk, score: similarity(queryEmbedding, chunk.embedding) }))
    .sort((left, right) => right.score - left.score)
    .slice(0, limit);
}

async function seedBundledCarrierBenefits(): Promise<BenefitChunk[]> {
  if (!bundleSeedPromise) {
    bundleSeedPromise = (async () => {
      const current = await loadIndex();
      if (current.length) return current;

      // This is intentionally a create-once batch. The runtime identity only needs Object Viewer
      // and Object Creator, not overwrite or delete privileges, for the first demo index.
      const parts = bundledCarrierBenefits.flatMap((document) => chunks(document.content).map((text, partIndex) => ({ document, text, partIndex })));
      const vectors = await embeddingsFor(parts.map((part) => part.text));
      const nextIndex: BenefitChunk[] = parts.map((part, index) => ({
        id: `${part.document.id}-${part.partIndex + 1}`,
        documentId: part.document.id,
        title: part.document.title,
        provider: part.document.provider,
        sourceURL: part.document.sourceURL,
        text: part.text,
        embedding: vectors[index]
      }));
      runtimeMemoryIndex = nextIndex;
      try {
        const bucket = storage().bucket(bucketName());
        for (const document of bundledCarrierBenefits) {
          await bucket.file(`benefits/documents/${document.id}.md`).save(document.content, {
            contentType: "text/markdown; charset=utf-8", resumable: false, preconditionOpts: { ifGenerationMatch: 0 }
          });
        }
        await bucket.file(INDEX_OBJECT).save(JSON.stringify({ version: 1, updatedAt: new Date().toISOString(), chunks: nextIndex }), {
          contentType: "application/json", resumable: false, preconditionOpts: { ifGenerationMatch: 0 }
        });
      } catch (error) {
        console.warn("Benefit index is running from bundled official documents until Cloud Storage write access is granted", error instanceof Error ? error.message : error);
      }
      return nextIndex;
    })().catch((error) => {
      // Do not cache a transient IAM or Vertex failure forever; a later request can retry.
      bundleSeedPromise = undefined;
      throw error;
    });
  }
  return bundleSeedPromise;
}

export async function ingestOfficialBenefit(document: BenefitDocument) {
  if (!document.sourceURL.startsWith("https://")) throw new Error("An official https source URL is required");
  const documentChunks = chunks(document.content);
  if (!documentChunks.length) throw new Error("Document needs at least 60 characters of benefit text");
  const vectors = await embeddingsFor(documentChunks);
  const nextChunks: BenefitChunk[] = documentChunks.map((text, index) => ({
    id: `${document.id}-${index + 1}`, documentId: document.id, title: document.title,
    provider: document.provider, sourceURL: document.sourceURL, text, embedding: vectors[index], rule: document.rule
  }));
  const bucket = storage().bucket(bucketName());
  await bucket.file(`benefits/documents/${document.id}.md`).save(document.content, { contentType: "text/markdown; charset=utf-8", resumable: false });
  const current = await loadIndex();
  await saveIndex([...current.filter((chunk) => chunk.documentId !== document.id), ...nextChunks]);
  return { documentId: document.id, chunkCount: nextChunks.length };
}
