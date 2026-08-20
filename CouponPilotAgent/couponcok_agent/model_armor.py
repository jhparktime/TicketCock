"""Minimal fail-closed Model Armor boundary for ADK prompt and response text."""

from __future__ import annotations

import asyncio
import os
from typing import Literal

import google.auth
from google.auth.transport.requests import AuthorizedSession

SafetyMode = Literal["off", "monitor", "enforce"]
Surface = Literal["prompt", "response"]


def configured_model_armor_mode() -> SafetyMode:
    value = os.getenv("MODEL_ARMOR_MODE", "off")
    return value if value in {"monitor", "enforce"} else "off"


def _template_config() -> tuple[str, str, str] | None:
    project = os.getenv("MODEL_ARMOR_PROJECT_ID") or os.getenv("GOOGLE_CLOUD_PROJECT")
    location = os.getenv("MODEL_ARMOR_LOCATION", "asia-northeast3")
    template = os.getenv("MODEL_ARMOR_TEMPLATE")
    return (project, location, template) if project and template else None


def _sanitize(text: str, surface: Surface) -> bool:
    config = _template_config()
    if config is None:
        raise RuntimeError("Model Armor template is not configured")
    project, location, template = config
    operation = "sanitizeUserPrompt" if surface == "prompt" else "sanitizeModelResponse"
    payload = {"userPromptData": {"text": text}} if surface == "prompt" else {"modelResponseData": {"text": text}}
    credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    session = AuthorizedSession(credentials)
    response = session.post(
        f"https://modelarmor.{location}.rep.googleapis.com/v1/projects/{project}/locations/{location}/templates/{template}:{operation}",
        json=payload,
        timeout=float(os.getenv("MODEL_ARMOR_TIMEOUT_SECONDS", "3")),
    )
    if not response.ok:
        raise RuntimeError(f"Model Armor returned HTTP {response.status_code}")
    return response.json().get("sanitizationResult", {}).get("filterMatchState") == "MATCH_FOUND"


async def enforce_model_armor(text: str, surface: Surface) -> None:
    """Do not log the evaluated text. Enforce mode blocks on match or service failure."""
    mode = configured_model_armor_mode()
    if mode == "off":
        return
    try:
        matched = await asyncio.to_thread(_sanitize, text, surface)
        if matched and mode == "enforce":
            raise RuntimeError(f"Model Armor blocked {surface}")
        if matched:
            print(f"Model Armor monitor match: surface={surface}")
    except Exception as error:
        if mode == "enforce":
            raise
        print(f"Model Armor monitor degraded: surface={surface}, reason={type(error).__name__}")
