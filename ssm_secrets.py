"""
secrets.py — AWS SSM Parameter Store helper for Lambda functions.

Usage:
    from secrets import get_secret
    token = get_secret(os.environ["SLACK_BOT_TOKEN_PARAM"])

Parameters must be SecureString type in SSM Parameter Store.
The Lambda execution role needs ssm:GetParameter on the parameters.
"""

import logging
import os

import boto3

logger = logging.getLogger(__name__)

_cache: dict[str, str] = {}
_ssm = boto3.client("ssm", region_name=os.environ.get("AWS_REGION", "us-east-1"))


def get_secret(param_name: str) -> str:
    """
    Fetch a SecureString parameter from SSM Parameter Store.

    Cached in-process for the lifetime of the Lambda container so warm
    invocations don't incur extra SSM API calls.
    """
    if param_name in _cache:
        return _cache[param_name]

    response = _ssm.get_parameter(Name=param_name, WithDecryption=True)
    value = response["Parameter"]["Value"]
    _cache[param_name] = value
    logger.debug("Fetched SSM parameter: %s", param_name)
    return value
