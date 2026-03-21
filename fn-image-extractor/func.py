import io
import json
import logging
import os

import fdk.context
import fdk.response
import google.generativeai as genai
import requests
from vault import get_secret

logger = logging.getLogger(__name__)

GEMINI_MODEL = "models/gemini-2.5-flash"

INVOICE_PROMPT = (
    "The image is an invoice or receipt. "
    "Extract every line item with its name, quantity, and unit price. "
    "Return the result as plain structured text listing each item, quantity, and price. "
    "If this is NOT an invoice image, state clearly that it is not an invoice image."
)


def handler(ctx: fdk.context.InvokeContext, data: io.BytesIO = None):
    """
    OCI Function entry point.

    Downloads an image from a Slack private URL and sends it to
    Gemini Vision to extract invoice items, quantities, and prices.

    Expected input JSON:
      {
        "event": {
          "files": [{"url_private_download": "https://..."}],
          "ts": "1234567890.123456"
        }
      }

    Returns JSON:
      {
        "bill_text": "<extracted invoice text>",
        "thread_ts": "<original event ts>"
      }
    """
    body = _parse_body(data)
    if body is None:
        return _error_response(ctx, "Invalid JSON", 400)

    event = body.get("event", {})
    files = event.get("files", [])

    if not files:
        return _error_response(ctx, "No files in event", 400)

    image_url = files[0].get("url_private_download")
    if not image_url:
        return _error_response(ctx, "Missing url_private_download", 400)

    thread_ts = event.get("ts", "")

    slack_token = get_secret(os.environ["SLACK_BOT_TOKEN_SECRET_OCID"])
    gemini_key = get_secret(os.environ["GEMINI_API_KEY_SECRET_OCID"])

    image_bytes = _download_image(image_url, slack_token)
    if image_bytes is None:
        return _error_response(ctx, "Failed to download image from Slack", 502)

    bill_text = _analyze_image(gemini_key, image_bytes)
    if bill_text is None:
        return _error_response(ctx, "Failed to analyze image with Gemini", 502)

    result = {"bill_text": bill_text, "thread_ts": thread_ts}
    return fdk.response.Response(
        ctx,
        response_data=json.dumps(result),
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


def _download_image(url: str, slack_token: str) -> bytes | None:
    """Download a Slack private image using the bot token."""
    try:
        resp = requests.get(
            url,
            headers={"Authorization": f"Bearer {slack_token}"},
            timeout=15,
        )
        resp.raise_for_status()
        return resp.content
    except requests.RequestException as exc:
        logger.error("Image download failed: %s", exc)
        return None


def _analyze_image(api_key: str, image_bytes: bytes) -> str | None:
    """Send image bytes to Gemini Vision and return extracted invoice text."""
    try:
        genai.configure(api_key=api_key)
        model = genai.GenerativeModel(GEMINI_MODEL)

        image_part = {"mime_type": "image/jpeg", "data": image_bytes}
        response = model.generate_content([INVOICE_PROMPT, image_part])
        return response.text
    except Exception as exc:
        logger.error("Gemini image analysis failed: %s", exc)
        return None


def _error_response(ctx, message: str, status_code: int) -> fdk.response.Response:
    return fdk.response.Response(
        ctx,
        response_data=json.dumps({"error": message}),
        headers={"Content-Type": "application/json"},
        status_code=status_code,
    )
