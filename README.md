# Split — AI Bill-Splitting Slack Bot

A Slack bot that reads restaurant bill photos (or text) and splits the total among people using a multi-turn AI conversation. Runs on AWS Lambda + Step Functions with zero cold-start cost inside the AWS free tier.

## Architecture

```
Slack Event API
       │
       ▼
fn-slack-webhook  (Lambda Function URL)
  • Verify Slack signature
  • Start Step Functions async  ─────────────────────────────────┐
  • Return HTTP 200 immediately                                   │
                                                                  │
        ┌─────────── image-flow (Express Workflow) ──────────────┤
        │                                                         │
        │   fn-image-extractor  →  fn-ai-agent  →  fn-slack-reply│
        │                                                         │
        └─────────── text-flow (Express Workflow) ───────────────┤
                                                                  │
                         fn-ai-agent  →  fn-slack-reply ─────────┘
```

| Service | Purpose | Free Tier |
|---|---|---|
| Lambda | Function compute | 1M requests/month |
| Step Functions Express | Orchestration | 1M executions/month |
| DynamoDB | Session memory | 200M requests/month |
| SSM Parameter Store | Secrets | Free (standard params) |
| CloudWatch Logs | Logs | 5 GB/month |

## Prerequisites

- AWS CLI v2 configured (`aws configure`)
- Python 3.11+ and `pip`
- Slack app with **Event Subscriptions** enabled and **Bot Token Scopes**: `chat:write`, `files:read`
- Google Gemini API key

## Quick Start

### 1. Create the Lambda IAM role

Run the commented-out block at the bottom of `deploy.sh` once, then export the ARN:

```bash
# paste the block from deploy.sh, then:
export LAMBDA_ROLE_ARN=$(aws iam get-role --role-name split-lambda-role --query 'Role.Arn' --output text)
```

### 2. Set required env vars

```bash
export AWS_REGION=us-east-1
export LAMBDA_ROLE_ARN=arn:aws:iam::123456789012:role/split-lambda-role
export SLACK_CHANNEL_ID=C0123456789   # channel where the bot posts
```

### 3. Deploy everything

```bash
./deploy.sh
```

The script will:
1. Create the `split-sessions` DynamoDB table
2. Prompt you to enter your Slack signing secret, bot token, and Gemini API key and store them in SSM Parameter Store
3. Package each function (`./package.sh`)
4. Create/update all four Lambda functions
5. Create/update the two Step Functions state machines
6. Create a Lambda Function URL and print it

### 4. Configure Slack

1. In the Slack app console → **Event Subscriptions → Request URL**, paste the Lambda Function URL.
2. Subscribe to `message.channels` (or `message.groups` for private channels).
3. Reinstall the app to the workspace.

## Project Structure

```
split/
├── fn-slack-webhook/
│   ├── lambda_function.py     # Slack webhook, starts Step Functions
│   └── requirements.txt
├── fn-image-extractor/
│   ├── lambda_function.py     # Downloads Slack image, calls Gemini Vision
│   └── requirements.txt
├── fn-ai-agent/
│   ├── lambda_function.py     # LangGraph ReAct agent, DynamoDB session
│   └── requirements.txt
├── fn-slack-reply/
│   ├── lambda_function.py     # Posts reply to Slack thread
│   └── requirements.txt
├── step-functions/
│   ├── image-flow.asl.json    # Step Functions ASL: extractor→agent→reply
│   └── text-flow.asl.json     # Step Functions ASL: agent→reply
├── db/
│   └── schema.sql             # DynamoDB table documentation
├── secrets.py                 # Shared SSM Parameter Store helper
├── package.sh                 # Build ZIP for each Lambda
└── deploy.sh                  # Full deploy via AWS CLI
```

## Environment Variables

Each Lambda function reads these at runtime:

| Function | Variable | SSM Parameter |
|---|---|---|
| fn-slack-webhook | `SLACK_SIGNING_SECRET_PARAM` | `/split/slack-signing-secret` |
| fn-slack-webhook | `IMAGE_FLOW_ARN` | (set by deploy.sh) |
| fn-slack-webhook | `TEXT_FLOW_ARN` | (set by deploy.sh) |
| fn-image-extractor | `SLACK_BOT_TOKEN_PARAM` | `/split/slack-bot-token` |
| fn-image-extractor | `GEMINI_API_KEY_PARAM` | `/split/gemini-api-key` |
| fn-ai-agent | `GEMINI_API_KEY_PARAM` | `/split/gemini-api-key` |
| fn-ai-agent | `DYNAMODB_TABLE_NAME` | (literal: `split-sessions`) |
| fn-slack-reply | `SLACK_BOT_TOKEN_PARAM` | `/split/slack-bot-token` |
| fn-slack-reply | `SLACK_CHANNEL_ID` | (literal: your channel ID) |

## Re-deploying a Single Function

```bash
./package.sh fn-ai-agent          # rebuild just that ZIP
cd dist && aws lambda update-function-code \
  --function-name fn-ai-agent \
  --zip-file fileb://fn-ai-agent.zip
```

## Logs

```bash
aws logs tail /aws/lambda/fn-slack-webhook --follow
aws logs tail /aws/lambda/fn-ai-agent --follow
```
