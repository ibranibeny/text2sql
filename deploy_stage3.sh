#!/usr/bin/env bash
# =============================================================================
# deploy_stage3.sh — Deploy A2A Agent Server (Stage 3)
# =============================================================================
#
# Adds an Agent-to-Agent (A2A) protocol server alongside the existing
# Streamlit frontend and FastAPI REST API on the Azure VM.
# GitHub Copilot (or any A2A-compatible client) connects via the A2A protocol.
#
# All three services run simultaneously:
#   Streamlit (:8501)  +  FastAPI (:8000)  +  A2A Server (:8002)
#
# Prerequisites:
#   - Stage 1 must be deployed (VM, SQL, AI Services exist)
#   - Stage 2 recommended (FastAPI backend)
#   - Azure CLI logged in: az login
#
# Usage:
#   chmod +x deploy_stage3.sh
#   ./deploy_stage3.sh
#
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------
# Configuration (same as Stage 1 & 2)
# -----------------------------------------------------------
RG_WORKSHOP="rg-text2sql-workshop"
VM_NAME="vm-text2sql-frontend"
A2A_PORT=8002

# Discover the NSG name dynamically
NSG_NAME=$(az network nsg list --resource-group "$RG_WORKSHOP" --query "[0].name" -o tsv 2>/dev/null)
if [ -z "$NSG_NAME" ]; then
    echo "ERROR: No NSG found in resource group $RG_WORKSHOP"
    exit 1
fi
echo "  Discovered NSG: $NSG_NAME"

# Reuse existing API key from .env, or generate a new one
API_KEY=$(openssl rand -hex 32)

echo "============================================================"
echo " Stage 3 — Deploy A2A Agent Server"
echo "============================================================"
echo ""

# -----------------------------------------------------------
# Phase 1: Verify Stage 1 resources exist
# -----------------------------------------------------------
echo "[1/8] Verifying Stage 1 resources..."

VM_IP=$(az vm show -g "$RG_WORKSHOP" -n "$VM_NAME" \
    --show-details --query publicIps -o tsv 2>/dev/null) || {
    echo "ERROR: VM '${VM_NAME}' not found in '${RG_WORKSHOP}'."
    echo "       Please deploy Stage 1 first (deploy.sh)."
    exit 1
}
echo "  VM IP: ${VM_IP}"
echo ""

# -----------------------------------------------------------
# Phase 2: Upload A2A server files to VM
# -----------------------------------------------------------
echo "[2/8] Uploading A2A server files to VM..."

# Upload models.py
az vm run-command invoke \
    --resource-group "$RG_WORKSHOP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "
mkdir -p /home/azureuser/text2sql/a2a
cd /home/azureuser/text2sql/a2a
curl -fsSL -o models.py 'https://raw.githubusercontent.com/ibranibeny/text2sql/main/a2a/models.py'
curl -fsSL -o handler.py 'https://raw.githubusercontent.com/ibranibeny/text2sql/main/a2a/handler.py'
curl -fsSL -o server.py 'https://raw.githubusercontent.com/ibranibeny/text2sql/main/a2a/server.py'

# Symlink agent.py so handler.py can import it
ln -sf /home/azureuser/text2sql/agent.py /home/azureuser/text2sql/a2a/agent.py
# Symlink .env so dotenv picks it up
ln -sf /home/azureuser/text2sql/.env /home/azureuser/text2sql/a2a/.env

chown -R azureuser:azureuser /home/azureuser/text2sql/a2a
echo 'A2A files downloaded:'
ls -la /home/azureuser/text2sql/a2a/
" --output none 2>/dev/null

echo "  A2A server files uploaded."
echo ""

# -----------------------------------------------------------
# Phase 3: Install A2A dependencies
# -----------------------------------------------------------
echo "[3/8] Installing A2A dependencies on VM..."

az vm run-command invoke \
    --resource-group "$RG_WORKSHOP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts '#!/bin/bash
