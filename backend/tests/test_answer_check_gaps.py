"""
Answer check gaps:

Gap 2: a strong retrieval match (simple query + top doc >= 70%) used to skip
the check entirely, so an answer that went beyond the document was never
checked. Now the cheap deterministic checks always run, and the LLM is only
called when they are inconclusive.

Gap 1: a correct "that's not in your documents" answer is recognised and
reported as not_found, instead of being flagged as unverified.

Uses the real sample document; the LLM is a mock that fails the test if called.
"""
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

import pytest

from rag.nodes import RAGNodes

POLICY = (Path(__file__).resolve().parents[2] / "sample-docs" / "northwind-remote-work-policy.md").read_text(
    encoding="utf-8"
)
STIPEND_SECTION = POLICY[POLICY.index("## 3. Equipment"):POLICY.index("## 4. Security")]


def nodes_without_llm():
    nodes = RAGNodes.__new__(RAGNodes)
    nodes.llm = MagicMock()
    nodes.llm.ainvoke = AsyncMock(side_effect=AssertionError("the LLM should not be needed"))
    return nodes


def state(answer, *, complexity="simple", score=88.0, content=STIPEND_SECTION):
    return {
        "answer": answer,
        "query_complexity": complexity,
        "iteration": 0,
        "relevant_documents": [
            {"content": content, "metadata": {"source": "northwind-remote-work-policy.md"}, "relevance_score": score}
        ],
    }


# --- Gap 2: the strong-match shortcut no longer skips the check -------------

JAPAN_ANSWER = (
    "The remote work stipend for employees based in Japan is 600 EUR, plus 45 EUR per month "
    "toward internet costs. Northwind issues a laptop, a 27-inch monitor, and a headset to remote staff."
)


@pytest.mark.asyncio
async def test_japan_stipend_answer_is_checked_and_flagged():
    """Live answer to "What is the remote work stipend for employees based in Japan...?"
    The document never mentions Japan; the retrieval match was strong (simple, 88%)."""
    s = state(JAPAN_ANSWER)
    assert RAGNodes.hallucination_check_will_run(s) is True

    result = await nodes_without_llm().check_hallucination(s)

    assert result["is_grounded"] is False
    assert result["answer_not_found"] is False
    assert "Japan" in result["hallucination_details"]
    assert result["processing_steps"] == ["hallucination_unsupported_specifics"]


@pytest.mark.asyncio
async def test_invented_number_is_flagged():
    result = await nodes_without_llm().check_hallucination(
        state("Remote employees receive a one-time home-office stipend of 900 EUR.")
    )
    assert result["is_grounded"] is False
    assert "900" in result["hallucination_details"]


@pytest.mark.asyncio
async def test_simple_grounded_question_still_takes_the_fast_path():
    """"How much is the home-office stipend?" answered from the document: passes
    on the deterministic checks alone, no LLM call."""
    result = await nodes_without_llm().check_hallucination(
        state("The home-office stipend is 600 EUR, plus 45 EUR per month toward internet costs.")
    )
    assert result["is_grounded"] is True
    assert result["processing_steps"] == ["hallucination_fast_pass"]
    assert result["skip_llm_hallucination_check"] is True


def test_names_inside_a_not_mentioned_sentence_are_not_flagged():
    answer = "The stipend is 600 EUR. The policy does not mention Japan."
    assert RAGNodes._unsupported_specifics(answer, [{"content": STIPEND_SECTION}]) == []


def test_sentence_start_capitals_and_list_items_are_not_names():
    answer = "Remote employees receive 600 EUR.\n- Receipts go through the Expensa portal.\n1. Northwind provides a headset."
    assert RAGNodes._unsupported_specifics(answer, [{"content": STIPEND_SECTION}]) == []


# --- Gap 1: "not in your documents" gets its own result ----------------------

PETS_ANSWER = (
    "There is no mention of pets, childcare, or working from a beach abroad in the provided policy document."
)


@pytest.mark.asyncio
async def test_pets_childcare_beach_answer_is_not_found():
    """Live answer to "Explain the policy's rules on pets, childcare and working from a
    beach abroad, with the exact penalties for each." It is correct, so not a warning."""
    result = await nodes_without_llm().check_hallucination(state(PETS_ANSWER, complexity="complex", score=40.0))
    assert result["answer_not_found"] is True
    assert result["is_grounded"] is True
    assert result["processing_steps"] == ["hallucination_not_found"]


@pytest.mark.parametrize(
    "answer, expected",
    [
        (PETS_ANSWER, True),
        ("I'm sorry. The provided documents do not contain information about parental leave.", True),
        ("The policy doesn't specify a dress code for video calls.", True),
        ("The stipend is 600 EUR. The policy does not mention Japan.", False),  # has a real answer
        (JAPAN_ANSWER, False),
        ("The home-office stipend is 600 EUR.", False),
    ],
)
def test_not_found_detection(answer, expected):
    assert RAGNodes._is_not_found_answer(answer) is expected


@pytest.mark.asyncio
async def test_done_event_carries_not_found():
    from types import SimpleNamespace
    from test_verifying_status import make_pipeline, collect

    pipe = make_pipeline()
    pipe.nodes.check_hallucination = AsyncMock(return_value={"is_grounded": True, "answer_not_found": True})
    events = await collect(pipe)
    assert events[-1]["type"] == "done"
    assert events[-1]["not_found"] is True
    assert events[-1]["was_checked"] is True

    from api.routes import chat
    from unittest.mock import patch

    async def fake_astream(message, session_id, collection):
        yield {"type": "done", "is_grounded": True, "was_checked": True, "not_found": True}

    with patch.object(chat, "get_pipeline", return_value=SimpleNamespace(astream=fake_astream)):
        import json
        out = [json.loads(e) async for e in chat.generate_stream("q", "s1", "coll")]
    assert out[-1]["not_found"] is True
