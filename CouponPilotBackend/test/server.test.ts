import assert from "node:assert/strict";
import { once } from "node:events";
import { app } from "../src/server.js";

const server = app.listen(0, "127.0.0.1");
await once(server, "listening");
const address = server.address();
assert(address && typeof address !== "string");
const baseURL = `http://127.0.0.1:${address.port}`;

try {
  const health = await fetch(`${baseURL}/health`);
  assert.equal(health.status, 200);

  const response = await fetch(`${baseURL}/v1/recommendations`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      storeId: "suwon-demo-starbucks", expectedPrice: 15_000,
      profile: { carrier: "SKT", membershipGrade: "VIP", monthlyBenefitStatus: "available" },
      coupons: [
        { id: "coupon-001", brand: "스타벅스", title: "음료 3,000원 할인", discountType: "fixedAmount", discountValue: 3_000, minimumOrderAmount: 10_000, combinableWithCard: true },
        { id: "coupon-002", brand: "스타벅스", title: "제조 음료 20% 할인", discountType: "percentage", discountValue: 20, minimumOrderAmount: 0, combinableWithCard: false }
      ]
    })
  });
  assert.equal(response.status, 200);
  const recommendation = await response.json() as { recommendedOption: { finalPrice: number; savings: number } };
  // Without an ingested official benefit rule, only the deterministic coupon calculator applies.
  assert.equal(recommendation.recommendedOption.finalPrice, 12_000);
  assert.equal(recommendation.recommendedOption.savings, 3_000);

  const singleItemCoupon = await fetch(`${baseURL}/v1/recommendations`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({
      storeId: "twosome-suwon", storeName: "투썸플레이스 수원점", expectedPrice: 15_000,
      profile: { carrier: "SKT", membershipGrade: "VIP", monthlyBenefitStatus: "available" },
      coupons: [{ id: "twosome-americano", brand: "투썸플레이스", title: "아메리카노 2,000원 할인", discountType: "fixedAmount", discountValue: 2_000, minimumOrderAmount: 5_000, combinableWithCard: true, referencePrice: 5_100 }]
    })
  });
  assert.equal(singleItemCoupon.status, 200);
  const singleItemRecommendation = await singleItemCoupon.json() as { originalPrice: number; recommendedOption: { finalPrice: number; savings: number } };
  assert.equal(singleItemRecommendation.originalPrice, 5_100);
  assert.equal(singleItemRecommendation.recommendedOption.finalPrice, 3_100);
  assert.equal(singleItemRecommendation.recommendedOption.savings, 2_000);

  // CouponPilot is not a generic coupon wallet: a coupon is considered only after
  // the entered store's franchise has matched it.
  const mismatchedCoupon = await fetch(`${baseURL}/v1/recommendations`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      storeId: "suwon-demo-starbucks", storeName: "스타벅스 수원시청점", expectedPrice: 15_000,
      profile: { carrier: "SKT", membershipGrade: "VIP", monthlyBenefitStatus: "available" },
      coupons: [{ id: "gongcha-only", brand: "공차", title: "공차 전용 할인", discountType: "fixedAmount", discountValue: 3_000, minimumOrderAmount: 0, combinableWithCard: false }]
    })
  });
  assert.equal(mismatchedCoupon.status, 422);

  const supportedFranchises = [
    ["스타벅스", "스타벅스 수원시청점"], ["투썸플레이스", "투썸플레이스 수원점"],
    ["메가MGC커피", "메가커피 수원점"], ["이디야", "이디야커피 수원점"],
    ["컴포즈커피", "컴포즈커피 수원점"], ["빽다방", "빽다방 수원점"],
    ["할리스", "할리스커피 수원점"], ["커피빈", "커피빈 수원점"],
    ["공차", "공차 수원점"], ["더벤티", "더벤티 수원점"],
    ["베스킨라빈스", "베스킨라빈스 수원점"], ["파리바게뜨", "파리바게뜨 수원점"],
    ["뚜레쥬르", "뚜레쥬르 수원점"], ["애슐리 퀸즈", "애슐리 퀸즈 수원점"]
  ];
  for (const [brand, storeName] of supportedFranchises) {
    const match = await fetch(`${baseURL}/v1/recommendations`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({
        storeId: storeName, storeName, expectedPrice: 10_000,
        profile: { carrier: "SKT", membershipGrade: "VIP", monthlyBenefitStatus: "available" },
        coupons: [{ id: brand, brand, title: `${brand} 테스트 쿠폰`, discountType: "fixedAmount", discountValue: 1_000, minimumOrderAmount: 0, combinableWithCard: false }]
      })
    });
    assert.equal(match.status, 200, `${brand} 쿠폰이 ${storeName}에 매칭되어야 합니다`);
  }
  console.log("API contract tests passed");
} finally {
  server.close();
}
