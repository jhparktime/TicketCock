import assert from "node:assert/strict";
import {
  calculateOptions,
  couponMatchesStore,
  matchingBenefitRules,
  type Coupon,
  type RecommendationInput
} from "../src/calculator.js";
import { validateBenefitDocument, type BenefitChunk, type CalculatorBenefitRule } from "../src/benefitRag.js";
import { findSensitiveValue } from "../src/privacy.js";

/**
 * Closed-beta release gate.
 *
 * These cases deliberately avoid live LLM, Firestore and public-API calls. A pull request must
 * prove that money, matching and privacy decisions remain deterministic before a shadow Agent
 * is allowed to explain the result. The named cases are also the source of truth for the beta
 * evaluation inventory in Docs/INTEGRATED_AGENTIC_SERVICE_BLUEPRINT.md.
 */

const baseProfile: RecommendationInput["profile"] = { carrier: "없음" };

function coupon(overrides: Partial<Coupon> = {}): Coupon {
  return {
    id: "coupon",
    brand: "투썸플레이스",
    title: "테스트 쿠폰",
    discountType: "fixedAmount",
    discountValue: 1_000,
    minimumOrderAmount: 0,
    combinableWithCard: false,
    ...overrides
  };
}

function recommendation(coupons: Coupon[], expectedPrice = 10_000, profile = baseProfile): RecommendationInput {
  return {
    storeId: "twosome-suwon",
    storeName: "투썸플레이스 수원점",
    expectedPrice,
    profile,
    coupons
  };
}

function calculate(input: RecommendationInput, rules: CalculatorBenefitRule[] = []) {
  return calculateOptions(input, rules);
}

function activeRule(rule: CalculatorBenefitRule): BenefitChunk {
  return {
    id: "benefit-1",
    documentId: "benefit-1",
    title: "공식 혜택",
    provider: rule.provider,
    sourceURL: rule.provider === "SKT" ? "https://sktmembership.tworld.co.kr/official" : "https://www.shinhancard.com/official",
    text: "공식 혜택 조건",
    embedding: [0.1],
    rule
  };
}

let count = 0;
function golden(id: string, run: () => void) {
  try {
    run();
    count += 1;
  } catch (error) {
    throw new Error(`Golden case failed: ${id}`, { cause: error });
  }
}

