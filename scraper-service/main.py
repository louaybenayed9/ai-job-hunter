"""
AI Job Hunter - scraper-service
===============================
Lightweight FastAPI microservice that turns Tunisian job boards into clean JSON.

Exposed endpoints
-----------------
GET  /health                liveness probe
GET  /health/detail         liveness + configuration summary
GET  /scrape/keejob         Keejob search page  -> JobListing[]
GET  /scrape/tanitjobs      Tanitjobs search    -> JobListing[]
GET  /scrape/all            aggregate every source in one call

Selectors are grounded in the live markup of both sites (checked 2026-10):
  * keejob    -> <article> cards, h2/h3 > a[href*="/offres-emploi/<id>/"],
                 a[href*="/offres-emploi/entreprises/"], i.fa-map-marker-alt,
                 div.mb-3 > p  (description)
  * tanitjobs -> article.listing-item.listing-item__jobs,
                 .listing-item__title a, .listing-item-info-company,
                 .listing-item-info-location
"""

from __future__ import annotations

import asyncio
import itertools
import logging
import os
import re
from typing import Iterable, List, Optional
from urllib.parse import urljoin

import httpx
from bs4 import BeautifulSoup, Tag
from fastapi import FastAPI, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

# ---------------------------------------------------------------------------
# Configuration (from docker-compose environment)
# ---------------------------------------------------------------------------
LOG_LEVEL = os.getenv("LOG_LEVEL", "info").upper()
SCRAPE_DELAY_SECONDS = float(os.getenv("SCRAPE_DELAY_SECONDS", "1.0"))
SCRAPE_TIMEOUT_SECONDS = float(os.getenv("SCRAPE_TIMEOUT_SECONDS", "20"))
SCRAPE_MAX_PAGES = int(os.getenv("SCRAPE_MAX_PAGES", "3"))
USER_AGENT = os.getenv(
    "USER_AGENT",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0 Safari/537.36",
)

