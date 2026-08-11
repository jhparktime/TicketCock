# CouponPilot 아키텍처

```text
iOS (SwiftUI)
 ├─ Vision OCR: 쿠폰 이미지 → raw text (이미지는 앱 내부 보관)
 ├─ MapKit + Core Location: 초기 매장 탐색과 매장 반경 진입 이벤트
 └─ Firebase ID Token → API Gateway → Cloud Run API
 ├─ Firestore: 사용자 프로필, 구조화 쿠폰, 사용 이력
       ├─ Cloud Storage: 카드·통신사 공식 혜택 문서
       ├─ RAG 검색 Tool: 관련 공식 규정만 반환
       ├─ LLM: OCR raw text → 쿠폰 JSON, Tool 호출·결과 설명
 └─ Calculator Tool: 가능한 할인 조합을 전수 계산하고 최저가 반환
```

## 수원시 매장 동기화

1. Cloud Run이 공공데이터포털 `소상공인시장진흥공단_상가(상권)정보_API`의 `storeListInRadius`를 호출합니다.
2. 수원시 경계 안의 상가만 `stores`에 upsert합니다. 데이터에는 상호명, 업종, 주소, 경도·위도가 제공됩니다.
3. iOS는 사용자 쿠폰 프랜차이즈를 MapKit으로 즉시 탐색해 지오펜스를 먼저 등록하고, Cloud Run의 공공데이터 결과로 보완합니다. 공공데이터 API 키는 절대 iOS에 넣지 않습니다.

데모 초기 범위는 수원시청 중심 반경 1.5km와 카페·편의점 업종입니다. 이후 수원시 전체 구역으로 확장합니다.

## Firestore 쿠폰 분리

```text
users/{uid}/coupons/{couponId}       # `status: active`인 추천 후보
users/{uid}/usedCoupons/{historyId}  # 사용 완료 이력, 추천·계산 입력에서 제외
```

`usedCoupons`에는 전체 바코드나 쿠폰 이미지를 저장하지 않습니다. 예시 이력에는 상품명, 사용일, 주문번호, 바코드 끝 4자리만 기록합니다.

## LLM 가드레일

- LLM은 쿠폰 이미지에 접근하지 않습니다. iPhone이 OCR한 raw text만 전송합니다.
- LLM은 OCR 텍스트만 구조화 초안으로 반환하며 원문은 저장하지 않습니다. 사용자가 확인한 구조화 필드만 Firestore에 저장합니다.
- 금액·할인 한도·중복 적용 가능 여부는 계산기 Tool 또는 정규화된 공식 혜택 규칙으로 판정합니다.
- RAG는 Cloud Storage의 공식 문서 chunk와 출처 URI를 함께 반환하도록 구현합니다.
- Gemini 모델은 `gemini-2.5-flash`로 고정하고, OCR raw text 정규화와 계산 결과 설명에만 사용합니다.
