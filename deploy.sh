#!/usr/bin/env bash
# deploy.sh — end-to-end deployment script for the Split OCI Functions project
#
# Prerequisites:
#   - OCI CLI configured (oci setup config)
#   - fn CLI installed and context set to your OCI region
#   - Docker running (fn uses it to build function images)
#   - OCI Vault secrets already created for SLACK_SIGNING_SECRET,
#     SLACK_BOT_TOKEN, and GEMINI_API_KEY
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh
set -euo pipefail

# ── Configuration — fill these in before running ──────────────────────────────

APP_NAME="split-app"
COMPARTMENT_OCID="ocid1.tenancy.oc1..aaaaaaaaclytdno62zpicek3m2f2a5gn2u4rb6y2cawdfizph4amblai2uaa"

# OCI Vault secret OCIDs (not the secret values themselves)
SLACK_SIGNING_SECRET_VAULT_OCID="ocid1.vaultsecret.oc1.ap-mumbai-1.amaaaaaapqmtbbaasu5jollh2lmf6zof7r5je43iwzcbyx76hwochhvrxpkq"
SLACK_BOT_TOKEN_VAULT_OCID="ocid1.vaultsecret.oc1.ap-mumbai-1.amaaaaaapqmtbbaamu43cffnw6yfpf3ybpqu2faishwfm3g3q5pcr56zlwza"
GEMINI_API_KEY_VAULT_OCID="ocid1.vaultsecret.oc1.ap-mumbai-1.amaaaaaapqmtbbaa5xwt34xshldz3vsv3ivu633abaxmpjzbegjocr43q2jq"

SLACK_CHANNEL_ID="C0ACJ6KPNEM"

# ── Validate prerequisites ─────────────────────────────────────────────────────

for var in APP_NAME COMPARTMENT_OCID SLACK_SIGNING_SECRET_VAULT_OCID \
           SLACK_BOT_TOKEN_VAULT_OCID GEMINI_API_KEY_VAULT_OCID; do
  if [[ "${!var}" == *"<replace>"* ]]; then
    echo "ERROR: $var is not set. Edit the Configuration section in deploy.sh first."
    exit 1
  fi
done

for cmd in oci fn docker; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is not installed or not on PATH."
    exit 1
  fi
done

# ── Step 1: Deploy all four functions ──────────────────────────────────────────

echo "==> [1/5] Deploying functions to app: $APP_NAME"

for fn_dir in fn-slack-webhook fn-image-extractor fn-ai-agent fn-slack-reply; do
  echo "    Deploying $fn_dir..."
  (cd "$fn_dir" && fn deploy --app "$APP_NAME" --no-bump)
done

# ── Step 2: Resolve function OCIDs ────────────────────────────────────────────

echo "==> [2/5] Resolving function OCIDs"

APP_OCID=$(oci fn application list \
  --compartment-id "$COMPARTMENT_OCID" \
  --display-name "$APP_NAME" \
  --query 'data[0].id' \
  --raw-output)

if [[ -z "$APP_OCID" || "$APP_OCID" == "null" ]]; then
  echo "ERROR: Application '$APP_NAME' not found in compartment."
  exit 1
fi

get_fn_ocid() {
  oci fn function list \
    --application-id "$APP_OCID" \
    --display-name "$1" \
    --query 'data[0].id' \
    --raw-output
}

FN_WEBHOOK_OCID=$(get_fn_ocid "fn-slack-webhook")
FN_EXTRACTOR_OCID=$(get_fn_ocid "fn-image-extractor")
FN_AGENT_OCID=$(get_fn_ocid "fn-ai-agent")
FN_REPLY_OCID=$(get_fn_ocid "fn-slack-reply")

echo "    fn-slack-webhook:   $FN_WEBHOOK_OCID"
echo "    fn-image-extractor: $FN_EXTRACTOR_OCID"
echo "    fn-ai-agent:        $FN_AGENT_OCID"
echo "    fn-slack-reply:     $FN_REPLY_OCID"

# ── Step 3: Create OCI NoSQL table ────────────────────────────────────────────

echo "==> [3/5] Creating OCI NoSQL table: split_sessions"

# Strip comment lines before passing DDL to the CLI
DDL=$(grep -v '^\s*--' db/schema.sql | tr -d '\n' | xargs)

