#!/bin/bash
set -e

# --- 1) Firewall ---
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --add-port=22/tcp
firewall-cmd --permanent --add-port=5678/tcp
firewall-cmd --reload

# --- 2) Install Node.js via nvm ---
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
export NVM_DIR="$HOME/.nvm"
source "$NVM_DIR/nvm.sh"
nvm install 20
nvm use 20

# --- 3) Install N8N ---
npm install -g n8n

# --- 4) Install OCI CLI and fetch secrets ---
pip3 install oci-cli --no-cache-dir

ENV_FILE="/etc/environment.secrets"
declare -A SECRETS=(
  ["ENV_SLACK_SIGNING_SECRET"]="ocid1.vaultsecret.oc1.ap-mumbai-1.amaaaaaapqmtbbaasu5jollh2lmf6zof7r5je43iwzcbyx76hwochhvrxpkq"
  ["ENV_SLACK_API_TOKEN"]="ocid1.vaultsecret.oc1.ap-mumbai-1.amaaaaaapqmtbbaamu43cffnw6yfpf3ybpqu2faishwfm3g3q5pcr56zlwza"
  ["ENV_WEBHOOK_URL"]="ocid1.vaultsecret.oc1.ap-mumbai-1.amaaaaaapqmtbbaaeqsllh2xtyxgke3lcbmhrawrsgpsp7om5ille4wpfgma"
  ["GEMINI_API_KEY"]="ocid1.vaultsecret.oc1.ap-mumbai-1.amaaaaaapqmtbbaa5xwt34xshldz3vsv3ivu633abaxmpjzbegjocr43q2jq"
  ["ENV_USERNAME"]="ocid1.vaultsecret.oc1.ap-mumbai-1.amaaaaaapqmtbbaacdu5a2w7mwx4srkgwh2jyivmwh4wtv4v6f73i7jn5rta"
  ["ENV_PASSWORD"]="ocid1.vaultsecret.oc1.ap-mumbai-1.amaaaaaapqmtbbaatjfrks5cyin3uzwaijjbewkvobcq2qovh5rlv6ygcmyq"
)
for ENV_VAR in "${!SECRETS[@]}"; do
  SECRET_VALUE=$(/usr/local/bin/oci secrets secret-bundle get \
    --secret-id "${SECRETS[$ENV_VAR]}" \
    --auth instance_principal \
    --query 'data."secret-bundle-content".content' \
    --raw-output | base64 -d)
  echo "${ENV_VAR}=${SECRET_VALUE}" >> "$ENV_FILE"
done
chmod 600 "$ENV_FILE"

# --- 5) Start N8N temporarily WITH UI for workflow import ---
set -a
source "$ENV_FILE"
set +a

NODE_PATH=$(which n8n | xargs dirname)

cat > /etc/systemd/system/n8n.service <<EOF
[Unit]
Description=N8N Workflow Automation
After=network.target

[Service]
Type=simple
User=opc
EnvironmentFile=/etc/environment.secrets
Environment=N8N_BASIC_AUTH_ACTIVE=true
Environment=EXECUTIONS_MODE=regular
Environment=N8N_SKIP_WEBHOOK_DEREGISTRATION_SHUTDOWN=true
ExecStart=${NODE_PATH}/n8n start
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl enable n8n
systemctl start n8n

# --- 6) Wait for N8N to be ready ---
echo "Waiting for N8N to start..."
for i in $(seq 1 20); do
  if curl -s -o /dev/null -w "%{http_code}" http://localhost:5678/healthz | grep -q "200"; then
    echo "N8N is up"
    break
  fi
  echo "Attempt $i: not ready, waiting 5s..."
  sleep 5
done

# --- 7) Import and activate workflow ---
source "$ENV_FILE"
curl -fsSL "https://raw.githubusercontent.com/cdebadri/split/refs/heads/main/Split.json" -o /tmp/workflow.json

WORKFLOW_RESPONSE=$(curl -s -X POST "http://localhost:5678/api/v1/workflows" \
  -u "$ENV_USERNAME:$ENV_PASSWORD" \
  -H "Content-Type: application/json" \
  -d @/tmp/workflow.json)

echo "Import response: $WORKFLOW_RESPONSE"

WORKFLOW_ID=$(echo "$WORKFLOW_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "Workflow ID: $WORKFLOW_ID"

curl -s -X PATCH "http://localhost:5678/api/v1/workflows/$WORKFLOW_ID" \
  -u "$ENV_USERNAME:$ENV_PASSWORD" \
  -H "Content-Type: application/json" \
  -d '{"active": true}'

echo "Workflow activated"

# --- 8) Restart N8N in headless mode (no UI) ---
echo "Restarting N8N in headless mode..."

cat > /etc/systemd/system/n8n.service <<EOF
[Unit]
Description=N8N Workflow Automation (headless)
After=network.target

[Service]
Type=simple
User=opc
EnvironmentFile=/etc/environment.secrets
Environment=N8N_DISABLE_UI=true
Environment=N8N_BASIC_AUTH_ACTIVE=true
Environment=EXECUTIONS_MODE=regular
Environment=N8N_SKIP_WEBHOOK_DEREGISTRATION_SHUTDOWN=true
ExecStart=${NODE_PATH}/n8n start
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl restart n8n

echo "N8N running in headless mode"
echo "Done!"
