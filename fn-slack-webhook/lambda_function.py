"""
fn-slack-webhook: AWS Lambda

Receives Slack Event API POST requests via Lambda Function URL.
Verifies the Slack request signature, handles url_verification inline,
then starts the appropriate Step Functions Express Workflow asynchronously
so Slack gets a 200 response within its 3-second timeout.

  image event: Step Functions image-flow  (extractor → agent → reply)
  text event:  Step Functions text-flow   (agent → reply)

Environment variables:
  SLACK_SIGNING_SECRET_PARAM   SSM parameter name for Slack signing secret
  IMAGE_FLOW_ARN               Step Functions state machine ARN (image flow)
  TEXT_FLOW_ARN                Step Functions state machine ARN (text flow)
"""

import hashlib
import hmac
import json
import logging
import os
import time

import boto3

from ssm_secrets import get_secret

logging.basicConfig(level=logging.INFO, force=True)
logger = logging.getLogger(__name__)

_SLACK_MAX_TIMESTAMP_DELTA_SECS = 300
_sfn = boto3.client("stepfunctions", region_name=os.environ.get("AWS_REGION", "us-east-1"))


def handler(event, context):
    logger.info("fn-slack-webhook invoked")

    raw_body = event.get("body", "") or ""
    if event.get("isBase64Encoded"):
        import base64
        raw_body = base64.b64decode(raw_body).decode("utf-8")

    raw_bytes = raw_body.encode("utf-8")

    # Parse body first so url_verification never touches SSM
    try:
        body = json.loads(raw_body) if raw_body else {}
    except (json.JSONDecodeError, ValueError) as exc:
        logger.error("Failed to parse body: %s", exc)
        return _response(400, {"error": "Invalid JSON"})

    # Respond to Slack's url_verification challenge immediately
    if body.get("type") == "url_verification":
        logger.info("Handling url_verification challenge")
        return _response(200, {"challenge": body.get("challenge", "")})

    # Verify Slack signature for all other events
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    timestamp = headers.get("x-slack-request-timestamp", "")
    slack_sig = headers.get("x-slack-signature", "")

    signing_secret = get_secret(os.environ["SLACK_SIGNING_SECRET_PARAM"])

    if not _verify_signature(signing_secret, timestamp, slack_sig, raw_bytes):
        logger.warning("Slack signature verification failed")
        return _response(403, {"error": "Unauthorized"})

    slack_event = body.get("event", {})
    files_list = slack_event.get("files") or (
        [slack_event["file"]] if slack_event.get("file") else []
    )
    has_files = isinstance(files_list, list) and len(files_list) > 0

    state_machine_arn = (
        os.environ["IMAGE_FLOW_ARN"] if has_files else os.environ["TEXT_FLOW_ARN"]
    )

    payload = json.dumps({"body": body})
    _sfn.start_execution(stateMachineArn=state_machine_arn, input=payload)
    logger.info("Started Step Functions execution: %s (has_files=%s)", state_machine_arn, has_files)

    return _response(200, {"status": "accepted"})


def _verify_signature(signing_secret: str, timestamp: str, slack_sig: str, raw_bytes: bytes) -> bool:
    if not timestamp or not slack_sig:
        return False
    try:
        if abs(time.time() - int(timestamp)) > _SLACK_MAX_TIMESTAMP_DELTA_SECS:
            logger.warning("Slack timestamp too old: %s", timestamp)
            return False
    except ValueError:
        return False

    basestring = f"v0:{timestamp}:{raw_bytes.decode('utf-8')}".encode("utf-8")
    expected = "v0=" + hmac.new(
        signing_secret.encode("utf-8"), basestring, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, slack_sig)


def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
