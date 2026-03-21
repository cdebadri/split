"""
fn-image-extractor: AWS Lambda

Downloads a Slack private image using the bot token and sends it to
Gemini Vision to extract invoice line items.

Invoked by Step Functions image-flow with the full Slack event body.

Input:
  {"body": {"event": {"files": [...], "ts": "..."}}}

Returns:
  {"bill_text": "<extracted text>", "thread_ts": "<event ts>"}
"""

import logging
import os

import google.generativeai as genai
import requests

from ssm_secrets import get_secret

logging.basicConfig(level=logging.INFO, force=True)
logger = logging.getLogger(__name__)

GEMINI_MODEL = "models/gemini-2.5-flash"
INVOICE_PROMPT = (
    "The image is an invoice or receipt. "
    "Extract every line item with its name, quantity, and unit price. "
    "Return the result as plain structured text listing each item, quantity, and price. "
    "If this is NOT an invoice image, state clearly that it is not an invoice image."
)


def handler(event, context):
    logger.info("fn-image-extractor invoked, keys: %s", list(event.keys()))

    slack_event = event.get("body", {}).get("event", {})
    files = slack_event.get("files") or (
        [slack_event["file"]] if slack_event.get("file") else []
    )

    if not files:
        logger.error("No files in event")
        raise ValueError("No files in event")

    image_url = files[0].get("url_private_download") or files[0].get("url_private")
    mime_type = files[0].get("mimetype", "image/jpeg")
    if not image_url:
        logger.error("Missing image URL in file object")
        raise ValueError("Missing image URL")

    thread_ts = slack_event.get("ts", "")
    logger.info("Downloading image, thread_ts=%s", thread_ts)

    slack_token = get_secret(os.environ["SLACK_BOT_TOKEN_PARAM"])
    gemini_key = get_secret(os.environ["GEMINI_API_KEY_PARAM"])

    image_bytes = _download_image(image_url, slack_token)
    bill_text = _analyze_image(gemini_key, image_bytes, mime_type)

    logger.info("Extracted bill text (%d chars)", len(bill_text))
    logger.info("Bill text:\n%s", bill_text)
    return {"bill_text": bill_text, "thread_ts": thread_ts}


def _download_image(url: str, slack_token: str) -> bytes:
    resp = requests.get(
        url,
        headers={"Authorization": f"Bearer {slack_token}"},
        timeout=15,
    )
    resp.raise_for_status()
    return resp.content


def _analyze_image(api_key: str, image_bytes: bytes, mime_type: str = "image/jpeg") -> str:
    genai.configure(api_key=api_key)
    model = genai.GenerativeModel(GEMINI_MODEL)
    image_part = {"mime_type": mime_type, "data": image_bytes}
    response = model.generate_content([INVOICE_PROMPT, image_part])
    return response.text
