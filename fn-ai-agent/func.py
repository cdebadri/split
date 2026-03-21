"""
fn-ai-agent: OCI Function

Implements the AI agent loop using langchain.agents.create_agent with Gemini as the LLM.
Tools:
  - sum_tool:    calculates sum(price * quantity) for an array of items
  - verify_tool: returns sum(shares) - total; zero means shares balance

create_agent returns a compiled StateGraph that runs the tool-calling loop
until no tool calls remain in the response. Prior conversation turns are
loaded from OCI NoSQL and passed as the messages list so the model has full
session context. Only human/AI message pairs are persisted back to NoSQL
(tool messages are transient).

Expected input JSON (from OCI Workflow):
  {
    "bill_text": "<invoice text>",    # present for image-flow
    "body": {                          # original Slack event body
      "event": {
        "text": "<user message>",
        "ts": "<thread timestamp>"
      }
    },
    "thread_ts": "<ts>"               # may come from fn-image-extractor
  }

Returns JSON:
  {
    "output": "<agent final answer>",
    "thread_ts": "<original event ts>"
  }
"""

import io
import json
import logging
import os
from typing import Annotated

import fdk.context
import fdk.response
import oci
from langchain.agents import create_agent
from langchain_core.messages import AIMessage, BaseMessage, HumanMessage
from langchain_google_genai import ChatGoogleGenerativeAI
from langchain_core.tools import tool
from vault import get_secret

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """
## CONTEXT
You are an expert in calculating individual shares from a total amount based on
individual expenditure. You are given a total bill amount, the prices of individual
items, their quantities, and what portion each person shared. Calculate the total
individual share of each person out of the total.

## TOOLS
- sum_tool:    Use to calculate the sum of amounts (price * quantity per item).
- verify_tool: Use to check whether the sum of all individual shares equals the total.

## INSTRUCTIONS
- Call sum_tool to calculate individual shares.
- Use verify_tool to verify that all shares add up to the total.

## IMPORTANT
- Always use the tools for calculations.
- If verify_tool returns a non-zero value, redo the calculation.
- If verify_tool returns zero, return the individual shares.
- Pass only the required values to tools as described by their schemas.
- Only output the shares of each food item and total for every individual.
""".strip()


# ---------------------------------------------------------------------------
# LangChain tools
# ---------------------------------------------------------------------------

@tool
def sum_tool(
    amounts: Annotated[
        list[dict],
        "Array of objects with 'price' (number) and 'quantity' (number) fields.",
    ],
) -> float:
    """Calculate the total amount from an array of items (price * quantity each). Returns the sum."""
    total = 0.0
    for item in amounts:
        total += float(item.get("price", 0)) * float(item.get("quantity", 0))
    return total


@tool
def verify_tool(
    total: Annotated[float, "The total bill amount."],
    shares: Annotated[list[float], "Array of individual share amounts."],
) -> float:
    """
    Verify that individual shares balance against the total.
    Returns 0.0 if balanced. Non-zero means the shares don't add up — redo the calculation.
    """
    return round(sum(float(s) for s in shares) - float(total), 10)


TOOLS = [sum_tool, verify_tool]


# ---------------------------------------------------------------------------
# OCI Function handler
# ---------------------------------------------------------------------------

def handler(ctx: fdk.context.InvokeContext, data: io.BytesIO = None):
    body = _parse_body(data)
    if body is None:
        return _error_response(ctx, "Invalid JSON", 400)

    gemini_key = get_secret(os.environ["GEMINI_API_KEY_SECRET_OCID"])
    if not gemini_key:
        return _error_response(ctx, "GEMINI_API_KEY not configured", 500)

    bill_text = body.get("bill_text", "")
    slack_event = body.get("body", {}).get("event", {})
    event_text = slack_event.get("text", "")
    thread_ts = body.get("thread_ts") or slack_event.get("ts", "")

    combined_text = "\n".join(filter(None, [event_text, bill_text]))
    if not combined_text.strip():
        return _error_response(ctx, "No invoice text provided", 400)

    session_key = f"Invoice-{thread_ts}" if thread_ts else "Invoice-unknown"

    # Load prior turns from NoSQL then append the new user message
    chat_history = _load_session(session_key)
    chat_history.append(HumanMessage(content=combined_text))

    llm = ChatGoogleGenerativeAI(
        model="gemini-2.5-flash",
        google_api_key=gemini_key,
        temperature=0.1,
    )

    graph = create_agent(
        model=llm,
        tools=TOOLS,
        system_prompt=SYSTEM_PROMPT,
    )

    result = graph.invoke({"messages": chat_history})

    # The last message in the result is the model's final answer
    output_messages: list[BaseMessage] = result["messages"]
    final_message = output_messages[-1]
    output = final_message.content if isinstance(final_message, AIMessage) else ""

    # Persist back to NoSQL — serialize filters out transient ToolMessages
    _save_session(session_key, output_messages)

    return fdk.response.Response(
        ctx,
        response_data=json.dumps({"output": output, "thread_ts": thread_ts}),
        headers={"Content-Type": "application/json"},
        status_code=200,
    )