// 22 Calculator exact-match cases ---------------------------------------------------------------
golden("CAL-01-fixed-discount", () => assert.equal(calculate(recommendation([coupon()]))[0].finalPrice, 9_000));
golden("CAL-02-fixed-discount-capped-at-price", () => assert.equal(calculate(recommendation([coupon({ discountValue: 20_000 })], 10_000))[0].finalPrice, 0));
golden("CAL-03-minimum-order-not-met", () => assert.equal(calculate(recommendation([coupon({ minimumOrderAmount: 10_001 })]))[0].savings, 0));
golden("CAL-04-percent-discount", () => assert.equal(calculate(recommendation([coupon({ discountType: "percentage", discountValue: 20 })]))[0].savings, 2_000));
golden("CAL-05-percent-maximum-cap", () => assert.equal(calculate(recommendation([coupon({ discountType: "percentage", discountValue: 20, maximumDiscount: 1_500 })]))[0].savings, 1_500));
golden("CAL-06-percent-rounds-down", () => assert.equal(calculate(recommendation([coupon({ discountType: "percentage", discountValue: 33 })], 101))[0].savings, 33));
golden("CAL-07-reference-price-is-authoritative", () => assert.equal(calculate(recommendation([coupon({ referencePrice: 5_100, discountValue: 2_000 })], 15_000))[0].finalPrice, 3_100));
golden("CAL-08-expired-coupon-is-excluded", () => assert.equal(calculate(recommendation([coupon({ expiresAt: "2020-01-01T00:00:00.000Z" })])).length, 0));
golden("CAL-09-future-coupon-is-included", () => assert.equal(calculate(recommendation([coupon({ expiresAt: "2099-01-01T00:00:00.000Z" })])).length, 1));
golden("CAL-10-best-of-two-coupons", () => assert.equal(calculate(recommendation([coupon({ id: "one", discountValue: 1_000 }), coupon({ id: "two", discountValue: 2_000 })]))[0].id, "two"));
golden("CAL-11-equal-savings-keeps-stable-order", () => assert.equal(calculate(recommendation([coupon({ id: "first" }), coupon({ id: "second" })]))[0].id, "first"));
golden("CAL-12-non-combinable-carrier-stays-separate", () => {
  const rule: CalculatorBenefitRule = { provider: "SKT", appliesTo: "carrier", fixedDiscount: 2_000, combinableWithCoupon: false, eligibleStoreKeywords: ["투썸플레이스"] };
  const options = calculate(recommendation([coupon({ discountValue: 1_000 })], 10_000), [rule]);
  assert.equal(options[0].id, "benefit-carrier-SKT");
  assert.equal(options[0].savings, 2_000);
});
golden("CAL-13-combinable-carrier-adds-savings", () => {
  const rule: CalculatorBenefitRule = { provider: "SKT", appliesTo: "carrier", fixedDiscount: 2_000, combinableWithCoupon: true, eligibleStoreKeywords: ["투썸플레이스"] };
  assert.equal(calculate(recommendation([coupon({ discountValue: 1_000 })], 10_000), [rule])[0].savings, 3_000);
});
golden("CAL-14-carrier-percent-cap", () => {
  const rule: CalculatorBenefitRule = { provider: "SKT", appliesTo: "carrier", discountPercent: 30, maximumDiscount: 2_000, combinableWithCoupon: true, eligibleStoreKeywords: ["투썸플레이스"] };
  assert.equal(calculate(recommendation([], 10_000), [rule])[0].savings, 2_000);
});
golden("CAL-15-carrier-minimum-order", () => {
  const rule: CalculatorBenefitRule = { provider: "SKT", appliesTo: "carrier", fixedDiscount: 2_000, minimumOrderAmount: 10_001, combinableWithCoupon: true, eligibleStoreKeywords: ["투썸플레이스"] };
  assert.equal(calculate(recommendation([], 10_000), [rule]).length, 0);
});
golden("CAL-16-card-remaining-limit-caps-benefit", () => {
  const profile: RecommendationInput["profile"] = { carrier: "없음", cards: [{ issuer: "신한카드", productId: "mr-life", productName: "Mr.Life", previousMonthSpendQualified: true, monthlyBenefitRemainingAmount: 700 }] };
  const rule: CalculatorBenefitRule = { provider: "신한카드 Mr.Life", appliesTo: "card", cardProductId: "mr-life", fixedDiscount: 1_000, maximumDiscount: 1_000, combinableWithCoupon: false, eligibleStoreKeywords: ["투썸플레이스"] };
  const matched = matchingBenefitRules(profile, "투썸플레이스 수원점", [activeRule(rule)]);
  assert.equal(calculate(recommendation([], 5_100, profile), matched)[0].savings, 700);
});
golden("CAL-17-card-requires-previous-spend", () => {
  const profile: RecommendationInput["profile"] = { carrier: "없음", cards: [{ issuer: "신한카드", productId: "mr-life", productName: "Mr.Life", previousMonthSpendQualified: false, monthlyBenefitRemainingAmount: 5_000 }] };
  const rule: CalculatorBenefitRule = { provider: "신한카드 Mr.Life", appliesTo: "card", cardProductId: "mr-life", fixedDiscount: 1_000, combinableWithCoupon: false, eligibleStoreKeywords: ["투썸플레이스"], requiresPreviousMonthSpend: true };
  assert.equal(matchingBenefitRules(profile, "투썸플레이스 수원점", [activeRule(rule)]).length, 0);
});
golden("CAL-18-carrier-grade-mismatch", () => {
  const profile: RecommendationInput["profile"] = { carrier: "SKT", membershipGrade: "SILVER" };
  const rule: CalculatorBenefitRule = { provider: "SKT", appliesTo: "carrier", fixedDiscount: 1_000, combinableWithCoupon: false, eligibleStoreKeywords: ["투썸플레이스"], eligibleGrades: ["VIP"] };
  assert.equal(matchingBenefitRules(profile, "투썸플레이스 수원점", [activeRule(rule)]).length, 0);
});
golden("CAL-19-monthly-benefit-used", () => {
  const profile: RecommendationInput["profile"] = { carrier: "SKT", monthlyBenefitStatus: "used" };
  const rule: CalculatorBenefitRule = { provider: "SKT", appliesTo: "carrier", fixedDiscount: 1_000, combinableWithCoupon: false, eligibleStoreKeywords: ["투썸플레이스"], requiresAvailableThisMonth: true };
  assert.equal(matchingBenefitRules(profile, "투썸플레이스 수원점", [activeRule(rule)]).length, 0);
});
golden("CAL-20-time-window-mismatch", () => {
  const profile: RecommendationInput["profile"] = { carrier: "SKT" };
  const rule: CalculatorBenefitRule = { provider: "SKT", appliesTo: "carrier", fixedDiscount: 1_000, combinableWithCoupon: false, eligibleStoreKeywords: ["투썸플레이스"], eligibleHoursKST: [22] };
  assert.equal(matchingBenefitRules(profile, "투썸플레이스 수원점", [activeRule(rule)], 14).length, 0);
});
golden("CAL-21-zero-won-floor", () => assert.equal(calculate(recommendation([coupon({ discountValue: 10_000 })], 10_000))[0].finalPrice, 0));
golden("CAL-22-multiple-benefits-use-best-only", () => {
  const rules: CalculatorBenefitRule[] = [
    { provider: "SKT", appliesTo: "carrier", fixedDiscount: 1_000, combinableWithCoupon: true, eligibleStoreKeywords: ["투썸플레이스"] },
    { provider: "KT", appliesTo: "carrier", fixedDiscount: 2_000, combinableWithCoupon: true, eligibleStoreKeywords: ["투썸플레이스"] }
  ];
  assert.equal(calculate(recommendation([coupon({ discountValue: 500 })]), rules)[0].savings, 2_500);
});

