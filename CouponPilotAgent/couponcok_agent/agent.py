"""CouponCock ADK multi-agent workflow.

The workflow deliberately keeps all price authority inside the Calculator MCP tool.
Agents may validate, retrieve evidence and explain, but must never invent or alter money.
"""

from __future__ import annotations

import os
from urllib.parse import urlparse

from dotenv import load_dotenv
from google.adk.agents import LlmAgent, SequentialAgent
from google.adk.apps import App
from google.adk.tools.mcp_tool import McpToolset
from google.adk.tools.mcp_tool.mcp_session_manager import (
    StreamableHTTPConnectionParams,
)
from google.auth.transport.requests import Request as GoogleAuthRequest
from google.genai import types
from google.oauth2 import id_token

from .guardrails import validate_tool_call

load_dotenv()

# AgentOps must be initialized before ADK agent instances are constructed so it can
# automatically observe agent, model and MCP tool spans. Observability is optional:
# a missing key or exporter outage must never block the recommendation path.
if os.getenv("AGENTOPS_API_KEY"):
    import agentops

    try:
        agentops.init()
    except Exception as error:
        print(f"AgentOps initialization skipped: {type(error).__name__}")

MODEL = os.getenv("ADK_MODEL", "gemini-2.5-flash")
MCP_SERVER_URL = os.getenv("MCP_SERVER_URL", "http://127.0.0.1:8081/mcp")
MCP_INTERNAL_TOKEN = os.getenv("MCP_INTERNAL_TOKEN", "")


def _generation_config(max_output_tokens: int) -> types.GenerateContentConfig:
    """Keep JSON agents deterministic and cap token cost for the short workflow."""

    return types.GenerateContentConfig(
        temperature=0,
        max_output_tokens=max_output_tokens,
        thinking_config=types.ThinkingConfig(thinking_budget=0),
    )


def _mcp_toolset(*tool_names: str) -> McpToolset:
    headers = {}
    if MCP_INTERNAL_TOKEN:
        headers["x-couponcok-mcp-token"] = MCP_INTERNAL_TOKEN
    if MCP_SERVER_URL.startswith("https://"):
        parsed = urlparse(MCP_SERVER_URL)
        audience = f"{parsed.scheme}://{parsed.netloc}"
        headers["Authorization"] = f"Bearer {id_token.fetch_id_token(GoogleAuthRequest(), audience)}"
    return McpToolset(
        connection_params=StreamableHTTPConnectionParams(
            url=MCP_SERVER_URL,
            headers=headers,
            timeout=20,
            sse_read_timeout=60,
        ),
        tool_filter=list(tool_names),
    )