TABLE_EXISTS=$(oci nosql table list \
  --compartment-id "$COMPARTMENT_OCID" \
  --name "split_sessions" \
  --query 'length(data)' \
  --raw-output 2>/dev/null || echo "0")

if [[ "$TABLE_EXISTS" == "0" ]]; then
  oci nosql table create \
    --compartment-id "$COMPARTMENT_OCID" \
    --name "split_sessions" \
    --ddl-statement "$DDL" \
    --table-limits '{"maxReadUnits":25,"maxWriteUnits":25,"maxStorageInGBs":25}' \
    --is-auto-reclaimable true \
    --wait-for-state ACTIVE
  echo "    Table created."
else
  echo "    Table already exists, skipping."
fi

# ── Step 4: Create OCI Workflows ──────────────────────────────────────────────

echo "==> [4/5] Creating OCI Workflows"

render_workflow() {
  sed \
    -e "s|<replace-with-fn-image-extractor-ocid>|$FN_EXTRACTOR_OCID|g" \
    -e "s|<replace-with-fn-ai-agent-ocid>|$FN_AGENT_OCID|g" \
    -e "s|<replace-with-fn-slack-reply-ocid>|$FN_REPLY_OCID|g" \
    "$1"
}

render_workflow workflows/image-flow.yaml > /tmp/split-image-flow.yaml
render_workflow workflows/text-flow.yaml  > /tmp/split-text-flow.yaml

IMAGE_FLOW_OCID=$(oci workflow workflow create \
  --compartment-id "$COMPARTMENT_OCID" \
  --from-file /tmp/split-image-flow.yaml \
  --query 'data.id' \
  --raw-output)

TEXT_FLOW_OCID=$(oci workflow workflow create \
  --compartment-id "$COMPARTMENT_OCID" \
  --from-file /tmp/split-text-flow.yaml \
  --query 'data.id' \
  --raw-output)

echo "    image-flow: $IMAGE_FLOW_OCID"
echo "    text-flow:  $TEXT_FLOW_OCID"

# ── Step 5: Set function configs ──────────────────────────────────────────────

echo "==> [5/5] Configuring functions"

oci fn function update \
  --function-id "$FN_WEBHOOK_OCID" \
  --config "{
    \"SLACK_SIGNING_SECRET_OCID\": \"$SLACK_SIGNING_SECRET_VAULT_OCID\",
    \"IMAGE_WORKFLOW_OCID\":        \"$IMAGE_FLOW_OCID\",
    \"TEXT_WORKFLOW_OCID\":         \"$TEXT_FLOW_OCID\",
    \"OCI_COMPARTMENT_OCID\":       \"$COMPARTMENT_OCID\"
  }"

oci fn function update \
  --function-id "$FN_EXTRACTOR_OCID" \
  --config "{
    \"SLACK_BOT_TOKEN_SECRET_OCID\": \"$SLACK_BOT_TOKEN_VAULT_OCID\",
    \"GEMINI_API_KEY_SECRET_OCID\":   \"$GEMINI_API_KEY_VAULT_OCID\"
  }"

oci fn function update \
  --function-id "$FN_AGENT_OCID" \
  --config "{
    \"GEMINI_API_KEY_SECRET_OCID\": \"$GEMINI_API_KEY_VAULT_OCID\",
    \"NOSQL_TABLE_NAME\":            \"split_sessions\",
    \"OCI_COMPARTMENT_OCID\":        \"$COMPARTMENT_OCID\"
  }"

oci fn function update \
  --function-id "$FN_REPLY_OCID" \
  --config "{
    \"SLACK_BOT_TOKEN_SECRET_OCID\": \"$SLACK_BOT_TOKEN_VAULT_OCID\",
    \"SLACK_CHANNEL_ID\":             \"$SLACK_CHANNEL_ID\"
  }"

echo ""
echo "✓ Deployment complete."
echo ""
echo "Next steps:"
echo "  1. Create an API Gateway deployment with:"
echo "     POST /slack/events  →  fn-slack-webhook ($FN_WEBHOOK_OCID)"
echo "  2. Register the API Gateway URL in your Slack app:"
echo "     Slack app → Event Subscriptions → Request URL"
