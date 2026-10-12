"""
AI Job Hunter - ai-service
==========================
Scores a job listing against a master resume using Gemini or OpenRouter and
returns strictly structured JSON (validated with pydantic) for the n8n pipeline.

Endpoints
---------
GET  /health          liveness probe
GET  /health/detail   config summary (never leaks API keys)
POST /score           one job  -> ScoreResult
POST /score/batch     many jobs -> ScoreResult[]

Provider selection is done with LLM_PROVIDER=openrouter|gemini.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
from functools import lru_cache
from typing import Any, Dict, List, Optional

import httpx
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
LOG_LEVEL = os.getenv("LOG_LEVEL", "info").upper()
LLM_PROVIDER = os.getenv("LLM_PROVIDER", "openrouter").lower()
LLM_MODEL = os.getenv(
    "LLM_MODEL",
    "nvidia/nemotron-3-super-120b-a12b:free"
    if LLM_PROVIDER == "openrouter"
    else "gemini-2.0-flash",
)
OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY", "")
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY", "")
LLM_TIMEOUT_SECONDS = float(os.getenv("LLM_TIMEOUT_SECONDS", "60"))
RESUME_PATH = os.getenv("RESUME_PATH", "/data/resume.md")
# Single source of truth shared with the n8n IF node; MIN_SCORE_TO_NOTIFY kept as legacy alias
MATCH_SCORE_THRESHOLD = int(
    os.getenv("MATCH_SCORE_THRESHOLD", os.getenv("MIN_SCORE_TO_NOTIFY", "75"))
)

logging.basicConfig(level=LOG_LEVEL, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("ai-service")

app = FastAPI(
    title="AI Job Hunter - AI Scoring Service",
    version="1.0.0",
    description="Gemini/OpenRouter job scoring with structured JSON output.",
)

# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------


class Job(BaseModel):
    title: str
    company: Optional[str] = None
    location: Optional[str] = None
    description: Optional[str] = None
    link: Optional[str] = None
    source: Optional[str] = None


class ScoreRequest(BaseModel):
    job: Job
    # Override the resume stored on disk when provided (useful for per-user runs)
    resume_text: Optional[str] = None
    keywords: Optional[str] = Field(default=None, description="Search query that surfaced the job")


class ScoreResult(BaseModel):
    score: int = Field(ge=0, le=100, description="Fit score 0-100")
    verdict: str = Field(pattern="^(strong_match|maybe|skip)$")
    matched_skills: List[str] = Field(default_factory=list)
    missing_skills: List[str] = Field(default_factory=list)
    keywords: List[str] = Field(default_factory=list)
    rationale: str
    model: str
    provider: str
    notify: bool = False


class LLMError(Exception):
    """Upstream LLM failure; answered with {"status": "error", "message": ...}."""


@app.exception_handler(LLMError)
async def llm_error_handler(_request: Request, exc: LLMError) -> JSONResponse:
    return JSONResponse(status_code=502, content={"status": "error", "message": str(exc)})


@app.exception_handler(RequestValidationError)
async def validation_error_handler(_request: Request, exc: RequestValidationError) -> JSONResponse:
    for err in exc.errors():
        loc = [str(part) for part in err.get("loc", [])]
        if err.get("type") == "missing":
            field = loc[-1] if loc else "body"
            return JSONResponse(
                status_code=400,
                content={"status": "error", "message": f"Missing input field: {field}"},
            )
    return JSONResponse(
        status_code=422,
        content={"status": "error", "message": exc.errors()[0].get("msg", "Invalid input")},
    )


# ---------------------------------------------------------------------------
# Master resume
# ---------------------------------------------------------------------------


@lru_cache(maxsize=1)
def load_resume() -> str:
    try:
        with open(RESUME_PATH, "r", encoding="utf-8") as handle:
            text = handle.read().strip()
        if text:
            log.info("Loaded master resume from %s (%d chars)", RESUME_PATH, len(text))
            return text
    except OSError as exc:
        log.warning("Could not read resume at %s: %s", RESUME_PATH, exc)
    return ""


# ---------------------------------------------------------------------------
# Prompting
# ---------------------------------------------------------------------------
SYSTEM_PROMPT = """You are a strict recruiting analyst inside an automated job-hunting pipeline.
Score how well the offered job matches the candidate's master resume.

