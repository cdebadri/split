"""
fn-slack-reply: AWS Lambda

Posts the agent's reply back to the originating Slack thread.

Invoked by Step Functions as the final state with:
  {"output": "<agent reply>", "thread_ts": "<event ts>"}

Environment variables:
  SLACK_BOT_TOKEN_PARAM    SSM parameter name for Slack bot token
  SLACK_CHANNEL_ID         Slack channel to post the reply into
"""

import logging
import os

from slack_sdk import WebClient
from slack_sdk.errors import SlackApiError

from ssm_secrets import get_secret

logging.basicConfig(level=logging.INFO, force=True)
logger = logging.getLogger(__name__)


def handler(event, context):
    logger.info("fn-slack-reply invoked, keys: %s", list(event.keys()))

    output = event.get("output", "")
    if isinstance(output, list):
        output = " ".join(
            block.get("text", "") if isinstance(block, dict) else str(block)
            for block in output
        )
    output = str(output).strip()
    thread_ts = event.get("thread_ts", "")
    channel_id = os.environ["SLACK_CHANNEL_ID"]

    if not output:
        logger.error("No output text in event")
        raise ValueError("Missing output")

    token = get_secret(os.environ["SLACK_BOT_TOKEN_PARAM"])
    client = WebClient(token=token)

    try:
        resp = client.chat_postMessage(
            channel=channel_id,
            text=output,
            thread_ts=thread_ts if thread_ts else None,
        )
        logger.info("Message posted, ts=%s", resp["ts"])
    except SlackApiError as exc:
        logger.error("Slack API error: %s", exc.response["error"])
        raise

    return {"status": "sent"}
