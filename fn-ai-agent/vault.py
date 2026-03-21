"""
vault.py — OCI Vault secret helper for OCI Functions.

Usage in func.py:
    from vault import get_secret
    token = get_secret(os.environ["SLACK_BOT_TOKEN_SECRET_OCID"])

The function's dynamic group must have this IAM policy:
    Allow dynamic-group <fn-dynamic-group> to read secret-bundles in compartment <name>
"""

import base64
import logging

import oci

logger = logging.getLogger(__name__)

_cache: dict[str, str] = {}


def get_secret(secret_ocid: str) -> str:
    """
    Fetch a secret value from OCI Vault by its OCID.

    Results are cached in-process for the lifetime of the function container
    so repeated invocations don't incur extra Vault API calls.
    """
    if secret_ocid in _cache:
        return _cache[secret_ocid]

    signer = oci.auth.signers.get_resource_principals_signer()
    client = oci.secrets.SecretsClient(config={}, signer=signer)

    response = client.get_secret_bundle(secret_id=secret_ocid)
    content = response.data.secret_bundle_content

    if content.content_type == "BASE64":
        value = base64.b64decode(content.content).decode("utf-8").strip()
    else:
        value = content.content.strip()

    _cache[secret_ocid] = value
    logger.debug("Fetched secret %s from OCI Vault", secret_ocid)
    return value
