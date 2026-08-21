"""ADK callbacks that enforce CouponCock's tool and privacy contracts."""

from __future__ import annotations

import re
from typing import Any

from google.adk.tools import BaseTool, ToolContext

ALLOWED_CARRIERS = {"SKT", "KT", "LG U+"}
KOREA_BOUNDS = {"min_lat": 33.0, "max_lat": 39.1, "min_lon": 124.0, "max_lon": 132.0}
SENSITIVE_KEYS = {
    "barcode",
    "barcodevalue",
    "cardnumber",
    "cardtoken",
    "email",
    "emailaddress",
    "firebaseuid",
    "mobilenumber",
    "ocrrawtext",
    "pan",
    "phone",
    "phonenumber",
    "rawtext",
    "telephone",
    "userid",
    "uid",
}

_EMAIL_PATTERN = re.compile(
    r"(?<![A-Z0-9._%+-])[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}(?![A-Z0-9._%+-])",
    re.IGNORECASE,
)
_KOREAN_PHONE_PATTERN = re.compile(
    r"(?<!\d)(?:\+?82[-.\s]?)?0?1[016789][-.\s]?\d{3,4}[-.\s]?\d{4}(?!\d)"
)
_LONG_DIGIT_PATTERN = re.compile(r"(?<!\d)(?:\d[-.\s]?){11,31}\d(?!\d)")
_LABELED_UID_PATTERN = re.compile(
    r"\b(?:firebase[-_\s]?uid|user[-_\s]?id|uid)\s*[:=]\s*[A-Z0-9_-]{8,128}\b",
    re.IGNORECASE,
)
_TOKEN_PATTERN = re.compile(r"(?<![A-Z0-9])[A-Z0-9]{28}(?![A-Z0-9])", re.IGNORECASE)


def _normalized_key(value: str) -> str:
    return "".join(character for character in value.lower() if character.isalnum())


def _luhn_valid(digits: str) -> bool:
    """Return whether a 13-19 digit candidate satisfies the PAN checksum."""

    if not 13 <= len(digits) <= 19 or len(set(digits)) == 1:
        return False
    checksum = 0
    parity = len(digits) % 2
    for index, character in enumerate(digits):
        digit = int(character)
        if index % 2 == parity:
            digit *= 2
            if digit > 9:
                digit -= 9
        checksum += digit
    return checksum % 10 == 0


def _firebase_uid_like(token: str) -> bool:
    """Conservatively identify Firebase-style opaque identifiers.

    Firebase Auth UIDs are commonly 28-character opaque alphanumeric values. Requiring
    upper case, lower case, and a digit avoids treating normal Korean/English business
    labels or coupon slugs as a user identifier.
    """

    return (
        len(token) == 28
        and any(character.islower() for character in token)
        and any(character.isupper() for character in token)
        and any(character.isdigit() for character in token)
    )


def _sensitive_string_kind(value: str) -> str | None:
    if _EMAIL_PATTERN.search(value):
        return "email"
    if _KOREAN_PHONE_PATTERN.search(value):
        return "phone"
    if _LABELED_UID_PATTERN.search(value):
        return "user_identifier"

    for candidate in _LONG_DIGIT_PATTERN.finditer(value):
        digits = "".join(character for character in candidate.group() if character.isdigit())
        if _luhn_valid(digits):
            return "payment_card_number"
        # GTIN/barcode values are commonly 12-14 digits. Longer opaque numeric values
        # are blocked as identifiers as well; ordinary prices are far shorter.
        if 12 <= len(digits) <= 32:
            return "barcode_or_numeric_identifier"

    for token in _TOKEN_PATTERN.finditer(value):
        if _firebase_uid_like(token.group()):
            return "user_identifier"
    return None


def _find_sensitive_data(value: Any) -> str | None:
    if isinstance(value, dict):
        for key, item in value.items():
            if _normalized_key(str(key)) in SENSITIVE_KEYS:
                return "sensitive_key"
            nested_kind = _find_sensitive_data(item)
            if nested_kind:
                return nested_kind
        return None
    if isinstance(value, (list, tuple)):
        for item in value:
            nested_kind = _find_sensitive_data(item)
            if nested_kind:
                return nested_kind
        return None
    if isinstance(value, str):
        return _sensitive_string_kind(value)
    # JSON may encode a barcode or account identifier as a number. The supported
    # business amounts are capped at 1,000,000, so 12+ digit integers are never valid
    # prices in this service contract.
    if isinstance(value, int) and not isinstance(value, bool) and 10**11 <= abs(value) < 10**32:
        digits = str(abs(value))
        return "payment_card_number" if _luhn_valid(digits) else "barcode_or_numeric_identifier"
    return None


def _blocked(reason: str) -> dict[str, Any]:
    return {
        "ok": False,
        "guardrail": "blocked",
        "reason": reason,
    }


def validate_tool_call(
    tool: BaseTool,
    args: dict[str, Any],
    tool_context: ToolContext,
) -> dict[str, Any] | None:
    """Block sensitive or out-of-policy MCP calls before network execution."""

    sensitive_kind = _find_sensitive_data(args)
    if sensitive_kind:
        return _blocked(
            "쿠폰 원문·바코드·카드번호·연락처·사용자 식별자는 도구로 전달할 수 없습니다."
        )

    if tool.name in {"search_nearby_stores", "verify_store_with_external_maps"}:
        latitude = args.get("latitude")
        longitude = args.get("longitude")
        radius = args.get("radiusMeters", 1_000)
        if not isinstance(latitude, (int, float)) or not KOREA_BOUNDS["min_lat"] <= latitude <= KOREA_BOUNDS["max_lat"]:
            return _blocked("대한민국 서비스 지역 위도 범위를 벗어났습니다.")
        if not isinstance(longitude, (int, float)) or not KOREA_BOUNDS["min_lon"] <= longitude <= KOREA_BOUNDS["max_lon"]:
            return _blocked("대한민국 서비스 지역 경도 범위를 벗어났습니다.")
        if not isinstance(radius, int) or not 100 <= radius <= 1_500:
            return _blocked("매장 검색 반경은 100~1,500m여야 합니다.")
        if tool.name == "verify_store_with_external_maps":
            store_name = args.get("storeName")
            if not isinstance(store_name, str) or not 1 <= len(store_name.strip()) <= 150:
                return _blocked("외부 지도 검증에는 유효한 매장명이 필요합니다.")

    if tool.name == "retrieve_carrier_benefits":
        if args.get("carrier") not in ALLOWED_CARRIERS:
            return _blocked("지원 통신사는 SKT, KT, LG U+입니다.")
        store_name = args.get("storeName")
        if not isinstance(store_name, str) or not 1 <= len(store_name.strip()) <= 150:
            return _blocked("유효한 매장명이 필요합니다.")

    if tool.name == "calculate_best_discount":
        expected_price = args.get("expectedPrice")
        coupons = args.get("coupons")
        if not isinstance(expected_price, int) or not 1 <= expected_price <= 1_000_000:
            return _blocked("예상 결제금액은 1~1,000,000원의 정수여야 합니다.")
        if not isinstance(coupons, list) or not 1 <= len(coupons) <= 100:
            return _blocked("계산 가능한 쿠폰은 1~100장입니다.")

    return None
