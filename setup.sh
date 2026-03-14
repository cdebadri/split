#!/bin/bash
set -e

# --- 1) Open firewall ---
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --add-port=22/tcp
firewall-cmd --permanent --add-port=5678/tcp
firewall-cmd --reload

# --- 2) Install prerequisites ---
yum install -y yum-utils git dnf-plugins-core python3-pip

# --- 3) Add Docker repo and install ---
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
yum install -y docker-ce docker-ce-cli containerd.io

# --- 4) Enable and start Docker ---
systemctl enable docker
systemctl start docker
usermod -aG docker opc

# --- 5) Docker Compose ---
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL https://github.com/docker/compose/releases/download/v2.22.0/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# --- 6) Clone repo ---
git clone https://github.com/cdebadri/split.git /opt/n8n

# --- 7) Install OCI CLI ---
/usr/bin/pip3 install oci-cli --no-cache-dir

# --- 8) Fetch secrets ---
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
  echo "${ENV_VAR}=\"${SECRET_VALUE}\"" >> "$ENV_FILE"
done
chmod 600 "$ENV_FILE"

# --- 9) Start N8N ---
set -a
source /etc/environment.secrets
set +a

docker run -d \
  --name n8n \
  --restart unless-stopped \
  -p 5678:5678 \
  -v /root/n8n-data:/home/node/.n8n \
  -e N8N_BLOCK_ENV_ACCESS_IN_NODE=false \
  -e N8N_BASIC_AUTH_ACTIVE=true \
  -e N8N_BASIC_AUTH_USER="$ENV_USERNAME" \
  -e N8N_BASIC_AUTH_PASSWORD="$ENV_PASSWORD" \
  -e ENV_SLACK_SIGNING_SECRET="$ENV_SLACK_SIGNING_SECRET" \
  -e ENV_SLACK_API_TOKEN="$ENV_SLACK_API_TOKEN" \
  -e ENV_WEBHOOK_URL="$ENV_WEBHOOK_URL" \
  -e GEMINI_API_KEY="$GEMINI_API_KEY" \
  docker.n8n.io/n8nio/n8n

# --- 10) Wait for N8N ---
echo "Waiting for N8N to start..."
for i in $(seq 1 20); do
  if curl -s -o /dev/null -w "%{http_code}" http://localhost:5678/healthz | grep -q "200"; then
    echo "N8N is up"
    break
  fi
  echo "Attempt $i: not ready, waiting 5s..."
  sleep 5
done

# --- 11) Import and activate workflow ---
source /etc/environment.secrets
curl -fsSL "https://raw.githubusercontent.com/cdebadri/split/refs/heads/main/Split.json" -o /tmp/workflow.json
WORKFLOW_RESPONSE=$(curl -s -X POST "http://localhost:5678/api/v1/workflows" \
  -u "$ENV_USERNAME:$ENV_PASSWORD" \
  -H "Content-Type: application/json" \
  -d @/tmp/workflow.json)
WORKFLOW_ID=$(echo "$WORKFLOW_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
curl -s -X PATCH "http://localhost:5678/api/v1/workflows/$WORKFLOW_ID" \
  -u "$ENV_USERNAME:$ENV_PASSWORD" \
  -H "Content-Type: application/json" \
  -d '{"active": true}'
echo "Workflow activated"
