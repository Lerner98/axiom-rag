# Axiom RAG backend (FastAPI + LangGraph). CPU-only image; the LLM runs in the
# separate Ollama container (see docker-compose.yml).
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HF_HOME=/app/data/hf-cache

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

# CPU-only torch first (the default wheel pulls ~2 GB of CUDA libraries),
# then the runtime dependencies at their tested versions.
COPY requirements-app.txt constraints.txt ./
RUN pip install torch==2.15.0 --index-url https://download.pytorch.org/whl/cpu \
    && pip install -r requirements-app.txt -c constraints.txt

COPY api/ ./api/
COPY config/ ./config/
COPY ingest/ ./ingest/
COPY memory/ ./memory/
COPY rag/ ./rag/
COPY vectorstore/ ./vectorstore/
COPY main.py .

RUN mkdir -p /app/data

EXPOSE 8001
HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=5 \
    CMD curl -fsS http://localhost:8001/health || exit 1

CMD ["python", "-m", "uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8001"]
