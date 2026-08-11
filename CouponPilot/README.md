# CouponPilot iOS

사용자가 등록한 쿠폰과 카드·통신사 혜택을 현재 매장 기준으로 비교해 최적의 결제 방식을 알려주는 iOS 앱입니다.

## 현재 구현 범위

- SwiftUI Liquid Glass 홈 화면
- `CoreLocation` 기반 매장 반경 진입 감지 인터페이스
- `Vision` 기반 기기 내 쿠폰 OCR 및 Gemini 구조화 초안
- Firebase ID 토큰 → API Gateway → 비공개 Cloud Run 호출 경계
- 재실행 후에도 복원되는 최대 20개 매장 지오펜스와 5분 재진입 제한
- 서버에서 할인 후보를 계산하고, LLM은 쿠폰 문구 정규화·설명 생성만 담당하는 구조
- 사용 완료 쿠폰 2건을 활성 쿠폰과 분리한 이력 UI
- 서비스 지역을 수원시로 제한하고 공공데이터포털 상가업소 API를 경유하는 매장 조회 API

## Xcode에서 실행하기

1. `CouponPilot.xcodeproj`를 Xcode에서 엽니다.
2. Firebase Console에서 내려받은 `GoogleService-Info.plist`를 앱 Target에 추가합니다. 이 파일은 저장소에 포함하지 않습니다.
3. Xcode의 Signing & Capabilities에서 본인의 Apple Development Team을 선택합니다. Firebase Auth의 Keychain 접근과 실기기 테스트에 필요합니다.
4. 앱 Target에는 아래 권한 문구가 이미 구성돼 있습니다.

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>주변 매장에서 사용할 수 있는 쿠폰을 알려드리기 위해 위치를 사용합니다.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>매장 진입 시 쿠폰 혜택을 알려드리기 위해 위치를 사용합니다.</string>
<key>NSCameraUsageDescription</key>
<string>쿠폰을 기기에서 안전하게 인식하기 위해 카메라를 사용합니다.</string>
```

5. `AgentAPIService.baseURL`은 Firebase를 검증하는 API Gateway 주소로 이미 설정돼 있습니다.

## 서비스 경계

| 책임 | 위치 |
| --- | --- |
| 이미지 OCR | iPhone의 Vision 프레임워크 |
| 쿠폰 이미지 | iPhone 앱 내부 저장소만 사용 |
| OCR raw text | 이미지 없이 Gemini 정규화 요청에만 사용, 영구 저장하지 않음 |
| 확인된 구조화 쿠폰·프로필 | Firestore (`users/{uid}` 소유 경로) |
| 사용 완료 쿠폰 | `users/{uid}/usedCoupons` (추천 대상 제외) |
| 공식 혜택 원문 | Cloud Storage |
| RAG 검색·LLM Tool orchestration | Cloud Run |
| 할인액·최적 조합 산출 | Cloud Run 계산기 Tool |
| 수원시 매장 정보 | 공공데이터포털 API → Cloud Run, iPhone의 MapKit 즉시 탐색으로 보완 |

백엔드는 인접한 `../CouponPilotBackend`에 있으며, Cloud Run과 API Gateway로 배포돼 있습니다.

## 제공된 쿠폰 샘플의 처리

제공된 두 스타벅스 쿠폰은 **사용 완료 이력** fixture로만 반영했습니다. 바코드 전체값과 원본 이미지는 앱 소스·Cloud Storage·Firestore에 저장하지 않고, 이력 식별에 필요한 바코드 끝 4자리만 보관합니다.

## 수원시 매장 데이터

백엔드의 `GET /v1/stores/nearby`는 공공데이터포털의 소상공인시장진흥공단 상가(상권)정보 API를 호출합니다. `DATA_GO_KR_SERVICE_KEY`는 Cloud Run 환경 변수 또는 Secret Manager에만 설정하고, iOS 앱에 포함하지 않습니다. 발표용으로는 수원시청 주변 1~1.5km 범위의 카페·편의점부터 Firestore에 적재하면 충분합니다.
