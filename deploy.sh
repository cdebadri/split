#!/usr/bin/env bash
# deploy.sh — Deploy all Lambda functions and Step Functions state machines.
#
# Prerequisites:
#   - AWS CLI v2 configured (aws configure, or IAM role on EC2/Cloud9)
#   - Python 3.11+ and pip available for packaging
#
# What this script does:
#   1. Creates the DynamoDB table for session memory (idempotent)
#   2. Creates SSM Parameter Store secrets (prompts for values on first run)
#   3. Builds and uploads Lambda ZIP packages
#   4. Creates or updates the four Lambda functions with env vars / timeouts
#   5. Creates or updates the Step Functions Express Workflow state machines
#   6. Creates a Lambda Function URL for fn-slack-webhook (the public Slack endpoint)
#
# Usage:
#   ./deploy.sh

set -euo pipefail

# Source .env if present (keeps credentials and config out of shell history)
REPO_ROOT_EARLY="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$REPO_ROOT_EARLY/.env" ]]; then
  set -o allexport
  # shellcheck source=.env
  source "$REPO_ROOT_EARLY/.env"
  set +o allexport
fi

# Map .env credential names → AWS CLI env vars
export AWS_ACCESS_KEY_ID="${ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
export AWS_SECRET_ACCESS_KEY="${SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"

# ─── CONFIGURATION ────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-ap-south-1}"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# IAM role that Lambda functions will assume.
# Create this role once in the console or with the helper at the bottom of this
# script, then paste its ARN here.
LAMBDA_ROLE_ARN="${LAMBDA_ROLE_ARN:-}"   # e.g. arn:aws:iam::123456789012:role/split-lambda-role

# Slack channel ID where the bot posts replies (e.g. C0123456789)
SLACK_CHANNEL_ID="${SLACK_CHANNEL_ID:-}"

# SSM parameter names (the script will create these on first run if absent)
PARAM_SLACK_SIGNING_SECRET="/split/slack-signing-secret"
PARAM_SLACK_BOT_TOKEN="/split/slack-bot-token"
PARAM_GEMINI_API_KEY="/split/gemini-api-key"

# DynamoDB
DYNAMODB_TABLE="split-sessions"

# S3 bucket for Lambda deployment ZIPs (avoids the 50 MB direct-upload limit)
S3_DEPLOY_BUCKET="split-lambda-deploy-${AWS_ACCOUNT_ID}-${AWS_REGION}"

# Step Functions
IMAGE_FLOW_NAME="split-image-flow"
TEXT_FLOW_NAME="split-text-flow"

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
# ──────────────────────────────────────────────────────────────────────────────

_check_prereqs() {
  for cmd in aws python3 pip zip jq; do
    command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found on PATH" >&2; exit 1; }
  done
  if [[ -z "$LAMBDA_ROLE_ARN" ]]; then
    echo "ERROR: Set LAMBDA_ROLE_ARN before running." >&2
    echo "  See 'Create IAM role' section at the bottom of deploy.sh." >&2
    exit 1
  fi
  if [[ -z "$SLACK_CHANNEL_ID" ]]; then
    echo "ERROR: Set SLACK_CHANNEL_ID before running." >&2
    exit 1
  fi
}

# ─── 1. DYNAMODB TABLE ───────────────────────────────────────────────────────
_create_dynamodb() {
  echo ""
  echo "==> DynamoDB: $DYNAMODB_TABLE"
  if aws dynamodb describe-table --table-name "$DYNAMODB_TABLE" --region "$AWS_REGION" &>/dev/null; then
    echo "    Table already exists, skipping."
  else
    aws dynamodb create-table \
      --table-name "$DYNAMODB_TABLE" \
      --attribute-definitions AttributeName=session_key,AttributeType=S \
      --key-schema AttributeName=session_key,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --region "$AWS_REGION"
    # Enable TTL
    aws dynamodb update-time-to-live \
      --table-name "$DYNAMODB_TABLE" \
      --time-to-live-specification "Enabled=true,AttributeName=ttl" \
      --region "$AWS_REGION"
    echo "    Created."
  fi
}