def build_root_agent() -> SequentialAgent:
    """Create a workflow for one orchestration request.

    Cloud Run ID tokens have a finite lifetime. Creating toolsets at request time ensures an
    MCP call always carries a fresh service-account token instead of an expired startup token.
    """

    store_context_agent = LlmAgent(
        name="store_context_agent",
        model=MODEL,
        description="전국 매장 진입 좌표와 매장 브랜드를 확인하는 전문 에이전트",
        instruction="""
사용자 요청에서 storeId, storeName, 좌표를 확인하세요.
좌표가 있으면 반드시 search_nearby_stores를 호출해 대한민국 내 지원 프랜차이즈인지 확인하세요.
매장명과 좌표가 있으면 verify_store_with_external_maps도 한 번 호출하세요. 이 도구는 정밀 위치를 외부에 보내지 않고 0.01도 격자·매장명만 Google Maps 공식 MCP에 전달하며, 실패 시 카카오 공식 Local API를 사용합니다.
외부 지도 결과는 보조 근거일 뿐입니다. data.go.kr 매장 원본을 대체하지 말고, unavailable이면 추정하지 마세요.
좌표가 없으면 제공된 storeName을 그대로 사용하고 위치가 미검증임을 표시하세요.
쿠폰·바코드·사용자 식별자를 도구에 전달하지 마세요.
결과는 짧은 JSON으로만 반환하세요.
""",
        tools=[_mcp_toolset("search_nearby_stores", "verify_store_with_external_maps")],
        before_tool_callback=validate_tool_call,
        generate_content_config=_generation_config(500),
        output_key="store_context",
    )

    coupon_understanding_agent = LlmAgent(
        name="coupon_understanding_agent",
        model=MODEL,
        description="등록된 쿠폰의 브랜드·할인 조건을 검증하는 전문 에이전트",
        instruction="""
사용자 요청의 coupons 배열을 검토해 매장 브랜드와 일치하는 후보만 정리하세요.
원문에 없는 할인액·최소 주문액·중복 가능 여부를 추정하지 마세요.
바코드 전체값이나 OCR 원문이 입력에 있더라도 출력에 반복하지 마세요.
검증 결과를 다음 단계가 그대로 사용할 수 있는 JSON으로만 반환하세요.
매장 맥락: {store_context}
""",
        generate_content_config=_generation_config(700),
        output_key="coupon_context",
    )

    benefit_retrieval_agent = LlmAgent(
        name="benefit_retrieval_agent",
        model=MODEL,
        description="공식 통신사·카드 혜택 문서의 근거와 계산 규칙을 검색하는 전문 에이전트",
        instruction="""
사용자의 통신사·등급·등록 카드 상품과 매장명으로 retrieve_carrier_benefits를 반드시 한 번 호출하세요. 등록 카드가 있으면 profile.cards의 productName만 cardProducts에 넣으세요.
등록 카드의 카드번호·만료일·CVC·결제내역을 도구에 전달하지 마세요. 상품명, 전월 실적 충족 여부, 남은 월 혜택 한도만 사용할 수 있습니다.
도구 결과의 공식 sourceURL과 rule만 사용하고, rule이 없는 혜택의 금액을 추정하지 마세요.
공식 sourceURL과 적용 조건을 참고용 근거로 정리하세요. 계산 규칙은 다음 단계에 전달하지 않으며 Calculator Tool이 공식 색인에서 직접 재조회합니다.
매장 맥락: {store_context}
쿠폰 맥락: {coupon_context}
""",
        tools=[_mcp_toolset("retrieve_carrier_benefits")],
        before_tool_callback=validate_tool_call,
        generate_content_config=_generation_config(700),
        output_key="benefit_context",
    )

    recommendation_agent = LlmAgent(
        name="recommendation_agent",
        model=MODEL,
        description="결정론적 계산 결과를 보존해 최종 추천을 설명하는 전문 에이전트",
        instruction="""
calculate_best_discount를 반드시 호출해 최종가·절약액·순위를 확정하세요.
쿠폰 입력은 coupon_context에서 가져오세요. 공식 통신사·카드 할인 규칙은 절대 도구 인자로 전달하거나 재작성하지 마세요. Calculator Tool이 활성·승인된 공식 RAG 문서에서 직접 재조회합니다.
도구가 반환한 금액·순위·중복 가능 여부를 절대 수정하거나 다시 계산하지 마세요.
최종 응답은 recommendedOption, alternatives, explanation, benefitSources를 포함한 JSON으로 반환하세요.
공식 근거가 없으면 benefitSources를 빈 배열로 두고 그 사실을 explanation에 명시하세요.

매장 맥락: {store_context}
쿠폰 맥락: {coupon_context}
혜택 맥락: {benefit_context}
""",
        tools=[_mcp_toolset("calculate_best_discount")],
        before_tool_callback=validate_tool_call,
        generate_content_config=_generation_config(900),
        output_key="recommendation_result",
    )

    return SequentialAgent(
        name="couponcok_orchestrator",
        description="매장 맥락, 쿠폰 후보, 공식 혜택, 결정론적 계산을 순서대로 실행하는 쿠폰콕 오케스트레이터",
        sub_agents=[
            store_context_agent,
            coupon_understanding_agent,
            benefit_retrieval_agent,
            recommendation_agent,
        ],
    )


# Used by health checks and architecture tests. Requests construct their own fresh instance.
root_agent = build_root_agent()

app = App(root_agent=root_agent, name="couponcok_agent")