cd /home/azureuser/text2sql
. venv/bin/activate
pip install --quiet fastapi "uvicorn[standard]" pydantic 2>&1 | tail -5
echo "Verify:"
python3 -c "import fastapi; print(f\"fastapi {fastapi.__version__}\")"
python3 -c "import pydantic; print(f\"pydantic {pydantic.__version__}\")"
echo "Install complete."
' --output none 2>/dev/null

echo "  Dependencies installed."
echo ""

# -----------------------------------------------------------
# Phase 4: Configure A2A environment variables
# -----------------------------------------------------------
echo "[4/8] Configuring A2A environment..."

az vm run-command invoke \
    --resource-group "$RG_WORKSHOP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "
cd /home/azureuser/text2sql
# Remove any existing A2A config lines
sed -i '/^A2A_PORT/d' .env
sed -i '/^A2A_HOST_URL/d' .env
# Add A2A config
printf 'A2A_PORT=${A2A_PORT}\n' >> .env
printf 'A2A_HOST_URL=http://${VM_IP}:${A2A_PORT}\n' >> .env
echo 'A2A environment configured.'
grep 'A2A_' .env
" --output none 2>/dev/null

echo "  A2A_PORT=${A2A_PORT}"
echo "  A2A_HOST_URL=http://${VM_IP}:${A2A_PORT}"
echo ""

# -----------------------------------------------------------
# Phase 5: Add API_KEY to .env (if not already present)
# -----------------------------------------------------------
echo "[5/8] Configuring API key..."

az vm run-command invoke \
    --resource-group "$RG_WORKSHOP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "
cd /home/azureuser/text2sql
# Check if API_KEY already set (from Stage 2)
if grep -q '^API_KEY=' .env 2>/dev/null; then
    echo 'API_KEY already configured (from Stage 2).'
else
    printf 'API_KEY=\"${API_KEY}\"\n' >> .env
    echo 'API_KEY configured.'
fi
" --output none 2>/dev/null

