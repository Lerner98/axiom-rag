"""
End-to-end answer latency through the running API (upload -> ask -> stream).

Usage (backend must be running on :8001):
    .venv\\Scripts\\python benchmark_latency.py [--runs 1] [--doc PATH]

Prints time-to-first-token and total time for each question, plus medians.
"""
import argparse
import json
import statistics
import time
import uuid
from pathlib import Path

import httpx

API = "http://127.0.0.1:8001"
DEFAULT_DOC = Path(__file__).resolve().parents[2] / "sample-docs" / "northwind-remote-work-policy.md"
QUESTIONS = [
    "How much is the home-office stipend?",
    "What are the core hours for remote employees?",
    "Who is not eligible for remote work and why?",
    "What should I do if my laptop is stolen?",
    "Summarize the security requirements.",
]


def ask(client: httpx.Client, chat_id: str, question: str) -> dict:
    t0 = time.perf_counter()
    first = None
    answer = []
    grounded = None
    with client.stream("POST", f"{API}/chat/{chat_id}/stream",
                       json={"message": question, "session_id": chat_id}) as r:
        r.raise_for_status()
        for line in r.iter_lines():
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if not payload:
                continue
            try:
                evt = json.loads(payload)
            except json.JSONDecodeError:
                continue
            if evt.get("type") == "token":
                if first is None:
                    first = time.perf_counter() - t0
                answer.append(evt.get("content", ""))
            elif "was_grounded" in evt:
                grounded = evt["was_grounded"]
            elif evt.get("type") == "error" or "code" in evt:
                raise RuntimeError(evt)
    total = time.perf_counter() - t0
    return {"ttft": first or total, "total": total, "answer": "".join(answer).strip(), "grounded": grounded}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--doc", type=Path, default=DEFAULT_DOC)
    args = ap.parse_args()

    health = httpx.get(f"{API}/health", timeout=10).json()
    print("health:", health.get("status"), health.get("services"))

    chat_id = f"bench-{uuid.uuid4().hex[:8]}"
    with httpx.Client(timeout=600) as client:
        with args.doc.open("rb") as f:
            t0 = time.perf_counter()
            r = client.post(f"{API}/chat/{chat_id}/documents", files={"files": (args.doc.name, f)})
            r.raise_for_status()
            print(f"upload: {time.perf_counter() - t0:.1f}s")

        rows = []
        for run in range(args.runs):
            for q in QUESTIONS:
                res = ask(client, chat_id, q)
                rows.append(res)
                print(f"\n[{run + 1}] Q: {q}\n    ttft={res['ttft']:.1f}s total={res['total']:.1f}s "
                      f"grounded={res['grounded']}\n    A: {res['answer'][:300]}")

        client.delete(f"{API}/chat/{chat_id}")

    print("\nmedian ttft  = %.1fs" % statistics.median(r["ttft"] for r in rows))
    print("median total = %.1fs" % statistics.median(r["total"] for r in rows))
    print("max total    = %.1fs" % max(r["total"] for r in rows))


if __name__ == "__main__":
    main()