# ---------------------------------------------------------------------------
# OCI NoSQL session memory
# ---------------------------------------------------------------------------

def _get_nosql_client() -> oci.nosql.NosqlClient:
    """Return an OCI NoSQL client using Resource Principal auth (inside OCI Functions)."""
    signer = oci.auth.signers.get_resource_principals_signer()
    return oci.nosql.NosqlClient(config={}, signer=signer)


def _load_session(session_key: str) -> list[BaseMessage]:
    """
    Load conversation history from OCI NoSQL and return as LangChain messages.
    Returns an empty list for a new session.
    """
    try:
        client = _get_nosql_client()
        resp = client.get_row(
            table_name_or_id=os.environ["NOSQL_TABLE_NAME"],
            key={"session_key": session_key},
            compartment_id=os.environ["OCI_COMPARTMENT_OCID"],
        )
        row_value = resp.data.value
        if row_value and "messages" in row_value:
            return _deserialize_messages(json.loads(row_value["messages"]))
    except oci.exceptions.ServiceError as exc:
        if exc.status != 404:
            logger.warning("Session load failed for %s: %s", session_key, exc)
    except Exception as exc:
        logger.warning("Session load failed for %s: %s", session_key, exc)
    return []


def _save_session(session_key: str, messages: list[BaseMessage]) -> None:
    """
    Upsert conversation history into OCI NoSQL.
    Only human/AI message pairs are stored — tool messages are transient.
    """
    try:
        client = _get_nosql_client()
        client.update_row(
            table_name_or_id=os.environ["NOSQL_TABLE_NAME"],
            update_row_details=oci.nosql.models.UpdateRowDetails(
                compartment_id=os.environ["OCI_COMPARTMENT_OCID"],
                value={
                    "session_key": session_key,
                    "messages": json.dumps(_serialize_messages(messages)),
                },
            ),
        )
    except Exception as exc:
        logger.error("Session save failed for %s: %s", session_key, exc)


def _serialize_messages(messages: list[BaseMessage]) -> list[dict]:
    """Convert LangChain messages to JSON-serialisable dicts. Skips ToolMessages."""
    out = []
    for msg in messages:
        if isinstance(msg, HumanMessage):
            out.append({"role": "human", "content": msg.content})
        elif isinstance(msg, AIMessage):
            out.append({"role": "ai", "content": msg.content})
    return out


def _deserialize_messages(raw: list[dict]) -> list[BaseMessage]:
    """Rehydrate stored dicts back into LangChain message objects."""
    messages: list[BaseMessage] = []
    for item in raw:
        role = item.get("role", "")
        content = item.get("content", "")
        if role == "human":
            messages.append(HumanMessage(content=content))
        elif role == "ai":
            messages.append(AIMessage(content=content))
    return messages


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _parse_body(data: io.BytesIO) -> dict | None:
    if not data:
        return {}
    try:
        return json.loads(data.getvalue())
    except (json.JSONDecodeError, ValueError) as exc:
        logger.error("Failed to parse request body: %s", exc)
        return None


def _error_response(ctx, message: str, status_code: int) -> fdk.response.Response:
    return fdk.response.Response(
        ctx,
        response_data=json.dumps({"error": message}),
        headers={"Content-Type": "application/json"},
        status_code=status_code,
    )