# ─── 2. SSM SECRETS ─────────────────────────────────────────────────────────
_upsert_param() {
  local name="$1" desc="$2" env_value="${3:-}"
  if aws ssm get-parameter --name "$name" --region "$AWS_REGION" &>/dev/null; then
    echo "    $name already exists, skipping."
    return
  fi
  local secret_val="$env_value"
  if [[ -z "$secret_val" ]]; then
    read -rsp "    Enter value for $desc: " secret_val
    echo ""
  fi
  aws ssm put-parameter \
    --name "$name" \
    --value "$secret_val" \
    --type SecureString \
    --description "$desc" \
    --region "$AWS_REGION"
  echo "    Stored."
}

_create_ssm_params() {
  echo ""
  echo "==> SSM Parameter Store secrets"
  _upsert_param "$PARAM_SLACK_SIGNING_SECRET" "Slack Signing Secret"      "${SLACK_SIGNING_SECRET:-}"
  _upsert_param "$PARAM_SLACK_BOT_TOKEN"      "Slack Bot Token (xoxb-...)" "${SLACK_BOT_TOKEN:-}"
  _upsert_param "$PARAM_GEMINI_API_KEY"       "Gemini API Key"             "${GEMINI_API_KEY:-}"
}

# ─── 3. PACKAGE + UPLOAD TO S3 ───────────────────────────────────────────────
_package() {
  echo ""
  echo "==> Packaging Lambda ZIPs"
  bash "$REPO_ROOT/package.sh"

  echo ""
  echo "==> S3 deploy bucket: $S3_DEPLOY_BUCKET"
  if aws s3api head-bucket --bucket "$S3_DEPLOY_BUCKET" --region "$AWS_REGION" &>/dev/null; then
    echo "    Bucket already exists."
  else
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$S3_DEPLOY_BUCKET" --region "$AWS_REGION"
    else
      aws s3api create-bucket --bucket "$S3_DEPLOY_BUCKET" --region "$AWS_REGION" \
        --create-bucket-configuration LocationConstraint="$AWS_REGION"
    fi
    # Block all public access
    aws s3api put-public-access-block --bucket "$S3_DEPLOY_BUCKET" \
      --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    echo "    Created."
  fi

  echo "    Uploading ZIPs..."
  for fn in fn-slack-webhook fn-image-extractor fn-ai-agent fn-slack-reply; do
    local attempt=0
    until aws s3 cp "$REPO_ROOT/dist/${fn}.zip" "s3://${S3_DEPLOY_BUCKET}/zips/${fn}.zip" \
            --region "$AWS_REGION" --no-progress; do
      attempt=$((attempt + 1))
      if [[ $attempt -ge 3 ]]; then
        echo "ERROR: Failed to upload ${fn}.zip after 3 attempts" >&2
        exit 1
      fi
      echo "    Upload failed, retrying ($attempt/3)..."
      sleep 5
    done
    echo "    -> s3://${S3_DEPLOY_BUCKET}/zips/${fn}.zip"
  done
}

# ─── 4. LAMBDA FUNCTIONS ─────────────────────────────────────────────────────
_get_or_create_function() {
  local fn_name="$1" handler="$2" timeout="$3" memory="$4"
  shift 4
  local env_vars=("$@")

  local s3_key="zips/${fn_name}.zip"
  local env_json
  env_json=$(printf '{"Variables":{%s}}' "$(IFS=,; echo "${env_vars[*]}")")

  if aws lambda get-function --function-name "$fn_name" --region "$AWS_REGION" &>/dev/null; then
    echo "    Updating code: $fn_name" >&2
    aws lambda update-function-code \
      --function-name "$fn_name" \
      --s3-bucket "$S3_DEPLOY_BUCKET" \
      --s3-key "$s3_key" \
      --region "$AWS_REGION" \
      --output text --query 'FunctionArn' >/dev/null
    aws lambda wait function-updated --function-name "$fn_name" --region "$AWS_REGION"
    aws lambda update-function-configuration \
      --function-name "$fn_name" \
      --handler "$handler" \
      --timeout "$timeout" \
      --memory-size "$memory" \
      --environment "$env_json" \
      --region "$AWS_REGION" \
      --output text --query 'FunctionArn' >/dev/null
    echo "    Updated: $fn_name" >&2
  else
    echo "    Creating: $fn_name" >&2
    aws lambda create-function \
      --function-name "$fn_name" \
      --runtime python3.12 \
      --role "$LAMBDA_ROLE_ARN" \
      --handler "$handler" \
      --code "S3Bucket=${S3_DEPLOY_BUCKET},S3Key=${s3_key}" \
      --timeout "$timeout" \
      --memory-size "$memory" \
      --environment "$env_json" \
      --region "$AWS_REGION" \
      --output text --query 'FunctionArn' >/dev/null
    aws lambda wait function-active --function-name "$fn_name" --region "$AWS_REGION"
    echo "    Created: $fn_name" >&2
  fi
}

