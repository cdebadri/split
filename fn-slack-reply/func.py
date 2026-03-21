"""
fn-slack-reply: OCI Function

Posts the AI agent output back to the originating Slack thread.

Expected input JSON (from OCI Workflow):
  {
    "output":    "<agent answer text>",
    "thread_ts": "<original Slack event ts>"
  }

Returns JSON:
  {"status": "sent"}  on success
"""

import io
import json
import logging
import os

import fdk.context
import fdk.response
from slack_sdk import WebClient
from slack_sdk.errors import SlackApiError
from vault import get_secret

logger = logging.getLogger(__name__)


def handler(ctx: fdk.context.InvokeContext, data: io.BytesIO = None):
    body = _parse_body(data)
    if body is None:
        return _error_response(ctx, "Invalid JSON", 400)

    output_text = body.get("output", "")
    thread_ts = body.get("thread_ts", "")

    if not output_text:
        return _error_response(ctx, "No output text provided", 400)

    slack_token = get_secret(os.environ["SLACK_BOT_TOKEN_SECRET_OCID"])
    channel_id = os.environ.get("SLACK_CHANNEL_ID", "C0ACJ6KPNEM")

    if not slack_token:
        logger.error("SLACK_BOT_TOKEN_SECRET_OCID resolved to empty value")
        return _error_response(ctx, "Slack token not available", 500)

    client = WebClient(token=slack_token)

    try:
        kwargs = {
            "channel": channel_id,
            "text": output_text,
        }
        if thread_ts:
            kwargs["thread_ts"] = thread_ts

        client.chat_postMessage(**kwargs)
        logger.info("Message sent to channel %s thread %s", channel_id, thread_ts)
    except SlackApiError as exc:
        logger.error("Slack API error: %s", exc.response["error"])
        return _error_response(ctx, f"Slack error: {exc.response['error']}", 502)

    return fdk.response.Response(
        ctx,
        response_data=json.dumps({"status": "sent"}),
        headers={"Content-Type": "application/json"},
        status_code=200,
    )


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
