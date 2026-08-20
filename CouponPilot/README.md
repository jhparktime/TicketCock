# CouponPilot iOS

사용자가 등록한 쿠폰과 통신사 혜택을 현재 매장 기준으로 비교해 최적의 결제 방식을 알려주는 iOS 앱입니다.

## 현재 구현 범위

- SwiftUI Liquid Glass 홈 화면
- `CoreLocation` 기반 매장 반경 진입 감지 인터페이스
- `Vision` 기반 기기 내 쿠폰 OCR 및 Gemini 구조화 초안
- Firebase ID 토큰 → API Gateway → 비공개 Cloud Run 호출 경계
- 재실행 후에도 복원되는 최대 20개 매장 지오펜스와 5분 재진입 제한
- 서버에서 할인 후보를 계산하고, LLM은 쿠폰 문구 정규화·설명 생성만 담당하는 구조
- AI 사용 사전고지와 `생성형 AI 설명 / 규칙 기반 Calculator 결과` 분리 표시
- 공식 도메인·확인일·staleAfter·권리 판단·버전·해시를 통과한 혜택만 사용하는 RAG 게이트
- 필수 처리와 선택 초개인화·위치 동의를 분리한 온보딩 및 철회 흐름
- 카드번호를 폐기하고 카드사·상품명만 기기 내 Vision으로 찾는 카드 OCR
- OCR 텍스트의 바코드·연락처를 기기와 서버에서 이중 제거한 뒤에만 AI 정규화
- 사용 완료 후 5초 실행 취소와 기록 상세의 안전한 쿠폰 복원
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

## Agent 플랫폼 고도화

- `../CouponPilotBackend/src/mcpServer.ts`: 매장 검색·공식 혜택 RAG·가격 계산을 제공하는 Streamable HTTP MCP 서버
- `../CouponPilotAgent`: Google ADK 기반 4단계 전문 Agent 오케스트레이터와 AgentOps 추적
- `../CouponPilotAgent/evals`: 핵심 추천의 응답·도구 궤적을 검사하는 ADK Eval 평가셋
- `ADK_ORCHESTRATION_MODE=off|shadow|explanation`: 기존 MVP를 유지하며 단계적으로 Agent 응답을 승격
- `explanation` 모드에서도 ADK 응답의 최종가·절약액이 Calculator 결과와 같을 때만 설명을 채택
- 루트 `cloudbuild.yaml`: 테스트 후 API·MCP·ADK 컨테이너를 빌드하는 CI

새 Agent·MCP 서비스는 배포 전까지 기본값 `off`이며, 배포 및 최소 권한 설정은 `Docs/AGENT_PLATFORM_ROLLOUT.md`를 따릅니다.

상용화의 법·Responsible AI·Agent 보안·공공데이터/RAG 거버넌스와 출시 게이트는 [`Docs/AI_LEGAL_SECURITY_DATA_COMPLIANCE.md`](Docs/AI_LEGAL_SECURITY_DATA_COMPLIANCE.md)에 추적합니다. 공공기관 보안 문서는 민간 앱의 일반 법적 의무로 표시하지 않고, 제품 통제와 향후 공공 납품 기준을 분리했습니다.

초개인화 신호, 동의 모델, 카드 OCR, 하이브리드 위치 디렉터리와 월 10만원 베타 FinOps 통제는 [`Docs/PERSONALIZATION_LOCATION_FINOPS.md`](Docs/PERSONALIZATION_LOCATION_FINOPS.md)에 정리했습니다.

팀 구현의 장점을 통합한 최종 제품 형태, 멀티에이전트·MCP·Tool 권한 경계, 공식 혜택 RAG, HITL, 개인정보 비식별화, 정량·정성 평가와 shadow/canary 출시 파이프라인은 [`Docs/INTEGRATED_AGENTIC_SERVICE_BLUEPRINT.md`](Docs/INTEGRATED_AGENTIC_SERVICE_BLUEPRINT.md)에 정리했습니다.

## 제공된 쿠폰 샘플의 처리

제공된 두 스타벅스 쿠폰은 **사용 완료 이력** fixture로만 반영했습니다. 바코드 전체값과 원본 이미지는 앱 소스·Cloud Storage·Firestore에 저장하지 않고, 이력 식별에 필요한 바코드 끝 4자리만 보관합니다.

## 수원시 매장 데이터

백엔드의 `GET /v1/stores/nearby`는 공공데이터포털의 소상공인시장진흥공단 상가(상권)정보 API를 호출합니다. `DATA_GO_KR_SERVICE_KEY`는 Cloud Run 환경 변수 또는 Secret Manager에만 설정하고, iOS 앱에 포함하지 않습니다. 발표용으로는 수원시청 주변 1~1.5km 범위의 카페·편의점부터 Firestore에 적재하면 충분합니다.
