# Docker Deployment

Run the whole stack (Ollama, the backend API and the web UI) in containers. CPU by default;
an NVIDIA GPU is optional.

> **Last verified:** 2026-11-25 on Windows 11 with Docker Desktop 29.2 (CPU mode): a clean
> `docker compose up --build` took ~12 minutes including the model download, all services
> reported healthy, and the UI flow (upload, ask, streamed answer with sources) worked end to end.

## Quick start

```bash
docker compose up --build          # first run builds images and downloads the model
# open http://localhost:3000
docker compose down                # stop (documents and models are kept in volumes)
```

With an NVIDIA GPU (requires GPU support in Docker Desktop or the NVIDIA Container Toolkit):

```bash
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up --build
```

Use a different model: `OLLAMA_MODEL=llama3.2:1b docker compose up` (the `model` service pulls it).

## Services

| Service | Image | Port | Role |
|---|---|---|---|
| `ollama` | `ollama/ollama:0.40.18` | internal only | Runs the LLM; models live in the `ollama_models` volume |
| `model` | `ollama/ollama:0.40.18` | none | One-shot: pulls `OLLAMA_MODEL` into the volume, then exits |
| `api` | built from `backend/Dockerfile` | 8001 | FastAPI + LangGraph; waits for the model pull to finish |
| `frontend` | built from `frontend/Dockerfile` | 3000 | Static Vite build served by nginx; waits for a healthy API |

Startup order is enforced with healthchecks: `ollama` healthy -> `model` completed -> `api`
healthy (`GET /health`) -> `frontend`.

## Configuration

The compose file sets the essentials; everything else uses the defaults in
[`backend/.env.example`](../backend/.env.example).

| Variable | Default (CPU) | GPU override |
|---|---|---|
| `OLLAMA_MODEL` | `llama3.2:3b` | `llama3.1:8b` |
| `COMPUTE_DEVICE` | `cpu` | `gpu` |
| `MEMORY_BACKEND` | `sqlite` (in the `api_data` volume) | same |
| `CORS_ORIGINS` | `["http://localhost:3000","http://127.0.0.1:3000"]` | same |

The Ollama container runs with `OLLAMA_KV_CACHE_TYPE=q8_0` and `OLLAMA_FLASH_ATTENTION=1`.

## Image notes

- The backend image installs **CPU-only PyTorch** first (the default wheel pulls ~2 GB of CUDA
  libraries the cross-encoder doesn't need), then `requirements-app.txt` pinned by `constraints.txt`.
- Hugging Face models (embeddings, reranker) download on first use into `/app/data/hf-cache`,
  inside the `api_data` volume, so they survive rebuilds.
- `.dockerignore` files keep `node_modules`, `.venv`, local data and `.env` out of the build context.

## Useful commands

```bash
docker compose ps                         # status and health
docker compose logs -f api                # backend logs
docker compose exec ollama ollama ps      # which model is loaded, CPU or GPU
docker compose down -v                    # stop and delete volumes (documents, models)
```