_get_function_arn() {
  aws lambda get-function --function-name "$1" --region "$AWS_REGION" \
    --query 'Configuration.FunctionArn' --output text
}

_deploy_functions() {
  echo ""
  echo "==> Lambda functions"

  _get_or_create_function "fn-slack-webhook" "lambda_function.handler" 600 128 \
    "\"SLACK_SIGNING_SECRET_PARAM\":\"$PARAM_SLACK_SIGNING_SECRET\""
  # IMAGE_FLOW_ARN and TEXT_FLOW_ARN are set after state machines are created

  _get_or_create_function "fn-image-extractor" "lambda_function.handler" 600 512 \
    "\"SLACK_BOT_TOKEN_PARAM\":\"$PARAM_SLACK_BOT_TOKEN\"" \
    "\"GEMINI_API_KEY_PARAM\":\"$PARAM_GEMINI_API_KEY\""

  _get_or_create_function "fn-ai-agent" "lambda_function.handler" 600 512 \
    "\"GEMINI_API_KEY_PARAM\":\"$PARAM_GEMINI_API_KEY\"" \
    "\"DYNAMODB_TABLE_NAME\":\"$DYNAMODB_TABLE\""

  _get_or_create_function "fn-slack-reply" "lambda_function.handler" 600 128 \
    "\"SLACK_BOT_TOKEN_PARAM\":\"$PARAM_SLACK_BOT_TOKEN\"" \
    "\"SLACK_CHANNEL_ID\":\"$SLACK_CHANNEL_ID\""

  echo ""
  echo "==> CloudWatch log groups"
  for lg in \
    "/aws/lambda/fn-slack-webhook" \
    "/aws/lambda/fn-image-extractor" \
    "/aws/lambda/fn-ai-agent" \
    "/aws/lambda/fn-slack-reply" \
    "/aws/states/split-image-flow" \
    "/aws/states/split-text-flow"; do
    if aws logs describe-log-groups --log-group-name-prefix "$lg" \
         --region "$AWS_REGION" --query 'logGroups[0].logGroupName' \
         --output text 2>/dev/null | grep -q "$lg"; then
      echo "    $lg already exists."
    else
      aws logs create-log-group --log-group-name "$lg" --region "$AWS_REGION"
      aws logs put-retention-policy --log-group-name "$lg" \
        --retention-in-days 30 --region "$AWS_REGION"
      echo "    Created $lg"
    fi
  done
}

# ─── 5. STEP FUNCTIONS ───────────────────────────────────────────────────────

# Create or look up the IAM role for Step Functions to invoke Lambda.
_get_or_create_sfn_role() {
  local role_name="split-sfn-role"
  if aws iam get-role --role-name "$role_name" &>/dev/null; then
    aws iam get-role --role-name "$role_name" --query 'Role.Arn' --output text
    return
  fi
  local trust
  trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"states.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  aws iam create-role --role-name "$role_name" --assume-role-policy-document "$trust" \
    --output text --query 'Role.Arn' > /dev/null
  aws iam attach-role-policy --role-name "$role_name" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaRole
  # Allow Step Functions to write execution logs to CloudWatch
  aws iam put-role-policy --role-name "$role_name" \
    --policy-name split-sfn-logs \
    --policy-document '{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Action":[
          "logs:CreateLogDelivery","logs:GetLogDelivery","logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery","logs:ListLogDeliveries",
          "logs:PutResourcePolicy","logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups"
        ],
        "Resource":"*"
      }]
    }'
  sleep 5  # brief propagation delay
  aws iam get-role --role-name "$role_name" --query 'Role.Arn' --output text
}