logging.basicConfig(
    level=LOG_LEVEL,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("scraper")

app = FastAPI(
    title="AI Job Hunter - Scraper Service",
    version="1.0.0",
    description="Scrapes Tunisian job boards and returns structured JSON for n8n.",
)

# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------


class JobListing(BaseModel):
    title: str
    company: Optional[str] = None
    location: Optional[str] = None
    description: Optional[str] = None
    link: str
    source: str


class ScrapeResponse(BaseModel):
    status: str = "ok"
    source: str
    keywords: Optional[str] = None
    page: int = 1
    count: int = 0
    jobs: List[JobListing] = Field(default_factory=list)


class HealthResponse(BaseModel):
    status: str
    service: str = "scraper-service"
    version: str = "1.0.0"


class ScrapingError(Exception):
    """Raised for upstream failures; answered with a uniform error envelope."""


# ---------------------------------------------------------------------------
# Error envelope: {"status": "error", "message": "..."}
# ---------------------------------------------------------------------------


@app.exception_handler(ScrapingError)
async def scraping_error_handler(_request: Request, exc: ScrapingError) -> JSONResponse:
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
# Shared helpers
# ---------------------------------------------------------------------------

_JOB_URL_RE = re.compile(r"/offres-emploi/\d+/")
_WS_RE = re.compile(r"\s+")


def _clean(text: Optional[str]) -> Optional[str]:
    if not text:
        return None
    collapsed = _WS_RE.sub(" ", text).strip()
    return collapsed or None


def _parser_for(_html: str) -> str:
    """lxml when available, html.parser as a safe fallback."""
    try:
        import lxml  # noqa: F401

        return "lxml"
    except ImportError:  # pragma: no cover
        return "html.parser"


def _parse_keejob(html: str, base: str = "https://www.keejob.com") -> List[JobListing]:
    soup = BeautifulSoup(html, _parser_for(html))
    jobs: List[JobListing] = []
    seen: set[str] = set()

    def add_job(
        link: Optional[str],
        title: Optional[str],
        company: Optional[str] = None,
        location: Optional[str] = None,
        description: Optional[str] = None,
    ) -> None:
        link = _clean(link)
        title = _clean(title)
        if not link or not title:
            return
        link = urljoin(base, link).split("?")[0]
        if link in seen:
            return
        seen.add(link)
        jobs.append(
            JobListing(
                title=title,
                company=_clean(company),
                location=_clean(location),
                description=_clean(description),
                link=link,
                source="keejob",
            )
        )

    # --- Primary layout: search results are <article> cards ---------------
    for card in soup.find_all("article"):
        if not isinstance(card, Tag):
            continue
        title_a = None
        for anchor in card.find_all("a", href=True):
            if _JOB_URL_RE.search(anchor["href"]):
                title_a = anchor
                break
        if title_a is None:
            continue

        company_a = None
        for anchor in card.select('a[href*="/offres-emploi/entreprises/"]'):
            if anchor.get_text(" ", strip=True):
                company_a = anchor
                break
        if company_a is not None:
            company_text = company_a.get_text(" ", strip=True)
        else:
            # anonymous listings render the company as plain text (e.g. "Entreprise Anonyme")
            company_p = card.select_one("p.mb-2")
            company_text = company_p.get_text(" ", strip=True) if company_p else None
        icon = card.select_one("i.fa-map-marker-alt")
        location_span = icon.find_next("span") if icon else None
        description_p = card.select_one("div.mb-3 > p") or card.find("p", class_=re.compile("leading-relaxed"))

        add_job(
            link=title_a["href"],
            title=title_a.get_text(" ", strip=True),
            company=company_text,
            location=location_span.get_text(" ", strip=True) if location_span else None,
            description=description_p.get_text(" ", strip=True) if description_p else None,
        )

    if jobs:
        return jobs

    # --- Fallback layout: homepage-style h2/h3 blocks (no <article>) ------
    for heading in soup.find_all(["h2", "h3"]):
        if not isinstance(heading, Tag):
            continue
        title_a = heading.find("a", href=True)
        if not title_a or not _JOB_URL_RE.search(title_a["href"]):
            continue
        block = heading.find_parent(["article", "div", "section"]) or heading
        company_text = None
        if isinstance(block, Tag):
            for anchor in block.select('a[href*="/offres-emploi/entreprises/"]'):
                if anchor.get_text(" ", strip=True):
                    company_text = anchor.get_text(" ", strip=True)
                    break
            if company_text is None:
                company_p = block.select_one("p.mb-2")
                company_text = company_p.get_text(" ", strip=True) if company_p else None
        icon = block.select_one("i.fa-map-marker-alt") if isinstance(block, Tag) else None
        location_span = icon.find_next("span") if icon else None
        description_p = block.find("p") if isinstance(block, Tag) else None
        add_job(
            link=title_a["href"],
            title=title_a.get_text(" ", strip=True),
            company=company_text,
            location=location_span.get_text(" ", strip=True) if location_span else None,
            description=description_p.get_text(" ", strip=True) if description_p else None,
        )
    return jobs


def _parse_tanitjobs(html: str, base: str = "https://www.tanitjobs.com") -> List[JobListing]:
    """Two live layouts exist: div.sj-job-card on /jobs/ search results and
    article.listing-item__jobs on the older listing pages."""
    soup = BeautifulSoup(html, _parser_for(html))
    jobs: List[JobListing] = []
    seen: set[str] = set()

    for card in soup.select("div.sj-job-card, article.listing-item__jobs, article.listing-item"):
        if not isinstance(card, Tag):
            continue
        title_a = card.select_one(".sj-card-title a, .listing-item__title a, a.link")
        if title_a is None or not title_a.get("href"):
            continue
        link = urljoin(base, title_a["href"]).split("?")[0]
        if link in seen:
            continue
        seen.add(link)

        company_a = card.select_one(".sj-card-company a")
        company = card.select_one(".listing-item-info-company")
        location = card.select_one(".sj-card-tags .sj-loc, .listing-item-info-location")
        description = card.select_one(".sj-card-desc, .listing-item__description, .listing-item__text")

        company_text = (
            company_a.get_text(" ", strip=True)
            if company_a
            else (company.get_text(" ", strip=True) if company else None)
        )
        if company_text:
            company_text = company_text.rstrip(" -").strip() or None

        title_text = _clean(title_a.get_text(" ", strip=True))
        if not title_text:
            continue
        jobs.append(
            JobListing(
                title=title_text,
                company=_clean(company_text),
                location=_clean(location.get_text(" ", strip=True)) if location else None,
                description=_clean(description.get_text(" ", strip=True)) if description else None,
                link=link,
                source="tanitjobs",
            )
        )
    return jobs


async def _fetch(client: httpx.AsyncClient, url: str) -> str:
    log.info("GET %s", url)
    try:
        response = await client.get(url, timeout=SCRAPE_TIMEOUT_SECONDS)
    except httpx.HTTPError as exc:
        raise ScrapingError(f"Upstream request failed: {exc.__class__.__name__}: {exc}") from exc
    if response.status_code != 200:
        raise ScrapingError(f"Upstream returned HTTP {response.status_code} for {url}")
    return response.text


async def _scrape_paginated(
    base_url: str,
    parser,
    keywords: Optional[str],
    page: int,
    limit: int,
    param_builder,
) -> List[JobListing]:
    results: List[JobListing] = []
    pages_to_fetch = min(SCRAPE_MAX_PAGES, max(1, -(-limit // 15)))  # ~15 cards/page
    async with httpx.AsyncClient(
        headers={"User-Agent": USER_AGENT, "Accept-Language": "fr,en;q=0.8"},
        follow_redirects=True,
    ) as client:
        for offset in range(pages_to_fetch):
            current_page = page + offset
            url = param_builder(base_url, keywords, current_page)
            html = await _fetch(client, url)
            batch = parser(html)
            results.extend(batch)
            if len(results) >= limit or not batch:
                break
            if offset < pages_to_fetch - 1 and SCRAPE_DELAY_SECONDS > 0:
                await asyncio.sleep(SCRAPE_DELAY_SECONDS)  # be polite
    return results[:limit]


def _keejob_url(base: str, keywords: Optional[str], page: int) -> str:
    params = []
    if keywords:
        params.append(f"keywords={httpx.QueryParams({'k': keywords})['k']}")
    if page > 1:
        params.append(f"page={page}")
    return f"{base}{'?' + '&'.join(params) if params else ''}"


def _tanitjobs_url(base: str, keywords: Optional[str], page: int) -> str:
    params = []
    if keywords:
        params.append(f"keywords%5Ball_words%5D={httpx.QueryParams({'k': keywords})['k']}")
    if page > 1:
        params.append(f"page={page}")
    return f"{base}{'?' + '&'.join(params) if params else ''}"


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@app.get("/health", response_model=HealthResponse, tags=["ops"])
async def health() -> HealthResponse:
    return HealthResponse(status="ok")


@app.get("/health/detail", tags=["ops"])
async def health_detail() -> dict:
    return {
        "status": "ok",
        "service": "scraper-service",
        "version": "1.0.0",
        "config": {
            "scrape_delay_seconds": SCRAPE_DELAY_SECONDS,
            "scrape_timeout_seconds": SCRAPE_TIMEOUT_SECONDS,
            "scrape_max_pages": SCRAPE_MAX_PAGES,
            "sources": ["keejob", "tanitjobs"],
        },
    }


@app.get("/scrape/keejob", response_model=ScrapeResponse, tags=["scrape"])
async def scrape_keejob(
    keywords: Optional[str] = Query(default=None, description="Search keywords, e.g. 'developpeur'"),
    page: int = Query(default=1, ge=1, le=50),
    limit: int = Query(default=15, ge=1, le=100),
) -> ScrapeResponse:
    """Scrape https://www.keejob.com/offres-emploi/ search results."""
    jobs = await _scrape_paginated(
        base_url="https://www.keejob.com/offres-emploi/",
        parser=_parse_keejob,
        keywords=keywords,
        page=page,
        limit=limit,
        param_builder=_keejob_url,
    )
    return ScrapeResponse(source="keejob", keywords=keywords, page=page, count=len(jobs), jobs=jobs)


@app.get("/scrape/tanitjobs", response_model=ScrapeResponse, tags=["scrape"])
async def scrape_tanitjobs(
    keywords: Optional[str] = Query(default=None, description="Search keywords, e.g. 'developpeur'"),
    page: int = Query(default=1, ge=1, le=50),
    limit: int = Query(default=15, ge=1, le=100),
) -> ScrapeResponse:
    """Scrape https://www.tanitjobs.com/jobs/ search results."""
    jobs = await _scrape_paginated(
        base_url="https://www.tanitjobs.com/jobs/",
        parser=_parse_tanitjobs,
        keywords=keywords,
        page=page,
        limit=limit,
        param_builder=_tanitjobs_url,
    )
    return ScrapeResponse(source="tanitjobs", keywords=keywords, page=page, count=len(jobs), jobs=jobs)


@app.get("/scrape/all", response_model=ScrapeResponse, tags=["scrape"])
async def scrape_all(
    keywords: Optional[str] = Query(default=None),
    limit: int = Query(default=15, ge=1, le=200),
) -> ScrapeResponse:
    """Fan out to every configured source; partial failures are reported, not fatal."""

    async def safe(coro) -> List[JobListing]:
        try:
            return await coro
        except ScrapingError as exc:
            log.warning("source failed: %s", exc)
            return []

    keejob, tanitjobs = await asyncio.gather(
        safe(
            _scrape_paginated(
                "https://www.keejob.com/offres-emploi/",
                _parse_keejob,
                keywords,
                1,
                limit,
                _keejob_url,
            )
        ),
        safe(
            _scrape_paginated(
                "https://www.tanitjobs.com/jobs/",
                _parse_tanitjobs,
                keywords,
                1,
                limit,
                _tanitjobs_url,
            )
        ),
    )
    # Interleave so one fast source cannot crowd the other out of `limit`
    merged: Iterable[JobListing] = [
        job
        for pair in itertools.zip_longest(keejob, tanitjobs)
        for job in pair
        if job is not None
    ]
    jobs = list(merged)[:limit]
    return ScrapeResponse(
        source="all",
        keywords=keywords,
        page=1,
        count=len(jobs),
        jobs=jobs,
    )


if __name__ == "__main__":  # pragma: no cover
    import uvicorn

    uvicorn.run("main:app", host="0.0.0.0", port=8000, log_level=LOG_LEVEL.lower())
