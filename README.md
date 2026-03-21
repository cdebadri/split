# Split — OCI Functions

Converts the Split n8n workflow into four lightweight Python OCI Functions orchestrated by OCI Workflows.

## Architecture

```
Slack Event API
      │
      ▼
fn-slack-webhook  ──(url_verification)──► Slack (challenge response)
      │
      ├── has image file ──► OCI Workflow: image-flow
      │                        │
      │                        ├─ fn-image-extractor  (Gemini Vision)
      │                        ├─ fn-ai-agent         (Gemini + tools)
      │                        └─ fn-slack-reply      (Slack thread reply)
      │
      └── text only ──► OCI Workflow: text-flow
                           │
                           ├─ fn-ai-agent         (Gemini + tools)
                           └─ fn-slack-reply      (Slack thread reply)
```

Session memory is persisted in OCI NoSQL Database (Forever Free tier), keyed by `Invoice-{event.ts}`.
Rows automatically expire after 30 days via the table TTL.

## Prerequisites

- OCI CLI installed and configured (`oci setup config`)
- OCI Functions application created in your tenancy
- `fn` CLI installed (`brew install fn` or equivalent)
- OCI NoSQL table created (Forever Free tier: 25 GB storage, 133M ops/month)
- Google Gemini API key
- Slack app with Bot Token and Event Subscriptions enabled

## Project Structure

```
split/
  fn-slack-webhook/      # Entry point — Slack event router
  fn-image-extractor/    # Downloads & analyzes invoice images via Gemini Vision
  fn-ai-agent/           # Core share-calculation agent (function calling + NoSQL memory)
  fn-slack-reply/        # Posts results back to Slack
  workflows/
    image-flow.yaml      # OCI Workflow for image events
    text-flow.yaml       # OCI Workflow for text-only events
  db/
    schema.sql           # OCI NoSQL sessions table DDL
```

## Setup

### 1. Create the OCI NoSQL Sessions Table

Run the DDL via the OCI Console (NoSQL → SQL Worksheet) or the CLI:

```bash
oci nosql query execute \
  --compartment-id <compartment-ocid> \
  --statement "$(cat db/schema.sql)"
```

Note the table name (`sessions`) — it maps to the `NOSQL_TABLE_NAME` function config key.

### 2. Store Secrets in OCI Vault

Create secrets in OCI Vault (Menu → Identity & Security → Vault) and note each secret's OCID:

| Secret Name              | Description                        |
|--------------------------|------------------------------------|
| `SLACK_BOT_TOKEN`        | Slack Bot OAuth Token (`xoxb-...`) |
| `SLACK_SIGNING_SECRET`   | Slack app signing secret           |
| `GEMINI_API_KEY`         | Google Gemini API key              |

At runtime, functions fetch these values via the OCI Secrets API using Resource Principal auth — the actual secret values are never stored in `func.yaml` or environment config.

Grant the function's dynamic group permission to read secrets:

```
Allow dynamic-group <fn-dynamic-group> to read secret-bundles in compartment <compartment-name>
```

### 3. Deploy Each Function

```bash
# Set your OCI Functions application name
export FN_APP=split-app

# Deploy all four functions
for fn_dir in fn-slack-webhook fn-image-extractor fn-ai-agent fn-slack-reply; do
  cd $fn_dir
  fn deploy --app $FN_APP
  cd ..
done
```

After deployment, note the OCID for each function from the OCI Console or:

```bash
oci fn function list --application-id <app-ocid> --query "data[*].{name:\"display-name\",ocid:id}"
```

### 4. Set Function Configuration

For each function, set the Vault secret OCIDs and any non-sensitive config via the CLI:

```bash
# fn-slack-webhook
oci fn function update \
  --function-id <fn-slack-webhook-ocid> \
  --config '{"SLACK_SIGNING_SECRET_OCID":"ocid1.vaultsecret.oc1...<...>","IMAGE_WORKFLOW_OCID":"<value>","TEXT_WORKFLOW_OCID":"<value>","OCI_COMPARTMENT_OCID":"<value>"}'

# fn-image-extractor
oci fn function update \
  --function-id <fn-image-extractor-ocid> \
  --config '{"SLACK_BOT_TOKEN_SECRET_OCID":"ocid1.vaultsecret.oc1...<...>","GEMINI_API_KEY_SECRET_OCID":"ocid1.vaultsecret.oc1...<...>"}'

# fn-ai-agent
oci fn function update \
  --function-id <fn-ai-agent-ocid> \
  --config '{"GEMINI_API_KEY_SECRET_OCID":"ocid1.vaultsecret.oc1...<...>","NOSQL_TABLE_NAME":"split_sessions","OCI_COMPARTMENT_OCID":"<value>"}'

# fn-slack-reply
oci fn function update \
  --function-id <fn-slack-reply-ocid> \
  --config '{"SLACK_BOT_TOKEN_SECRET_OCID":"ocid1.vaultsecret.oc1...<...>","SLACK_CHANNEL_ID":"C0ACJ6KPNEM"}'
```