Rules:
- Score from 0 to 100 where 70+ means worth applying, 45-69 means borderline, below 45 means skip.
- verdict must be exactly one of: "strong_match", "maybe", "skip".
- matched_skills: concrete skills/tools from the resume that the job requires.
- missing_skills: requirements of the job the resume does NOT cover.
- keywords: 3-6 short job keywords (technologies, seniority, domain).
- rationale: 2-3 factual sentences, no marketing language, never invent experience.
- Respond with a single JSON object matching the requested schema and nothing else."""

GEMINI_RESPONSE_SCHEMA: Dict[str, Any] = {
    "type": "object",
    "properties": {
        "score": {"type": "integer"},
        "verdict": {"type": "string", "enum": ["strong_match", "maybe", "skip"]},
        "matched_skills": {"type": "array", "items": {"type": "string"}},
        "missing_skills": {"type": "array", "items": {"type": "string"}},
        "keywords": {"type": "array", "items": {"type": "string"}},
        "rationale": {"type": "string"},
    },
    "required": ["score", "verdict", "matched_skills", "missing_skills", "keywords", "rationale"],
}


def build_user_prompt(req: ScoreRequest, resume: str) -> str:
    job = req.job
    parts = [
        "MASTER RESUME:",
        resume or "(no resume provided)",
        "",
        "JOB OFFER:",
        f"- title: {job.title}",
        f"- company: {job.company or 'n/a'}",
        f"- location: {job.location or 'n/a'}",
        f"- source: {job.source or 'n/a'}",
        f"- url: {job.link or 'n/a'}",
        f"- search keywords: {req.keywords or 'n/a'}",
        f"- description: {job.description or '(no description provided)'}",
        "",
        "Return the JSON object now.",
    ]
    return "\n".join(parts)


# ---------------------------------------------------------------------------
# Providers
# ---------------------------------------------------------------------------


async def _call_openrouter(messages: List[Dict[str, str]]) -> str:
    if not OPENROUTER_API_KEY:
        raise LLMError("Missing input field: OPENROUTER_API_KEY")
    payload = {
        "model": LLM_MODEL,
        "messages": messages,
        "temperature": 0.2,
        # Reasoning models can burn most of the budget on reasoning tokens
        # (observed: 566 of 700), leaving a truncated or empty answer.
        "max_tokens": 3000,
    }
    headers = {
        "Authorization": f"Bearer {OPENROUTER_API_KEY}",
        "X-Title": "AI Job Hunter",
    }
    try:
        async with httpx.AsyncClient(timeout=LLM_TIMEOUT_SECONDS) as client:
            response = await client.post(
                "https://openrouter.ai/api/v1/chat/completions",
                json=payload,
                headers=headers,
            )
    except httpx.HTTPError as exc:
        raise LLMError(f"OpenRouter request failed: {exc.__class__.__name__}: {exc}") from exc
    if response.status_code != 200:
        raise LLMError(f"OpenRouter returned HTTP {response.status_code}: {response.text[:300]}")
    data = response.json()
    try:
        choice = data["choices"][0]
        content = choice["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        raise LLMError(f"Unexpected OpenRouter response shape: {json.dumps(data)[:300]}") from exc
    if not isinstance(content, str) or not content.strip():
        # Never return None: downstream parsing expects a string, and a silent
        # None used to crash the request handler into a bare 500.
        message = choice.get("message") or {}
        raise LLMError(
            f"OpenRouter returned no content for {LLM_MODEL} "
            f"(finish_reason={choice.get('finish_reason')!r}, "
            f"reasoning_chars={len(message.get('reasoning') or '')})"
        )
    return content


async def _call_gemini(messages: List[Dict[str, str]]) -> str:
    if not GEMINI_API_KEY:
        raise LLMError("Missing input field: GEMINI_API_KEY")
    system_text = "\n".join(m["content"] for m in messages if m["role"] == "system")
    user_texts = [m["content"] for m in messages if m["role"] != "system"]
    body = {
        "contents": [{"role": "user", "parts": [{"text": t} for t in user_texts]}],
        "systemInstruction": {"parts": [{"text": system_text}]},
        "generationConfig": {
            "temperature": 0.2,
            "maxOutputTokens": 700,
            "responseMimeType": "application/json",
            "responseSchema": GEMINI_RESPONSE_SCHEMA,
        },
    }
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{LLM_MODEL}:generateContent"
    try:
        async with httpx.AsyncClient(timeout=LLM_TIMEOUT_SECONDS) as client:
            response = await client.post(url, json=body, headers={"x-goog-api-key": GEMINI_API_KEY})
    except httpx.HTTPError as exc:
        raise LLMError(f"Gemini request failed: {exc.__class__.__name__}: {exc}") from exc
    if response.status_code != 200:
        raise LLMError(f"Gemini returned HTTP {response.status_code}: {response.text[:300]}")
    data = response.json()
    try:
        return data["candidates"][0]["content"]["parts"][0]["text"]
    except (KeyError, IndexError, TypeError) as exc:
        raise LLMError(f"Unexpected Gemini response shape: {json.dumps(data)[:300]}") from exc


async def complete(messages: List[Dict[str, str]]) -> str:
    if LLM_PROVIDER == "gemini":
        return await _call_gemini(messages)
    if LLM_PROVIDER == "openrouter":
        return await _call_openrouter(messages)
    raise LLMError(f"Unsupported LLM_PROVIDER: {LLM_PROVIDER} (use 'openrouter' or 'gemini')")


# ---------------------------------------------------------------------------
# Structured output parsing (with one repair round-trip)
# ---------------------------------------------------------------------------

_FENCE_RE = re.compile(r"```(?:json)?\s*(.*?)\s*```", re.DOTALL)


def _extract_json(text: str) -> Dict[str, Any]:
    if not isinstance(text, str) or not text.strip():
        # ValueError -> handled by the repair round-trip below, never a 500
        raise ValueError("model returned empty output")
    candidate = text.strip()
    fence = _FENCE_RE.search(candidate)
    if fence:
        candidate = fence.group(1).strip()
    start, end = candidate.find("{"), candidate.rfind("}")
    if start == -1 or end == -1:
        raise ValueError("no JSON object found in model output")
    return json.loads(candidate[start : end + 1])


def _derive_verdict(score: int, verdict: str) -> str:
    if verdict in ("strong_match", "maybe", "skip"):
        return verdict
    if score >= MATCH_SCORE_THRESHOLD:
        return "strong_match"
    if score >= 45:
        return "maybe"
    return "skip"


async def score_job(req: ScoreRequest) -> ScoreResult:
    resume = req.resume_text or load_resume()
    if not resume.strip():
        raise LLMError(f"Missing input field: resume ({RESUME_PATH} is empty and no resume_text given)")

    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": build_user_prompt(req, resume)},
    ]

    raw = await complete(messages)
    try:
        parsed = _extract_json(raw)
        result = ScoreResult(
            score=int(parsed["score"]),
            verdict=_derive_verdict(int(parsed["score"]), str(parsed.get("verdict", ""))),
            matched_skills=[str(s) for s in parsed.get("matched_skills", [])],
            missing_skills=[str(s) for s in parsed.get("missing_skills", [])],
            keywords=[str(s) for s in parsed.get("keywords", [])],
            rationale=str(parsed.get("rationale", "")).strip(),
            model=LLM_MODEL,
            provider=LLM_PROVIDER,
        )
    except (ValueError, KeyError, TypeError) as first_error:
        # One repair round-trip: show the model its own output and the parse error
        log.warning("structured output invalid (%s), retrying once", first_error)
        messages.append({"role": "assistant", "content": raw})
        messages.append(
            {
                "role": "user",
                "content": (
                    f"Your reply could not be parsed ({first_error}). "
                    "Reply again with ONLY the JSON object, no prose, no code fences."
                ),
            }
        )
        raw = await complete(messages)
        try:
            parsed = _extract_json(raw)
            result = ScoreResult(
                score=int(parsed["score"]),
                verdict=_derive_verdict(int(parsed["score"]), str(parsed.get("verdict", ""))),
                matched_skills=[str(s) for s in parsed.get("matched_skills", [])],
                missing_skills=[str(s) for s in parsed.get("missing_skills", [])],
                keywords=[str(s) for s in parsed.get("keywords", [])],
                rationale=str(parsed.get("rationale", "")).strip(),
                model=LLM_MODEL,
                provider=LLM_PROVIDER,
            )
        except (ValueError, KeyError, TypeError) as second_error:
            raise LLMError(f"Model returned non-parsable output: {second_error}") from second_error

    result.notify = result.score >= MATCH_SCORE_THRESHOLD
    return result


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@app.get("/health", tags=["ops"])
async def health() -> dict:
    return {"status": "ok", "service": "ai-service", "version": "1.0.0"}


@app.get("/health/detail", tags=["ops"])
async def health_detail() -> dict:
    return {
        "status": "ok",
        "service": "ai-service",
        "version": "1.0.0",
        "config": {
            "provider": LLM_PROVIDER,
            "model": LLM_MODEL,
            "openrouter_key_present": bool(OPENROUTER_API_KEY),
            "gemini_key_present": bool(GEMINI_API_KEY),
            "resume_loaded": bool(load_resume()),
            "resume_chars": len(load_resume()),
            "match_score_threshold": MATCH_SCORE_THRESHOLD,
        },
    }


@app.post("/score", tags=["score"])
async def score(req: ScoreRequest) -> dict:
    result = await score_job(req)
    return {"status": "ok", "result": result.model_dump()}


@app.post("/score/batch", tags=["score"])
async def score_batch(request: Request) -> Any:
    """Body: {"jobs": [Job, ...], "resume_text": optional, "keywords": optional}"""
    body = await request.json()
    jobs_raw = body.get("jobs")
    if not jobs_raw:
        return JSONResponse(
            status_code=400,
            content={"status": "error", "message": "Missing input field: jobs"},
        )
    resume_override = body.get("resume_text")
    keywords = body.get("keywords")
    semaphore = asyncio.Semaphore(3)

    async def one(job_raw: Dict[str, Any]) -> Dict[str, Any]:
        async with semaphore:
            try:
                req = ScoreRequest(
                    job=Job(**job_raw),
                    resume_text=resume_override,
                    keywords=keywords,
                )
                return {"status": "ok", "job": job_raw, "result": (await score_job(req)).model_dump()}
            except (LLMError, ValueError) as exc:
                return {"status": "error", "message": str(exc), "job": job_raw}

    results = await asyncio.gather(*(one(job) for job in jobs_raw))
    return {"status": "ok", "count": len(results), "results": list(results)}


if __name__ == "__main__":  # pragma: no cover
    import uvicorn

    uvicorn.run("main:app", host="0.0.0.0", port=8001, log_level=LOG_LEVEL.lower())