# Read back the actual API key from the VM
ACTUAL_API_KEY=$(az vm run-command invoke \
    --resource-group "$RG_WORKSHOP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "grep '^API_KEY=' /home/azureuser/text2sql/.env | head -1 | sed 's/API_KEY=//' | tr -d '\"'" \
    --query 'value[0].message' -o tsv 2>/dev/null | grep -v '^\[' | tr -d '[:space:]') || true

if [ -n "$ACTUAL_API_KEY" ]; then
    API_KEY="$ACTUAL_API_KEY"
fi

echo "  API Key: ${API_KEY}"
echo ""

# -----------------------------------------------------------
# Phase 6: Create and start systemd service for A2A
# -----------------------------------------------------------
echo "[6/8] Setting up A2A systemd service..."

az vm run-command invoke \
    --resource-group "$RG_WORKSHOP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts '#!/bin/bash

# Create A2A service (port 8002)
sudo tee /etc/systemd/system/text2sql-a2a.service > /dev/null << UNIT
[Unit]
Description=Text2SQL A2A Agent Server
After=network.target

[Service]
Type=simple
User=azureuser
WorkingDirectory=/home/azureuser/text2sql/a2a
EnvironmentFile=/home/azureuser/text2sql/.env
ExecStart=/home/azureuser/text2sql/venv/bin/python3 -m uvicorn server:app --host 0.0.0.0 --port 8002 --timeout-keep-alive 120
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# Reload and start A2A service
sudo systemctl daemon-reload
sudo systemctl enable text2sql-a2a
sudo systemctl restart text2sql-a2a
sleep 4

echo "A2A Server: $(sudo systemctl is-active text2sql-a2a)"

# Show status of all Text2SQL services
echo ""
echo "All services:"
echo "  Streamlit: $(sudo systemctl is-active text2sql-streamlit 2>/dev/null || echo "not-deployed")"
echo "  FastAPI:   $(sudo systemctl is-active text2sql-api 2>/dev/null || echo "not-deployed")"
echo "  A2A:       $(sudo systemctl is-active text2sql-a2a)"
' --output none 2>/dev/null

echo "  A2A service started: text2sql-a2a."
echo ""

# -----------------------------------------------------------
# Phase 7: Open port 8002 on NSG
# -----------------------------------------------------------
echo "[7/8] Opening port ${A2A_PORT} on NSG..."

EXISTING_A2A=$(az network nsg rule show \
    --resource-group "$RG_WORKSHOP" \
    --nsg-name "$NSG_NAME" \
    --name AllowA2A \
    --query name -o tsv 2>/dev/null) || true

if [ -z "$EXISTING_A2A" ]; then
    az network nsg rule create \
        --resource-group "$RG_WORKSHOP" \
        --nsg-name "$NSG_NAME" \
        --name AllowA2A \
        --priority 1030 \
        --destination-port-ranges "$A2A_PORT" \
        --access Allow \
        --protocol Tcp \
        --direction Inbound \
        --source-address-prefixes "*" \
        --destination-address-prefixes "*" \
        --output none 2>/dev/null
    echo "  NSG rule created: AllowA2A (port ${A2A_PORT})."
else
    echo "  NSG rule already exists: AllowA2A."
fi
echo ""

# -----------------------------------------------------------
# Phase 8: Verify
# -----------------------------------------------------------
echo "[8/8] Verifying A2A Agent Server..."
sleep 5

# Test health endpoint
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://${VM_IP}:${A2A_PORT}/health" 2>/dev/null) || HTTP_CODE="000"

if [ "$HTTP_CODE" = "200" ]; then
    echo "  Health check: OK (HTTP 200)"
else
    echo "  Health check: HTTP ${HTTP_CODE} (may need a few seconds to start)"
    echo "  Retry: curl http://${VM_IP}:${A2A_PORT}/health"
fi

# Test agent card
AGENT_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://${VM_IP}:${A2A_PORT}/.well-known/agent.json" 2>/dev/null) || AGENT_HTTP="000"

if [ "$AGENT_HTTP" = "200" ]; then
    echo "  Agent Card: OK (HTTP 200)"
else
    echo "  Agent Card: HTTP ${AGENT_HTTP}"
fi

echo ""
echo "============================================================"
echo " Stage 3 Deployment Complete"
echo "============================================================"
echo ""
echo " A2A Agent:   http://${VM_IP}:${A2A_PORT}            (A2A Protocol Server)"
echo " Agent Card:  http://${VM_IP}:${A2A_PORT}/.well-known/agent.json"
echo " Health:      http://${VM_IP}:${A2A_PORT}/health"
echo " Docs:        http://${VM_IP}:${A2A_PORT}/docs"
echo " FastAPI:     http://${VM_IP}:8000                  (REST API — Stage 2)"
echo " Streamlit:   http://${VM_IP}:8501                  (Chat UI — Stage 1)"
echo ""
echo " API Key:     ${API_KEY}"
echo ""
echo " ─── Test A2A Agent Discovery ───"
echo ""
echo "   curl http://${VM_IP}:${A2A_PORT}/.well-known/agent.json | python3 -m json.tool"
echo ""
echo " ─── Test A2A Task (send a question) ───"
echo ""
echo "   curl -X POST http://${VM_IP}:${A2A_PORT}/ \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -H 'X-API-Key: ${API_KEY}' \\"
echo "     -d '{"
echo "       \"jsonrpc\": \"2.0\","
echo "       \"id\": \"1\","
echo "       \"method\": \"tasks/send\","
echo "       \"params\": {"
echo "         \"id\": \"test-task-1\","
echo "         \"message\": {"
echo "           \"role\": \"user\","
echo "           \"parts\": [{\"type\": \"text\", \"text\": \"Show me the top 5 customers\"}]"
echo "         }"
echo "       }"
echo "     }'"
echo ""
echo " ─── Connect from GitHub Copilot (VS Code) ───"
echo ""
echo "  Add to your VS Code settings.json:"
echo "  {"
echo "    \"github.copilot.chat.agents\": {"
echo "      \"text2sql\": {"
echo "        \"url\": \"http://${VM_IP}:${A2A_PORT}\""
echo "      }"
echo "    }"
echo "  }"
echo ""
echo "============================================================"
