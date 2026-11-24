# Axiom RAG

A local-first document Q&A system with source citations and hallucination detection.

## Overview

Axiom RAG enables question-answering over private documents without sending data to external services. All processing happens locally using Ollama for LLM inference and ChromaDB for vector storage.

### Core Capabilities

- **Document Ingestion**: PDF, TXT, MD, DOCX support with parent-child chunking
- **Hybrid Search**: Vector similarity (FastEmbed) combined with BM25 keyword matching
- **Cross-Encoder Reranking**: Neural reranking for improved relevance
- **Source Citations**: Every answer includes document and page references
- **Hallucination Detection**: Hybrid verification (deterministic + LLM) ensures answers are grounded
- **Session Isolation**: Each chat maintains separate document context
- **Real-time Streaming**: Token-by-token response delivery

## Try it on your PC (Windows, no GPU needed)

1. **Download** the project: click the green **Code** button on this page, then **Download ZIP**.
   Unzip it anywhere (for example, your Desktop).
2. **Double-click `Start-Axiom.bat`** in the unzipped folder.
   - If Windows shows "Windows protected your PC", click **More info**, then **Run anyway**.
   - The first run installs what it needs (Python, Node.js and Ollama if missing) and downloads
     the AI model. It takes about 10-20 minutes and needs ~5 GB of free disk space.
     Later runs start in under a minute.
3. Your browser opens at **http://localhost:8080**. Click **New chat**, upload a document
   (PDF, Word, TXT or Markdown; there is a sample in [`sample-docs/`](sample-docs)), and ask a question.
   Answers stream in with the source passages they came from.

Keep the black window open while you use the app; close it to stop.
Everything runs on your computer. Your documents never leave it.

**No graphics card? No problem.** Setup checks for an NVIDIA GPU with 6 GB+ of memory. If it
finds one, it uses `llama3.1:8b` on the GPU. Otherwise it runs the smaller `llama3.2:3b` on the
processor (CPU mode).

| Measured on an Intel Core Ultra 9 285K, CPU only (`COMPUTE_DEVICE=cpu`, GPU unused) | Time |
|---|---|
| First words of the answer appear (median) | 2.1 s |
| Complete answer (median / slowest of 5) | 4.4 s / 6.6 s |
| Same, limited to 4 CPU threads (closer to a typical laptop) | 6.2 s / 10.1 s |

A typical office laptop is slower than this desktop. As an estimate (not measured), expect roughly 10-40 seconds per answer.
To re-measure on your machine, run `python benchmark_latency.py` in `original_rag/backend` while the app is running.

### Options

Run from PowerShell in the project folder (or pass the same options to `Start-Axiom.bat`):

```powershell
.\setup.ps1 -Mode cpu                 # force CPU mode even if you have a GPU
.\setup.ps1 -Mode gpu                 # force GPU mode
.\setup.ps1 -Model llama3.2:1b        # smaller, faster model for older PCs
.\setup.ps1 -InstallOnly              # install everything, don't start
```

Settings live in `original_rag/backend/.env`. The key ones are `OLLAMA_MODEL`,
`COMPUTE_DEVICE` (`auto` / `cpu` / `gpu`) and `OLLAMA_NUM_THREAD`. Logs are written to `logs/`.

### Troubleshooting

| Problem | Fix |
|---|---|
| "Port 8001/8080 is already in use" | Axiom is already running in another window. Close it and try again. |
| Setup says Python/Node "was installed but this window cannot see it yet" | Close the window and double-click `Start-Axiom.bat` again. |
| `winget` is missing (older Windows 10) | Install **App Installer** from the Microsoft Store, or install [Python 3.12](https://www.python.org/downloads/), [Node.js LTS](https://nodejs.org/) and [Ollama](https://ollama.com/download) yourself, then run again. |
| Answers are very slow | Run `Start-Axiom.bat -Model llama3.2:1b`. |

## Manual setup (developers)

Requires Python 3.11-3.13, Node.js 18+ and [Ollama](https://ollama.com/download).

```powershell
ollama pull llama3.2:3b                      # or llama3.1:8b with a 6 GB+ GPU

cd original_rag\backend
python -m venv .venv
.venv\Scripts\pip install -r requirements-app.txt -c constraints.txt   # requirements.txt adds eval/dev tools
"OLLAMA_MODEL=llama3.2:3b`nCOMPUTE_DEVICE=cpu" | Set-Content .env
.venv\Scripts\python -m uvicorn api.main:app --port 8001

# second terminal
cd original_rag\frontend
npm ci
npm run dev                                  # http://localhost:8080
```

## Architecture

| Component | Technology |
|-----------|------------|
| Frontend | React, TypeScript, Vite, Tailwind, shadcn/ui |
| Backend | FastAPI, LangGraph |
| LLM | Ollama (llama3.1:8b on GPU, llama3.2:3b on CPU) |
| Embeddings | FastEmbed (BAAI/bge-small-en-v1.5) |
| Vector Store | ChromaDB |
| Reranker | Cross-Encoder (ms-marco-MiniLM-L-6-v2) |
| Keyword Search | BM25 (rank-bm25) |

## System Requirements

| Resource | CPU mode (any PC) | GPU mode |
|----------|---------|---------|
| OS | Windows 10/11 (64-bit) | Windows 10/11 (64-bit) |
| RAM | 8 GB | 8 GB |
| GPU | Not needed | NVIDIA, 6 GB+ VRAM |
| Disk | ~5 GB free | ~8 GB free |

Python 3.11-3.13, Node.js 18+ and Ollama are installed automatically by `Start-Axiom.bat` if missing.

## Project Structure

```
original_rag/
├── backend/          # FastAPI application
│   ├── api/          # HTTP endpoints
│   ├── rag/          # Pipeline, nodes, retrieval
│   ├── ingest/       # Document processing
│   ├── vectorstore/  # ChromaDB integration
│   └── memory/       # Session storage
├── frontend/         # React application
└── docs/             # Technical documentation
```

## Documentation

Technical documentation is available in `original_rag/docs/`:

- `PROJECT_ARCHITECTURE.md` - System design and component overview
- `RAG_Pipeline_Architecture.md` - Detailed pipeline documentation
- `ENGINEERING_JOURNEY.md` - Optimization history and decisions
- `BENCHMARK_RESULTS.md` - Performance measurements
- `adrs/` - Architecture Decision Records

## License

MIT
