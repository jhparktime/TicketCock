# AgentOps · MCP · Google ADK 고도화 실행계획

## 구현된 구성

- Node API: Firebase 인증, 기존 추천 계약, 결정론적 Calculator, ADK 결과 검증
- MCP Cloud Run: 매장 검색, 공식 통신사 혜택 RAG, 최종가 계산 도구
- ADK Cloud Run: 4개 전문 Agent의 순차 워크플로
- Cloud Logging/OpenTelemetry: 현재 운영 가능한 요청·도구 지연·실패 관측
- AgentOps: ADK와 Gemini/MCP 실행의 Trace·비용·지연·실패 관측을 위한 선택 연동 코드. `AGENTOPS_API_KEY`를 Secret Manager에 등록하기 전에는 활성화하지 않는다.
- ADK Callback: 민감 필드·서비스 지역·가격 범위를 도구 호출 전에 검사
- ADK Eval: 핵심 추천 2건의 응답·도구 궤적 평가셋
- Cloud Build: 계약 테스트 후 API·MCP·ADK 이미지를 빌드하는 CI

## 배포 순서

1. `CouponPilotBackend/Dockerfile.mcp`로 비공개 MCP Cloud Run을 배포합니다.
2. MCP Runtime SA에 필요한 최소 역할만 부여하고 `MCP_INTERNAL_TOKEN`을 Secret Manager에서 주입합니다.
3. `CouponPilotAgent/Dockerfile`로 비공개 ADK Cloud Run을 배포합니다.
4. ADK Runtime SA에 MCP 서비스의 `roles/run.invoker`와 Vertex AI User를 부여합니다.
5. Node API에 ADK URL과 내부 토큰을 주입하고 `ADK_ORCHESTRATION_MODE=shadow`로 배포합니다.
6. ADK Eval과 Cloud Logging에서 20건 이상 Trace를 비교한 뒤 Calculator 일치율 100%일 때 `explanation`으로 전환합니다. AgentOps 키를 도입한 경우에는 같은 표본을 AgentOps에서도 교차 확인합니다.

## 승격 기준

| 단계 | 필수 기준 |
|---|---|
| off → shadow | REST·MCP 계약 테스트와 ADK 가드레일 6개 테스트 통과, MCP 비공개 호출 확인 |
| shadow 유지 | Calculator 일치율 100%, 공식 출처 없는 할인 추정 0건 |
| shadow → explanation | 응답 P95 3초 목표 또는 허용 범위 합의, 실패 시 MVP fallback 확인 |
| 운영 | Cloud Logging에 원본 OCR·바코드·직접 사용자 ID가 기록되지 않음. AgentOps 활성화 시에도 동일한 금지 기준을 확인 |

## 장애 시 동작

- ADK 실패·시간초과: 기존 Node 계산 및 Gemini 설명으로 자동 복귀
- MCP RAG 실패: 쿠폰만 계산하고 공식 혜택 없음 표시
- data.go.kr 실패: 기존 캐시와 iOS MapKit 보완 경로 사용
- AgentOps 실패: 추천은 계속 처리하고 Cloud Logging에 구조화 이벤트 기록
