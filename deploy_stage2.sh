#!/usr/bin/env bash
# =============================================================================
# deploy_stage2.sh — Deploy FastAPI REST API Backend (Stage 2)
# =============================================================================
#
# Replaces the Streamlit frontend (Stage 1) with a FastAPI REST API backend
# on the existing Azure VM. Copilot Studio connects to this API.
#
# Prerequisites:
#   - Stage 1 must be deployed (VM, SQL, AI Services exist)
#   - Azure CLI logged in: az login
#
# Usage:
#   chmod +x deploy_stage2.sh
#   ./deploy_stage2.sh
#
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------
# Configuration (same as Stage 1)
# -----------------------------------------------------------
RG_WORKSHOP="rg-text2sql-workshop"
VM_NAME="vm-text2sql-frontend"
# Discover the NSG name dynamically (Azure auto-names it when creating a VM)
NSG_NAME=$(az network nsg list --resource-group "$RG_WORKSHOP" --query "[0].name" -o tsv 2>/dev/null)
if [ -z "$NSG_NAME" ]; then
    echo "ERROR: No NSG found in resource group $RG_WORKSHOP"
    exit 1
fi
echo "  Discovered NSG: $NSG_NAME"
FASTAPI_PORT=8000

# Generate random API key
API_KEY=$(openssl rand -hex 32)

echo "============================================================"
echo " Stage 2 — Deploy FastAPI REST API Backend"
echo "============================================================"
echo ""

# -----------------------------------------------------------
# Phase 1: Verify Stage 1 resources exist
# -----------------------------------------------------------
echo "[1/7] Verifying Stage 1 resources..."

VM_IP=$(az vm show -g "$RG_WORKSHOP" -n "$VM_NAME" \
    --show-details --query publicIps -o tsv 2>/dev/null) || {
    echo "ERROR: VM '${VM_NAME}' not found in '${RG_WORKSHOP}'."
    echo "       Please deploy Stage 1 first (deploy.sh)."
    exit 1
}
echo "  VM IP: ${VM_IP}"
echo ""

# -----------------------------------------------------------
# Phase 2: Upload main.py to VM
# -----------------------------------------------------------
echo "[2/7] Uploading FastAPI main.py to VM..."

az vm run-command invoke \
    --resource-group "$RG_WORKSHOP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "
cd /home/azureuser/text2sql
curl -fsSL -o main.py 'https://raw.githubusercontent.com/ibranibeny/text2sql/main/api/main.py'
echo 'Downloaded main.py: \$(wc -l < main.py) lines'
" --output none 2>/dev/null

echo "  main.py uploaded."
echo ""

# -----------------------------------------------------------
# Phase 3: Install FastAPI + Uvicorn
# -----------------------------------------------------------
echo "[3/7] Installing FastAPI and Uvicorn on VM..."

az vm run-command invoke \
    --resource-group "$RG_WORKSHOP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts '
cd /home/azureuser/text2sql
source venv/bin/activate
pip install --quiet fastapi "uvicorn[standard]" 2>&1 | tail -5
echo "Install complete."
' --output none 2>/dev/null

echo "  FastAPI + Uvicorn installed."
echo ""

# -----------------------------------------------------------
# Phase 4: Add API_KEY to .env
# -----------------------------------------------------------
echo "[4/7] Configuring API key..."

az vm run-command invoke \
    --resource-group "$RG_WORKSHOP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "
cd /home/azureuser/text2sql
# Remove any existing API_KEY line
sed -i '/^API_KEY/d' .env
# Add new API_KEY
printf 'API_KEY=\"${API_KEY}\"\n' >> .env
echo 'API_KEY configured.'
" --output none 2>/dev/null

echo "  API Key: ${API_KEY}"
echo ""

# -----------------------------------------------------------
# Phase 5: Create and start systemd service
# -----------------------------------------------------------
echo "[5/7] Setting up systemd service (text2sql-api)..."

az vm run-command invoke \
    --resource-group "$RG_WORKSHOP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts '
# Stop Stage 1 Streamlit service (if running)
sudo systemctl stop text2sql 2>/dev/null || true
sudo systemctl disable text2sql 2>/dev/null || true

# Create Stage 2 FastAPI service
sudo tee /etc/systemd/system/text2sql-api.service > /dev/null << UNIT
[Unit]
Description=Text-to-SQL FastAPI Backend
After=network.target

[Service]
Type=simple
User=azureuser
WorkingDirectory=/home/azureuser/text2sql
EnvironmentFile=/home/azureuser/text2sql/.env
ExecStart=/home/azureuser/text2sql/venv/bin/uvicorn main:app --host=0.0.0.0 --port=8000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable text2sql-api
sudo systemctl start text2sql-api
sleep 3
sudo systemctl is-active text2sql-api
' --output none 2>/dev/null

echo "  Service text2sql-api started."
echo ""

# -----------------------------------------------------------
# Phase 6: Open port 8000 on NSG
# -----------------------------------------------------------
echo "[6/7] Opening port ${FASTAPI_PORT} on NSG..."

# Check if rule already exists
EXISTING=$(az network nsg rule show \
    --resource-group "$RG_WORKSHOP" \
    --nsg-name "$NSG_NAME" \
    --name AllowFastAPI \
    --query name -o tsv 2>/dev/null) || true

if [ -z "$EXISTING" ]; then
    az network nsg rule create \
        --resource-group "$RG_WORKSHOP" \
        --nsg-name "$NSG_NAME" \
        --name AllowFastAPI \
        --priority 1020 \
        --destination-port-ranges "$FASTAPI_PORT" \
        --access Allow \
        --protocol Tcp \
        --direction Inbound \
        --output none 2>/dev/null
    echo "  NSG rule created: AllowFastAPI (port ${FASTAPI_PORT})."
else
    echo "  NSG rule already exists: AllowFastAPI."
fi
echo ""

# -----------------------------------------------------------
# Phase 7: Verify
# -----------------------------------------------------------
echo "[7/7] Verifying API..."
sleep 5

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "X-API-Key: ${API_KEY}" \
    "http://${VM_IP}:${FASTAPI_PORT}/api/health" 2>/dev/null) || HTTP_CODE="000"

if [ "$HTTP_CODE" = "200" ]; then
    echo "  Health check: OK (HTTP 200)"
else
    echo "  Health check: HTTP ${HTTP_CODE} (may need a few seconds to start)"
    echo "  Retry: curl -H 'X-API-Key: ${API_KEY}' http://${VM_IP}:${FASTAPI_PORT}/api/health"
fi

echo ""
echo "============================================================"
echo " Stage 2 Deployment Complete"
echo "============================================================"
echo ""
echo " API URL:     http://${VM_IP}:${FASTAPI_PORT}"
echo " Docs:        http://${VM_IP}:${FASTAPI_PORT}/docs"
echo " Health:      http://${VM_IP}:${FASTAPI_PORT}/api/health"
echo " API Key:     ${API_KEY}"
echo ""
echo " Test:"
echo "   curl -X POST http://${VM_IP}:${FASTAPI_PORT}/api/ask \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -H 'X-API-Key: ${API_KEY}' \\"
echo "     -d '{\"question\": \"Show me all electronics products\"}'"
echo ""
echo " OpenAPI v2 spec for Copilot Studio:"
echo "   Edit api/openapi_v2.json — replace REPLACE_WITH_VM_IP with ${VM_IP}"
echo "============================================================"