_deploy_state_machine() {
  local name="$1" asl_template="$2"
  local sfn_role_arn="$3"

  local extractor_arn; extractor_arn="$(_get_function_arn fn-image-extractor)"
  local agent_arn;     agent_arn="$(_get_function_arn fn-ai-agent)"
  local reply_arn;     reply_arn="$(_get_function_arn fn-slack-reply)"

  local definition
  definition=$(sed \
    -e "s|FN_IMAGE_EXTRACTOR_ARN|$extractor_arn|g" \
    -e "s|FN_AI_AGENT_ARN|$agent_arn|g" \
    -e "s|FN_SLACK_REPLY_ARN|$reply_arn|g" \
    "$asl_template")

  local log_group_arn="arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/states/${name}:*"
  local logging_config
  logging_config="{\"level\":\"ERROR\",\"includeExecutionData\":true,\"destinations\":[{\"cloudWatchLogsLogGroup\":{\"logGroupArn\":\"${log_group_arn}\"}}]}"

  if aws stepfunctions describe-state-machine \
       --state-machine-arn "arn:aws:states:${AWS_REGION}:${AWS_ACCOUNT_ID}:stateMachine:${name}" \
       --region "$AWS_REGION" &>/dev/null; then
    echo "    Updating state machine: $name" >&2
    local sm_arn="arn:aws:states:${AWS_REGION}:${AWS_ACCOUNT_ID}:stateMachine:${name}"
    aws stepfunctions update-state-machine \
      --state-machine-arn "$sm_arn" \
      --definition "$definition" \
      --role-arn "$sfn_role_arn" \
      --logging-configuration "$logging_config" \
      --region "$AWS_REGION" \
      --output text --query 'stateMachineArn' >/dev/null
    echo "$sm_arn"
  else
    echo "    Creating state machine: $name" >&2
    aws stepfunctions create-state-machine \
      --name "$name" \
      --definition "$definition" \
      --role-arn "$sfn_role_arn" \
      --type EXPRESS \
      --logging-configuration "$logging_config" \
      --region "$AWS_REGION" \
      --output text --query 'stateMachineArn'
  fi
}

_deploy_state_machines() {
  echo ""
  echo "==> Step Functions state machines"
  local sfn_role_arn
  sfn_role_arn="$(_get_or_create_sfn_role)"

  local image_flow_arn
  image_flow_arn="$(_deploy_state_machine "$IMAGE_FLOW_NAME" \
    "$REPO_ROOT/step-functions/image-flow.asl.json" "$sfn_role_arn")"

  local text_flow_arn
  text_flow_arn="$(_deploy_state_machine "$TEXT_FLOW_NAME" \
    "$REPO_ROOT/step-functions/text-flow.asl.json" "$sfn_role_arn")"

  # Now patch fn-slack-webhook with the state machine ARNs
  echo "    Updating fn-slack-webhook with state machine ARNs"
  aws lambda update-function-configuration \
    --function-name fn-slack-webhook \
    --environment "{\"Variables\":{
      \"SLACK_SIGNING_SECRET_PARAM\":\"$PARAM_SLACK_SIGNING_SECRET\",
      \"IMAGE_FLOW_ARN\":\"$image_flow_arn\",
      \"TEXT_FLOW_ARN\":\"$text_flow_arn\"
    }}" \
    --region "$AWS_REGION" \
    --output text --query 'FunctionArn'
}

