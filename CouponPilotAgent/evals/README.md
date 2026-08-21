# ADK Eval

교재의 AgentOps 품질 보증 흐름에 맞춘 쿠폰콕 평가셋입니다.

```bash
adk eval couponcok_agent evals/couponcok_mvp.evalset.json \
  --config_file_path evals/test_config.json
```

라이브 평가는 Gemini와 MCP Cloud Run을 호출하므로 스테이징 환경에서만 실행합니다. 금액의 정확성은 LLM 평가에 맡기지 않고 `CouponPilotBackend/test/server.test.ts`의 Calculator 계약 테스트에서 100% 일치를 요구합니다.

## 릴리스 Holdout·Trajectory 평가

`couponcok_release_holdout.evalset.json`은 MVP 튜닝에 사용하지 않는 10개 시나리오입니다. 반드시
스테이징 Cloud Run과 실제 MCP 도구를 향하도록 설정한 뒤 실행합니다.

```bash
adk eval couponcok_agent evals/couponcok_release_holdout.evalset.json \
  --config_file_path evals/release_holdout_config.json
```

- 필수 도구 궤적: `retrieve_carrier_benefits → calculate_best_discount`
- 궤적 통과 기준: **1.0** (도구 추가·순서 변경 모두 실패)
- 응답 의미 일치 기준: **0.75 이상**
- Calculator의 최종가·절약 금액: 백엔드 결정론 테스트 **100%** 통과가 별도 필수

실행 결과의 run ID, 모델 버전, 프롬프트 버전, MCP/혜택 인덱스 버전을 릴리스 기록에 남깁니다.

GitHub Actions의 **Release Agent Evaluation**은 PR마다 결정론 계약·Guardrail·holdout 스키마를 검사합니다.
보호된 스테이징에서 실제 모델·MCP 호출은 수동 실행(`run_remote_holdout=true`)으로만 허용합니다.
이때 `GCP_WIF_PROVIDER`, `GCP_EVAL_SERVICE_ACCOUNT`, `GCP_PROJECT_ID`, `MCP_STAGING_URL`,
`MCP_STAGING_TOKEN`을 GitHub Environment `staging`의 Secret으로 등록합니다. 서비스 계정 키 파일이나
MCP 토큰을 저장소·평가 결과·AgentOps 로그에 기록하지 않습니다.

## 개인정보·정책 경계 평가

`privacy_guardrail_cases.json`은 모델 호출 없이 `pytest`에서 실행되는 결정론적 평가셋입니다.

- 민감정보 차단 재현율 목표: 100%
- 정상 가격·할인 조건 허용률 목표: 100%
- 지역·통신사 정책 위반 차단률 목표: 100%
- 차단 대상: 민감 키, PAN/Luhn, 긴 바코드, 전화번호, 이메일, 직접 UID 형태
- 정상 허용 대상: 1~1,000,000원 가격, 할인율, 최대 할인액, 일반 쿠폰 ID

```bash
pytest -q
```

평가 실패 시 라이브 ADK 평가나 배포를 진행하지 않습니다. 이 평가는 값의 유출 여부를
검사하며, 입력 원문 자체는 테스트·운영 로그에 기록하지 않는 것을 전제로 합니다.

## 정성 평가

`qualitative_review_rubric.json`은 세 명의 검토자가 동일한 추천 결과를 독립적으로 평가할
때 사용합니다. Calculator 일치, 공식 출처, 불확실성 고지, 사용자 선택권, 개인정보 표현,
행동 가능성을 5점 척도로 기록합니다. 가중 평균 4.2 이상이면서 각 항목의 hard gate를 모두
통과해야 출시 후보로 승인합니다. 검토자 간 일치율 목표는 80% 이상입니다.