// 14 Store/coupon identity cases -----------------------------------------------------------------
const franchiseCases: Array<[string, string, boolean]> = [
  ["스타벅스", "스타벅스 수원시청점", true], ["투썸플레이스", "투썸 수원점", true],
  ["메가MGC커피", "메가커피 수원점", true], ["이디야", "이디야커피 수원점", true],
  ["컴포즈커피", "컴포즈 수원점", true], ["빽다방", "빽다방 수원점", true],
  ["할리스", "할리스커피 수원점", true], ["커피빈", "Coffee Bean 수원점", true],
  ["공차", "공차 수원점", true], ["더벤티", "TheVenti 수원점", true],
  ["베스킨라빈스", "배스킨라빈스 수원점", true], ["파리바게뜨", "파리바게트 수원점", true],
  ["뚜레쥬르", "Tous Les Jours 수원점", true], ["애슐리 퀸즈", "애슐리퀸즈 수원점", true]
];
for (const [brand, storeName, expected] of franchiseCases) {
  golden(`MATCH-${brand}`, () => assert.equal(couponMatchesStore(coupon({ brand }), storeName), expected));
}

// 10 RAG governance cases ------------------------------------------------------------------------
const governedDocument = {
  id: "skt-golden-document",
  title: "SKT 공식 혜택 원문",
  provider: "SKT",
  sourceURL: "https://sktmembership.tworld.co.kr/official",
  content: "공식 혜택 조건을 위한 60자 이상의 원문입니다. 적용 대상과 기간, 제외 조건, 할인 한도와 공식 앱에서 최종 확인해야 하는 내용을 함께 기록합니다.",
  governance: {
    status: "active" as const,
    checkedAt: "2026-08-20",
    staleAfter: "2026-09-20",
    version: "2026-08-20.v1",
    reviewer: "golden-reviewer",
    license: "Official-link citation and factual paraphrase reviewed",
    limitations: []
  }
};
golden("RAG-01-valid-official-document", () => assert.equal(validateBenefitDocument(governedDocument), governedDocument));
golden("RAG-02-reject-non-official-domain", () => assert.throws(() => validateBenefitDocument({ ...governedDocument, sourceURL: "https://example.com/benefit" }), /official-domain/u));
golden("RAG-03-reject-future-check", () => assert.throws(() => validateBenefitDocument({ ...governedDocument, governance: { ...governedDocument.governance, checkedAt: "2099-01-01" } }), /future/u));
golden("RAG-04-reject-invalid-calendar", () => assert.throws(() => validateBenefitDocument({ ...governedDocument, governance: { ...governedDocument.governance, checkedAt: "2026-02-30" } }), /ISO/u));
golden("RAG-05-reject-stale-before-check", () => assert.throws(() => validateBenefitDocument({ ...governedDocument, governance: { ...governedDocument.governance, staleAfter: "2026-08-19" } }), /staleAfter/u));
golden("RAG-06-reject-unknown-rights", () => assert.throws(() => validateBenefitDocument({ ...governedDocument, governance: { ...governedDocument.governance, license: "pending review" } }), /reviewed license/u));
golden("RAG-07-reject-unsafe-version", () => assert.throws(() => validateBenefitDocument({ ...governedDocument, governance: { ...governedDocument.governance, version: "../escape" } }), /path-safe/u));
golden("RAG-08-reject-over-100-percent", () => assert.throws(() => validateBenefitDocument({ ...governedDocument, rule: { provider: "SKT", appliesTo: "carrier", discountPercent: 101, combinableWithCoupon: false, eligibleStoreKeywords: ["투썸플레이스"] } }), /range/u));
golden("RAG-09-reject-card-without-product", () => assert.throws(() => validateBenefitDocument({ ...governedDocument, provider: "신한카드 Mr.Life", sourceURL: "https://www.shinhancard.com/official", rule: { provider: "신한카드 Mr.Life", appliesTo: "card", fixedDiscount: 1_000, combinableWithCoupon: false, eligibleStoreKeywords: ["투썸플레이스"] } }), /cardProductId/u));
golden("RAG-10-reject-rule-without-store-scope", () => assert.throws(() => validateBenefitDocument({ ...governedDocument, rule: { provider: "SKT", appliesTo: "carrier", fixedDiscount: 1_000, combinableWithCoupon: false } }), /eligibleStoreKeywords/u));

