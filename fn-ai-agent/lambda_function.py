"""
fn-ai-agent: AWS Lambda

Bill-splitting agent using langchain.agents.create_agent (LangChain 1.x) with
Google Gemini. Replicates the original n8n workflow: Sum Tool and Verify Tool
with the exact system prompt from Split.json.

Session history is persisted in DynamoDB for multi-turn Slack threads.

Invoked by Step Functions with:
  {
    "body": {"event": {"text": "<user message>", "ts": "..."}},
    "bill_text": "<extracted text>",  # image-flow only
    "thread_ts": "<event ts>"
  }

Returns:
  {"output": "<agent reply>", "thread_ts": "<event ts>"}

Environment variables:
  GEMINI_API_KEY_PARAM    SSM parameter name for Gemini API key
  DYNAMODB_TABLE_NAME     DynamoDB table for session memory
"""

import json
import logging
import os
import time
from typing import List

import boto3
from langchain.agents import create_agent
from langchain_core.messages import AIMessage, HumanMessage
from langchain_core.tools import tool
from langchain_google_genai import ChatGoogleGenerativeAI
from pydantic import BaseModel

from ssm_secrets import get_secret

logging.basicConfig(level=logging.INFO, force=True)
logger = logging.getLogger(__name__)

GEMINI_MODEL = "gemini-2.5-flash"
SESSION_TTL_DAYS = 30

SYSTEM_PROMPT = """\
## CONTEXT
You are an expert in calculating individual shares from a total amount based on individual expenditure. \
You would be given a total amount of the bill and the prices of individual items and also the quantity. \
You are also given what portion each person shared. \
You are required to calculate the total individual share of each person out of the total.

## TOOLS
You are given tools to calculate shares
Sum_Tool - To find the sum of amounts
Verify_Tool - To check whether the sum of all individual shares equals the total amount.

## INSTRUCTIONS
- Call the `Sum_Tool` to calculate individual shares.
- Use the `Verify_Tool` to verify if all shares are adding upto the total.

## IMPORTANT
- Always use the tools for calculations
- If the `Verify_Tool` returns non zero value redo the calculation
- If the `Verify_Tool` returns zero value then return the individual shares of people.
- Pass only the required values to tools as mentioned by input schemas.
- Only output the shares of each food item and total for every individual."""

_dynamodb = boto3.resource("dynamodb", region_name=os.environ.get("AWS_REGION", "us-east-1"))


# ─── TOOLS (exact logic from Split.json) ─────────────────────────────────────

class SumItem(BaseModel):
    price: float
    quantity: float


class SumInput(BaseModel):
    amounts: List[SumItem]


class VerifyInput(BaseModel):
    total: float
    shares: List[float]


@tool("Sum_Tool", args_schema=SumInput)
def sum_tool(amounts: List[SumItem]) -> float:
    """
    Call this tool with an array of amounts to find the total amount.
    Args:
      amounts: array of objects with price and quantity to be multiplied and summed.
    Returns: total sum as a number.
    """
    return round(sum(item.price * item.quantity for item in amounts), 2)


@tool("Verify_Tool", args_schema=VerifyInput)
def verify_tool(total: float, shares: List[float]) -> float:
    """
    Call this tool to verify if the sum of share amounts equals the total.
    Returns the difference (shares_sum - total). Should be 0 if correct.
    If not zero there is a problem and the calculation must be redone.
    """
    return round(sum(shares) - total, 2)


TOOLS = [sum_tool, verify_tool]


# ─── HANDLER ──────────────────────────────────────────────────────────────────

def handler(event, context):
    logger.info("fn-ai-agent invoked, keys: %s", list(event.keys()))

    slack_event = event.get("body", {}).get("event", {})
    user_text = slack_event.get("text", "").strip()
    thread_ts = event.get("thread_ts") or slack_event.get("ts", "")
    channel_id = slack_event.get("channel", "")
    bill_text = event.get("bill_text", "")

    logger.info("channel=%s thread_ts=%s bill_text_len=%d", channel_id, thread_ts, len(bill_text))

    if not user_text and not bill_text:
        logger.error("No user text or bill_text in event")
        raise ValueError("No content to process")

    gemini_key = get_secret(os.environ["GEMINI_API_KEY_PARAM"])

    table_name = os.environ["DYNAMODB_TABLE_NAME"]
    session_key = f"{channel_id}:{thread_ts}"
    logger.info("Session key: %s", session_key)

    chat_history = _load_session(table_name, session_key)
    logger.info("Loaded %d messages from session", len(chat_history))

    user_content = (
        f"Here is the bill:\n\n{bill_text}\n\n{user_text}" if bill_text and user_text
        else bill_text or user_text
    )

    llm = ChatGoogleGenerativeAI(
        model=GEMINI_MODEL,
        google_api_key=gemini_key,
        temperature=0.1,
    )
    agent = create_agent(model=llm, tools=TOOLS, system_prompt=SYSTEM_PROMPT)
    logger.info("Running agent")

    result = agent.invoke({"messages": chat_history + [HumanMessage(content=user_content)]})
    ai_messages = [m for m in result["messages"] if isinstance(m, AIMessage)]
    raw_output = ai_messages[-1].content if ai_messages else "I could not generate a response."
    output = _coerce_to_str(raw_output)

    logger.info("Agent output (%d chars): %s...", len(output), output[:120])

    chat_history.append(HumanMessage(content=user_content))
    chat_history.append(AIMessage(content=output))
    _save_session(table_name, session_key, chat_history)

    return {"output": output, "thread_ts": thread_ts}


def _coerce_to_str(content) -> str:
    """Normalize AIMessage.content to a plain string.

    LangChain with Gemini can return content as:
      - str                          → use directly
      - list of {"type":"text",...}  → join the text parts
    """
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                parts.append(block.get("text", ""))
            elif isinstance(block, str):
                parts.append(block)
        return "".join(parts)
    return str(content)


# ─── SESSION ──────────────────────────────────────────────────────────────────

def _load_session(table_name: str, session_key: str) -> list:
    table = _dynamodb.Table(table_name)
    response = table.get_item(Key={"session_key": session_key})
    item = response.get("Item")
    if not item or "messages" not in item:
        return []
    raw = json.loads(item["messages"])
    messages = []
    for m in raw:
        if m["role"] == "human":
            messages.append(HumanMessage(content=m["content"]))
        elif m["role"] == "ai":
            messages.append(AIMessage(content=m["content"]))
    return messages


def _save_session(table_name: str, session_key: str, messages: list) -> None:
    table = _dynamodb.Table(table_name)
    serialized = []
    for m in messages:
        if isinstance(m, HumanMessage):
            serialized.append({"role": "human", "content": m.content})
        elif isinstance(m, AIMessage):
            serialized.append({"role": "ai", "content": m.content})
    table.put_item(Item={
        "session_key": session_key,
        "messages": json.dumps(serialized),
        "ttl": int(time.time()) + SESSION_TTL_DAYS * 86400,
    })
    logger.info("Saved %d messages to session %s", len(serialized), session_key)
