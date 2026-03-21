import hashlib
import hmac
import io
import json
import logging
import os
import time

import fdk.context
import fdk.response
import oci
from vault import get_secret

logger = logging.getLogger(__name__)

# Slack requires the request timestamp to be within 5 minutes
_SLACK_MAX_TIMESTAMP_DELTA_SECS = 300


def handler(ctx: fdk.context.InvokeContext, data: io.BytesIO = None):
    """
    OCI Function entry point.

    Receives Slack Event API POST requests, verifies the request signature
    using the Slack Signing Secret, handles url_verification challenges
    inline, and triggers the appropriate OCI Workflow for image-bearing
    or text-only invoice messages.
    """
    raw_body = data.getvalue() if data else b""

    headers = dict(ctx.Headers().as_dict()) if ctx.Headers() else {}
    # Header names from OCI API Gateway are lowercased
    timestamp = headers.get("x-slack-request-timestamp", "")
    slack_signature = headers.get("x-slack-signature", "")

    signing_secret = get_secret(os.environ["SLACK_SIGNING_SECRET_OCID"])

    if not _verify_slack_signature(signing_secret, timestamp, slack_signature, raw_body):
        logger.warning("Slack signature verification failed")
        return fdk.response.Response(
            ctx,
            response_data=json.dumps({"error": "Unauthorized"}),
            headers={"Content-Type": "application/json"},
            status_code=403,
        )

    try:
        body = json.loads(raw_body) if raw_body else {}
    except (json.JSONDecodeError, ValueError) as exc:
        logger.error("Failed to parse request body: %s", exc)
        return fdk.response.Response(
            ctx,
            response_data=json.dumps({"error": "Invalid JSON"}),
            headers={"Content-Type": "application/json"},
            status_code=400,
        )

    event_type = body.get("type", "")

    # Slack url_verification handshake — must respond synchronously
    if event_type == "url_verification":
        challenge = body.get("challenge", "")
        return fdk.response.Response(
            ctx,
            response_data=json.dumps({"challenge": challenge}),
            headers={"Content-Type": "application/json"},
            status_code=200,
        )

    event = body.get("event", {})
    files = event.get("files", [])
    has_files = isinstance(files, list) and len(files) > 0

    workflow_id = (
        os.environ.get("IMAGE_WORKFLOW_OCID")
        if has_files
        else os.environ.get("TEXT_WORKFLOW_OCID")
    )

    if not workflow_id:
        logger.error("Workflow OCID env var not set for has_files=%s", has_files)
        return fdk.response.Response(
            ctx,
            response_data=json.dumps({"error": "Workflow OCID not configured"}),
            headers={"Content-Type": "application/json"},
            status_code=500,
        )

    _trigger_workflow(workflow_id, body)

    # Respond to Slack immediately to avoid the 3-second timeout
    return fdk.response.Response(
        ctx,
        response_data=json.dumps({"status": "accepted"}),
        headers={"Content-Type": "application/json"},
        status_code=200,
    )


def _verify_slack_signature(
    signing_secret: str,
    timestamp: str,
    slack_signature: str,
    raw_body: bytes,
) -> bool:
    """
    Verify a Slack request signature.

    Slack signs every request as:
        v0={hmac_sha256(signing_secret, "v0:{timestamp}:{raw_body}")}

    Rejects requests whose timestamp is older than 5 minutes to prevent
    replay attacks. Uses hmac.compare_digest for constant-time comparison.
    """
    if not timestamp or not slack_signature:
        return False

    try:
        request_time = int(timestamp)
    except ValueError:
        return False

    if abs(time.time() - request_time) > _SLACK_MAX_TIMESTAMP_DELTA_SECS:
        logger.warning("Slack request timestamp too old: %s", timestamp)
        return False

    sig_basestring = f"v0:{timestamp}:{raw_body.decode('utf-8')}".encode("utf-8")
    expected_sig = (
        "v0="
        + hmac.new(
            signing_secret.encode("utf-8"),
            sig_basestring,
            hashlib.sha256,
        ).hexdigest()
    )

    return hmac.compare_digest(expected_sig, slack_signature)


def _trigger_workflow(workflow_id: str, payload: dict) -> None:
    """Asynchronously trigger an OCI Workflow execution with the Slack payload."""
    try:
        signer = oci.auth.signers.get_resource_principals_signer()
        workflow_client = oci.workflow.WorkflowsClient({}, signer=signer)

        workflow_client.create_workflow_execution(
            oci.workflow.models.CreateWorkflowExecutionDetails(
                workflow_id=workflow_id,
                compartment_id=os.environ.get("OCI_COMPARTMENT_OCID"),
                input=json.dumps(payload),
            )
        )
        logger.info("Triggered workflow %s", workflow_id)
    except Exception as exc:
        logger.error("Failed to trigger workflow %s: %s", workflow_id, exc)
        raise