# ─── 6. API GATEWAY HTTP API ─────────────────────────────────────────────────
_create_api_gateway() {
  echo ""
  echo "==> API Gateway HTTP API for fn-slack-webhook"

  local fn_arn
  fn_arn="$(_get_function_arn fn-slack-webhook)"

  # Check if API already exists
  local api_id
  api_id="$(aws apigatewayv2 get-apis --region "$AWS_REGION" \
    --query "Items[?Name=='split-slack-api'].ApiId" --output text)"

  if [[ -z "$api_id" || "$api_id" == "None" ]]; then
    echo "    Creating API..."
    api_id="$(aws apigatewayv2 create-api \
      --name split-slack-api \
      --protocol-type HTTP \
      --region "$AWS_REGION" \
      --query 'ApiId' --output text)"
    echo "    API ID: $api_id"
  else
    echo "    API already exists: $api_id"
  fi

  # Grant API Gateway permission to invoke the Lambda
  aws lambda add-permission \
    --function-name fn-slack-webhook \
    --statement-id AllowApiGatewayInvoke \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${AWS_REGION}:${AWS_ACCOUNT_ID}:${api_id}/*/*" \
    --region "$AWS_REGION" \
    --output text --query 'Statement' >/dev/null 2>&1 || true

  # Create or reuse the Lambda integration
  local integration_id
  integration_id="$(aws apigatewayv2 get-integrations \
    --api-id "$api_id" --region "$AWS_REGION" \
    --query 'Items[0].IntegrationId' --output text 2>/dev/null)"

  if [[ -z "$integration_id" || "$integration_id" == "None" ]]; then
    echo "    Creating integration..."
    integration_id="$(aws apigatewayv2 create-integration \
      --api-id "$api_id" \
      --integration-type AWS_PROXY \
      --integration-uri "arn:aws:apigateway:${AWS_REGION}:lambda:path/2015-03-31/functions/${fn_arn}/invocations" \
      --payload-format-version 2.0 \
      --region "$AWS_REGION" \
      --query 'IntegrationId' --output text)"
  fi

  # Create POST / route if it doesn't exist
  local route_exists
  route_exists="$(aws apigatewayv2 get-routes \
    --api-id "$api_id" --region "$AWS_REGION" \
    --query "Items[?RouteKey=='POST /'].RouteId" --output text 2>/dev/null)"

  if [[ -z "$route_exists" || "$route_exists" == "None" ]]; then
    echo "    Creating POST / route..."
    aws apigatewayv2 create-route \
      --api-id "$api_id" \
      --route-key "POST /" \
      --target "integrations/${integration_id}" \
      --region "$AWS_REGION" \
      --output text --query 'RouteId' >/dev/null
  fi

  # Create or update $default stage with auto-deploy
  if aws apigatewayv2 get-stage \
       --api-id "$api_id" --stage-name '$default' \
       --region "$AWS_REGION" &>/dev/null; then
    echo "    Stage already exists."
  else
    aws apigatewayv2 create-stage \
      --api-id "$api_id" \
      --stage-name '$default' \
      --auto-deploy \
      --region "$AWS_REGION" \
      --output text --query 'StageName' >/dev/null
  fi

  local invoke_url="https://${api_id}.execute-api.${AWS_REGION}.amazonaws.com/"
  echo ""
  echo "    Invoke URL: $invoke_url"
  echo ""
  echo "  *** Set this URL as the Slack Event Subscriptions Request URL ***"
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────
echo "=== Split — AWS Lambda Deploy ==="
echo "    Region:  $AWS_REGION"
echo "    Account: $AWS_ACCOUNT_ID"

_check_prereqs
_create_dynamodb
_create_ssm_params
_package
_deploy_functions
_deploy_state_machines
_create_api_gateway

echo ""
echo "=== Deploy complete ==="

# ─── CREATE IAM ROLE (run once manually if LAMBDA_ROLE_ARN is not set) ───────
# Uncomment and run:
#
# aws iam create-role \
#   --role-name split-lambda-role \
#   --assume-role-policy-document '{
#     "Version":"2012-10-17",
#     "Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
#   }'

# aws iam attach-role-policy --role-name split-lambda-role \
#   --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# aws iam put-role-policy --role-name split-lambda-role \
#   --policy-name split-lambda-inline \
#   --policy-document '{
#     "Version":"2012-10-17",
#     "Statement":[
#       {"Effect":"Allow","Action":["ssm:GetParameter"],"Resource":"arn:aws:ssm:*:*:parameter/split/*"},
#       {"Effect":"Allow","Action":["dynamodb:GetItem","dynamodb:PutItem"],"Resource":"arn:aws:dynamodb:*:*:table/split-sessions"},
#       {"Effect":"Allow","Action":"states:StartExecution","Resource":"arn:aws:states:*:*:stateMachine:split-*"}
#     ]
#   }'

# export LAMBDA_ROLE_ARN=$(aws iam get-role --role-name split-lambda-role --query 'Role.Arn' --output text)
