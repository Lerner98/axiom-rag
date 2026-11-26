"""
The streamed answer tells the UI when the groundedness check runs.

After the last answer token the pipeline may spend several seconds checking
the answer against its sources. It emits {"type": "status", "step": "verifying"}
before that check (only when a check really runs), and the done event says
whether a check ran (was_checked) and its verdict (is_grounded).

The LLM and retrieval nodes are mocked; no Ollama needed.
"""
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from rag.nodes import RAGNodes
from rag.pipeline import RAGPipeline

DOC = {"content": "Employees get 20 vacation days.", "metadata": {"source": "policy.md"}}


class FakeLLM:
    """Streams a fixed answer token by token."""

    def __init__(self, tokens):
        self.tokens = tokens

    async def astream(self, prompt):
        for t in self.tokens:
            yield SimpleNamespace(content=t)


def make_pipeline(*, intent="question", complexity="complex", top_score=55.0,
                  docs=True, grounded=True):
    """A RAGPipeline with mocked nodes, skipping the real constructor."""
    pipe = RAGPipeline.__new__(RAGPipeline)
    pipe.llm = FakeLLM(["Twenty ", "days."])
    pipe.memory = None
    pipe._build_context = lambda documents: "context"
    pipe._get_chat_history = AsyncMock(return_value="")

    relevant = [dict(DOC, relevance_score=top_score)] if docs else []
    nodes = MagicMock()
    nodes.classify_intent = AsyncMock(return_value={"detected_intent": intent})
    nodes.handle_non_rag_intent = AsyncMock(return_value={"answer": "Hello there"})
    nodes.route_query = AsyncMock(return_value={"query_complexity": complexity, "skip_rewrite": True})
    nodes.retrieve = AsyncMock(return_value={"relevant_documents": relevant})
    nodes.grade_documents = AsyncMock(return_value={"sources": [{"filename": "policy.md"}]})
    nodes.check_hallucination = AsyncMock(return_value={"is_grounded": grounded})
    nodes.save_to_memory = AsyncMock(return_value={})
    nodes.hallucination_check_will_run = RAGNodes.hallucination_check_will_run
    pipe.nodes = nodes
    return pipe


async def collect(pipe, question="How many vacation days?"):
    return [e async for e in pipe.astream(question, "s1", "chat_x")]


@pytest.mark.asyncio
async def test_verifying_status_comes_after_last_token_and_before_done():
    events = await collect(make_pipeline())
    types = [e["type"] for e in events]

    assert {"type": "status", "step": "verifying"} in events
    status_at = types.index("status")
    last_token_at = max(i for i, t in enumerate(types) if t == "token")
    assert last_token_at < status_at < types.index("done")
    assert types.count("status") == 1

    done = events[-1]
    assert done["type"] == "done"
    assert done["was_checked"] is True
    assert done["is_grounded"] is True


@pytest.mark.asyncio
async def test_not_grounded_verdict_reaches_done_event():
    events = await collect(make_pipeline(grounded=False))
    done = events[-1]
    assert done["was_checked"] is True
    assert done["is_grounded"] is False


@pytest.mark.asyncio
async def test_no_status_when_check_is_skipped_for_simple_high_confidence():
    events = await collect(make_pipeline(complexity="simple", top_score=85.0))
    assert all(e["type"] != "status" for e in events)
    assert events[-1]["was_checked"] is False


@pytest.mark.asyncio
async def test_no_status_when_no_documents_were_found():
    events = await collect(make_pipeline(docs=False))
    assert all(e["type"] != "status" for e in events)
    assert events[-1]["was_checked"] is False


@pytest.mark.asyncio
async def test_no_status_for_greeting():
    events = await collect(make_pipeline(intent="greeting"), question="hi")
    assert all(e["type"] != "status" for e in events)
    assert events[-1]["type"] == "done"
    assert events[-1].get("was_checked", False) is False


@pytest.mark.parametrize(
    "state, expected",
    [
        ({"relevant_documents": []}, False),
        ({"query_complexity": "simple", "relevant_documents": [dict(DOC, relevance_score=90)]}, False),
        ({"query_complexity": "simple", "relevant_documents": [dict(DOC, relevance_score=40)]}, True),
        ({"query_complexity": "complex", "relevant_documents": [dict(DOC, relevance_score=90)]}, True),
    ],
)
@pytest.mark.asyncio
async def test_prediction_matches_what_check_hallucination_does(state, expected):
    """hallucination_check_will_run must agree with check_hallucination's skip paths."""
    nodes = RAGNodes.__new__(RAGNodes)
    nodes._fast_groundedness_check = MagicMock(return_value=0.9)  # passes without the LLM
    state = dict(state, answer="Twenty days.", iteration=0)

    result = await nodes.check_hallucination(state)
    really_checked = nodes._fast_groundedness_check.called

    assert RAGNodes.hallucination_check_will_run(state) is expected
    assert really_checked is expected
    assert result["is_grounded"] is True


@pytest.mark.asyncio
async def test_sse_route_forwards_status_and_was_checked():
    from api.routes import chat

    async def fake_astream(message, session_id, collection):
        yield {"type": "token", "content": "Twenty days."}
        yield {"type": "status", "step": "verifying"}
        yield {"type": "done", "is_grounded": False, "was_checked": True}

    fake = SimpleNamespace(astream=fake_astream)
    with patch.object(chat, "get_pipeline", return_value=fake):
        out = [json.loads(e) async for e in chat.generate_stream("q", "s1", "coll")]

    assert out[1] == {"type": "status", "step": "verifying"}
    assert out[2]["type"] == "done"
    assert out[2]["was_checked"] is True
    assert out[2]["was_grounded"] is False
