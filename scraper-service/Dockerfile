# ------------------------------------------------------------------
# AI Job Hunter - scraper-service image
# FastAPI + BeautifulSoup/httpx, exposes site scrapers as HTTP APIs
# ------------------------------------------------------------------
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# Install dependencies first so source edits don't bust the layer cache
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Run as a non-root user
RUN useradd --create-home --shell /usr/sbin/nologin app \
    && chown -R app:app /app
USER app

COPY . .

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=8s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/health', timeout=5).status==200 else 1)"

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
