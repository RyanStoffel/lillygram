FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY pyproject.toml ./
COPY lillygram_backend ./lillygram_backend
RUN pip install --no-cache-dir .

RUN useradd --create-home --uid 10001 lillygram \
    && mkdir -p /app/data \
    && chown -R lillygram:lillygram /app
USER lillygram

EXPOSE 8000
CMD ["uvicorn", "lillygram_backend.main:build_default_app", "--factory", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips", "*"]