The OCIDs are safe to store in function config — they are identifiers, not credentials. The function fetches the actual secret value from Vault at invocation time using Resource Principal auth (`vault.py`).

Grant the function's dynamic group the following IAM policy so it can access NoSQL:

```
Allow dynamic-group <fn-dynamic-group> to use nosql-rows in compartment <compartment-name>
```

### 5. Deploy OCI Workflows

Fill in the function OCIDs in `workflows/image-flow.yaml` and `workflows/text-flow.yaml`, then deploy:

```bash
oci workflow workflow create \
  --compartment-id <compartment-ocid> \
  --from-file workflows/image-flow.yaml

oci workflow workflow create \
  --compartment-id <compartment-ocid> \
  --from-file workflows/text-flow.yaml
```

Note the OCID for each workflow.

### 6. Configure fn-slack-webhook

Set the workflow OCIDs on the webhook function:

```bash
oci fn function update \
  --function-id <fn-slack-webhook-ocid> \
  --config '{
    "IMAGE_WORKFLOW_OCID": "<image-flow-workflow-ocid>",
    "TEXT_WORKFLOW_OCID":  "<text-flow-workflow-ocid>",
    "OCI_COMPARTMENT_OCID": "<compartment-ocid>"
  }'
```

### 7. Expose fn-slack-webhook via OCI API Gateway

Create an API Gateway deployment with a route:

```
POST /slack/events  →  fn-slack-webhook
```

The resulting URL is the endpoint you register in the Slack app's **Event Subscriptions** → **Request URL**.

### 8. Configure Slack App

In your Slack app settings:

- **Event Subscriptions → Request URL**: `https://<api-gateway-url>/slack/events`
- **Subscribe to Bot Events**: `message.channels` (or `message.groups` for private channels)
- **Scopes**: `chat:write`, `files:read`, `channels:history`
- Invite the bot to the `finance` channel (`C0ACJ6KPNEM`)

## Environment Variables Reference

| Config key                    | Function(s)               | Description                                        |
|-------------------------------|---------------------------|----------------------------------------------------|
| `SLACK_SIGNING_SECRET_OCID`   | webhook                   | OCI Vault secret OCID for the Slack signing secret |
| `SLACK_BOT_TOKEN_SECRET_OCID` | extractor, reply          | OCI Vault secret OCID for the Slack Bot token      |
| `GEMINI_API_KEY_SECRET_OCID`  | extractor, ai-agent       | OCI Vault secret OCID for the Gemini API key       |
| `NOSQL_TABLE_NAME`            | ai-agent                  | OCI NoSQL table name (default: `sessions`)         |
| `OCI_COMPARTMENT_OCID`        | webhook, ai-agent         | OCI compartment OCID                               |
| `SLACK_CHANNEL_ID`            | reply                     | Target Slack channel (default: `C0ACJ6KPNEM`)      |
| `IMAGE_WORKFLOW_OCID`         | webhook                   | OCID of the image-flow OCI Workflow                |
| `TEXT_WORKFLOW_OCID`          | webhook                   | OCID of the text-flow OCI Workflow                 |

## Local Testing

Each function can be invoked locally using the `fn` CLI:

```bash
# Test fn-slack-webhook with a url_verification challenge
echo '{"type":"url_verification","challenge":"test123"}' | fn invoke $FN_APP fn-slack-webhook

# Test fn-image-extractor (requires real Slack file URL and valid tokens)
echo '{"event":{"files":[{"url_private_download":"https://..."}],"ts":"123.456"}}' \
  | fn invoke $FN_APP fn-image-extractor

# Test fn-ai-agent with inline bill text
echo '{"body":{"event":{"text":"Alice had pasta $12, Bob had pizza $15","ts":"123.456"}}}' \
  | fn invoke $FN_APP fn-ai-agent

# Test fn-slack-reply
echo '{"output":"Alice: $12, Bob: $15","thread_ts":"123.456"}' \
  | fn invoke $FN_APP fn-slack-reply
```