// 14 privacy value-level cases -------------------------------------------------------------------
const privacyCases: Array<[string, unknown, string | undefined]> = [
  ["PII-01-safe-price", { price: 15_000 }, undefined],
  ["PII-02-safe-discount", { title: "20% 할인 최대 3,000원" }, undefined],
  ["PII-03-email", { note: "a@example.com" }, "email"],
  ["PII-04-phone", { note: "010-1234-5678" }, "phone"],
  ["PII-05-rrn", { note: "900101-1234567" }, "resident-id"],
  ["PII-06-card", { note: "4111 1111 1111 1111" }, "card-number"],
  ["PII-07-barcode", { note: "123456789012" }, "long-digit-secret"],
  ["PII-08-barcode-with-dashes", { note: "1234-5678-9012" }, "long-digit-secret"],
  ["PII-09-barcode-key-with-value", { barcodeValue: "123456789012" }, "long-digit-secret"],
  ["PII-10-raw-ocr-with-barcode", { ocrRawText: "쿠폰번호 123456789012" }, "long-digit-secret"],
  ["PII-11-non-sensitive-random-id", { note: "Ab3Cd5Ef7Gh9Jk2Lm4Np6Qr8St0U" }, undefined],
  ["PII-12-nested-email", { coupon: { contact: "a@example.com" } }, "email"],
  ["PII-13-safe-product-id", { productId: "shinhancard-mr-life" }, undefined],
  ["PII-14-safe-store", { storeName: "투썸플레이스 수원점" }, undefined]
];
for (const [id, value, expected] of privacyCases) {
  golden(id, () => assert.equal(findSensitiveValue(value)?.kind, expected));
}

assert.equal(count, 60, `Expected exactly 60 closed-beta golden cases, received ${count}`);
console.log(`Closed-beta golden tests passed (${count}/60)`);
