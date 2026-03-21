#!/usr/bin/env bash
# deploy-objstore.sh — deploys Split OCI Functions via Object Storage (no Docker required)
#
# Prerequisites:
#   - OCI CLI configured (oci setup config)
#   - OCI Vault secrets already created for SLACK_SIGNING_SECRET,
#     SLACK_BOT_TOKEN, and GEMINI_API_KEY
#
# Usage:
#   chmod +x deploy-objstore.sh
#   ./deploy-objstore.sh
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

APP_NAME="split-app"
COMPARTMENT_OCID="ocid1.tenancy.oc1..aaaaaaaaclytdno62zpicek3m2f2a5gn2u4rb6y2cawdfizph4amblai2uaa"
NAMESPACE="bmjcelblcxcl"
BUCKET_NAME="split-fn-deploy"

SLACK_SIGNING_SECRET_VAULT_OCID="ocid1.vaultsecret.oc1.ap-mumbai-1.amaaaaaapqmtbbaasu5jollh2lmf6zof7r5je43iwzcbyx76hwochhvrxpkq"
SLACK_BOT_TOKEN_VAULT_OCID="ocid1.vaultsecret.oc1.ap-mumbai-1.amaaaaaapqmtbbaamu43cffnw6yfpf3ybpqu2faishwfm3g3q5pcr56zlwza"
GEMINI_API_KEY_VAULT_OCID="ocid1.vaultsecret.oc1.ap-mumbai-1.amaaaaaapqmtbbaa5xwt34xshldz3vsv3ivu633abaxmpjzbegjocr43q2jq"

SLACK_CHANNEL_ID="C0ACJ6KPNEM"

# Function specs: name|memory_mb|timeout_sec|runtime
FUNCTIONS=(
  "fn-slack-webhook|256|30|python3.11"
  "fn-image-extractor|512|60|python3.11"
  "fn-ai-agent|512|120|python3.11"
  "fn-slack-reply|256|30|python3.11"
)

# ── Validate prerequisites ─────────────────────────────────────────────────────

if ! command -v oci &>/dev/null; then
  echo "ERROR: 'oci' CLI is not installed or not on PATH."
  exit 1
fi

# ── Step 1: Package all functions ─────────────────────────────────────────────

echo "==> [1/6] Packaging functions"
./package.sh

# ── Step 2: Create Object Storage bucket ──────────────────────────────────────

echo "==> [2/6] Creating Object Storage bucket: $BUCKET_NAME"

if oci os bucket get --namespace "$NAMESPACE" --bucket-name "$BUCKET_NAME" &>/dev/null; then
  echo "    Bucket already exists, skipping."
else
  oci os bucket create \
    --compartment-id "$COMPARTMENT_OCID" \
    --namespace "$NAMESPACE" \
    --name "$BUCKET_NAME"
  echo "    Bucket created."
fi

# ── Step 3: Upload ZIPs to Object Storage ─────────────────────────────────────

echo "==> [3/6] Uploading function ZIPs to Object Storage"

for spec in "${FUNCTIONS[@]}"; do
  fn_name=$(echo "$spec" | cut -d'|' -f1)
  zip_file="dist/${fn_name}.zip"

  echo "    Uploading $zip_file..."
  oci os object put \
    --namespace "$NAMESPACE" \
    --bucket-name "$BUCKET_NAME" \
    --file "$zip_file" \
    --name "code/${fn_name}.zip" \
    --force
done

# ── Step 4: Resolve Application OCID ──────────────────────────────────────────

echo "==> [4/6] Resolving application and creating/updating functions"

APP_OCID=$(oci fn application list \
  --compartment-id "$COMPARTMENT_OCID" \
  --display-name "$APP_NAME" \
  --query 'data[0].id' \
  --raw-output)

if [[ -z "$APP_OCID" || "$APP_OCID" == "null" ]]; then
  echo "ERROR: Application '$APP_NAME' not found. Create it in OCI Console first."
  exit 1
fi

echo "    Application OCID: $APP_OCID"

# ── Step 5: Create/update each function ───────────────────────────────────────

get_fn_ocid() {
  oci fn function list \
    --application-id "$APP_OCID" \
    --display-name "$1" \
    --query 'data[0].id' \
    --raw-output 2>/dev/null || echo ""
}

declare -A FN_OCIDS 2>/dev/null || true
FN_WEBHOOK_OCID=""
FN_EXTRACTOR_OCID=""
FN_AGENT_OCID=""
FN_REPLY_OCID=""

for spec in "${FUNCTIONS[@]}"; do
  fn_name=$(echo "$spec" | cut -d'|' -f1)
  memory=$(echo "$spec"  | cut -d'|' -f2)
  timeout=$(echo "$spec" | cut -d'|' -f3)
  runtime=$(echo "$spec" | cut -d'|' -f4)

  source_details=$(cat <<EOF
{
  "sourceType": "OBJECT_STORAGE",
  "namespace": "$NAMESPACE",
  "bucketName": "$BUCKET_NAME",
  "objectName": "code/${fn_name}.zip"
}
EOF
)

  existing_ocid=$(get_fn_ocid "$fn_name")

  if [[ -z "$existing_ocid" || "$existing_ocid" == "null" ]]; then
    echo "    Creating $fn_name..."
    fn_ocid=$(oci fn function create \
      --application-id "$APP_OCID" \
      --display-name "$fn_name" \
      --memory-in-mbs "$memory" \
      --timeout-in-seconds "$timeout" \
      --runtime "$runtime" \
      --source-details "$source_details" \
      --query 'data.id' \
      --raw-output)
  else
    echo "    Updating $fn_name..."
    oci fn function update \
      --function-id "$existing_ocid" \
      --memory-in-mbs "$memory" \
      --timeout-in-seconds "$timeout" \
      --source-details "$source_details"
    fn_ocid="$existing_ocid"
  fi

  echo "      OCID: $fn_ocid"

  case "$fn_name" in
    fn-slack-webhook)   FN_WEBHOOK_OCID="$fn_ocid" ;;
    fn-image-extractor) FN_EXTRACTOR_OCID="$fn_ocid" ;;
    fn-ai-agent)        FN_AGENT_OCID="$fn_ocid" ;;
    fn-slack-reply)     FN_REPLY_OCID="$fn_ocid" ;;
  esac
done

# ── Step 5b: Create OCI NoSQL table ───────────────────────────────────────────

echo "==> [5/6] Creating OCI NoSQL table: split_sessions"

DDL=$(grep -v '^\s*--' db/schema.sql | tr -d '\n' | xargs)

TABLE_EXISTS=$(oci nosql table list \
  --compartment-id "$COMPARTMENT_OCID" \
  --query "length(data[?name=='split_sessions'])" \
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

# ── Step 5c: Create OCI Workflows ─────────────────────────────────────────────

echo "    Creating OCI Workflows..."

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

# ── Step 6: Set function configs ──────────────────────────────────────────────

echo "==> [6/6] Configuring functions"

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
