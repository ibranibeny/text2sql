#!/usr/bin/env bash
# =============================================================================
# deploy_stage4.sh — Deploy MCP Server (Stage 4)
# =============================================================================
#
# Adds an MCP (Model Context Protocol) server alongside the existing services.
# Microsoft Copilot Studio connects via Streamable HTTP transport.
#
# Services after deployment:
#   Streamlit   :8501  (Stage 1 — Chat UI)
#   FastAPI     :8000  (Stage 2 — REST API for Copilot Studio)
#   A2A         :8002  (Stage 3 — Agent-to-Agent protocol)
#   MCP         :8003  (Stage 4 — Model Context Protocol for Copilot Studio)
#
# Prerequisites:
#   - Stage 1 must be deployed (VM, SQL, AI Services exist)
#   - Azure CLI logged in: az login
#
# Usage:
#   chmod +x deploy_stage4.sh
#   ./deploy_stage4.sh
#
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------
# Configuration
# -----------------------------------------------------------
RG_WORKSHOP="rg-text2sql-workshop"
VM_NAME="vm-text2sql-frontend"
MCP_PORT=8003

# Discover NSG name
NSG_NAME=$(az network nsg list --resource-group "$RG_WORKSHOP" --query "[0].name" -o tsv 2>/dev/null)
if [ -z "$NSG_NAME" ]; then
    echo "ERROR: No NSG found in resource group $RG_WORKSHOP"
    exit 1
fi
echo "  Discovered NSG: $NSG_NAME"

echo "============================================================"
echo " Stage 4 — Deploy MCP Server (Model Context Protocol)"
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
# Phase 2: Upload MCP server.py to VM
# -----------------------------------------------------------
echo "[2/7] Uploading MCP server.py to VM..."

# Read the server.py file and upload it
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_PY=$(cat "$SCRIPT_DIR/mcp_server/server.py")

az vm run-command invoke \
    --resource-group "$RG_WORKSHOP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "
mkdir -p /home/azureuser/text2sql/mcp_server
cat > /home/azureuser/text2sql/mcp_server/server.py << 'PYEOF'
${SERVER_PY}
PYEOF
chown -R azureuser:azureuser /home/azureuser/text2sql/mcp_server
echo \"Uploaded server.py: \$(wc -l < /home/azureuser/text2sql/mcp_server/server.py) lines\"
" --output none 2>/dev/null

echo "  server.py uploaded."
echo ""

# -----------------------------------------------------------
# Phase 3: Create symlinks for shared files
# -----------------------------------------------------------
echo "[3/7] Creating symlinks for agent.py and .env..."

az vm run-command invoke \
    --resource-group "$RG_WORKSHOP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts '#!/bin/bash
cd /home/azureuser/text2sql/mcp_server

# Symlink agent.py from parent
[ -L agent.py ] || ln -sf ../agent.py agent.py
# Symlink .env from parent
[ -L .env ] || ln -sf ../.env .env

echo "Symlinks:"
ls -la agent.py .env
' --output none 2>/dev/null

echo "  Symlinks created."
echo ""

# -----------------------------------------------------------
# Phase 4: Install MCP SDK
# -----------------------------------------------------------
echo "[4/7] Installing MCP Python SDK..."

az vm run-command invoke \
    --resource-group "$RG_WORKSHOP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts '#!/bin/bash
cd /home/azureuser/text2sql
. venv/bin/activate
pip install --quiet "mcp[cli]>=1.5.0" 2>&1 | tail -5
echo "Verify:"
python3 -c "import mcp; print(f\"mcp {mcp.__version__ if hasattr(mcp, '__version__') else 'OK'}\")"
python3 -c "from mcp.server.fastmcp import FastMCP; print(\"FastMCP import OK\")"
echo "Install complete."
' --output none 2>/dev/null

echo "  MCP SDK installed."
echo ""

# -----------------------------------------------------------
# Phase 5: Create systemd service
# -----------------------------------------------------------
echo "[5/7] Setting up systemd service..."

az vm run-command invoke \
    --resource-group "$RG_WORKSHOP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts '#!/bin/bash

sudo tee /etc/systemd/system/text2sql-mcp.service > /dev/null << UNIT
[Unit]
Description=Text2SQL MCP Server (Model Context Protocol)
After=network.target

[Service]
Type=simple
User=azureuser
WorkingDirectory=/home/azureuser/text2sql/mcp_server
EnvironmentFile=/home/azureuser/text2sql/.env
Environment=MCP_PORT=8003
ExecStart=/home/azureuser/text2sql/venv/bin/python3 server.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable text2sql-mcp
sudo systemctl restart text2sql-mcp
sleep 5

echo "Service status: $(sudo systemctl is-active text2sql-mcp)"
' --output none 2>/dev/null

echo "  Service text2sql-mcp started."
echo ""

# -----------------------------------------------------------
# Phase 6: Open port on NSG
# -----------------------------------------------------------
echo "[6/7] Opening port ${MCP_PORT} on NSG..."

EXISTING=$(az network nsg rule show \
    --resource-group "$RG_WORKSHOP" \
    --nsg-name "$NSG_NAME" \
    --name AllowMCP \
    --query name -o tsv 2>/dev/null) || true

if [ -z "$EXISTING" ]; then
    az network nsg rule create \
        --resource-group "$RG_WORKSHOP" \
        --nsg-name "$NSG_NAME" \
        --name AllowMCP \
        --priority 1040 \
        --destination-port-ranges "$MCP_PORT" \
        --access Allow \
        --protocol Tcp \
        --direction Inbound \
        --source-address-prefixes "*" \
        --destination-address-prefixes "*" \
        --output none 2>/dev/null
    echo "  NSG rule created: AllowMCP (port ${MCP_PORT})."
else
    echo "  NSG rule already exists: AllowMCP."
fi
echo ""

# -----------------------------------------------------------
# Phase 7: Verify
# -----------------------------------------------------------
echo "[7/7] Verifying MCP server..."
sleep 5

# Test health via the MCP endpoint (POST initialize)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "http://${VM_IP}:${MCP_PORT}/mcp" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "test", "version": "1.0"}}}' \
    2>/dev/null) || HTTP_CODE="000"

if [ "$HTTP_CODE" = "200" ]; then
    echo "  MCP initialize: OK (HTTP 200)"
else
    echo "  MCP initialize: HTTP ${HTTP_CODE} (may need a few seconds to start)"
    echo "  Retry manually with the curl command below."
fi

echo ""
echo "============================================================"
echo " Stage 4 Deployment Complete"
echo "============================================================"
echo ""
echo " MCP Server:  http://${VM_IP}:${MCP_PORT}/mcp"
echo " Transport:   Streamable HTTP (JSON-RPC 2.0)"
echo ""
echo " All services:"
echo "   Streamlit:   http://${VM_IP}:8501       (Chat UI)"
echo "   FastAPI:     http://${VM_IP}:8000       (REST API)"
echo "   A2A:         http://${VM_IP}:8002       (Agent-to-Agent)"
echo "   MCP:         http://${VM_IP}:${MCP_PORT}/mcp  (Model Context Protocol)"
echo ""
echo " MCP Tools exposed:"
echo "   - ask_database         Ask NL question, get SQL + answer"
echo "   - get_database_schema  Get full database schema"
echo "   - run_sql_query        Execute raw T-SQL query"
echo ""
echo " ─── Connect from Copilot Studio ───"
echo "   1. Go to Tools → Add a tool → New tool → Model Context Protocol"
echo "   2. Server URL: http://${VM_IP}:${MCP_PORT}/mcp"
echo "   3. Auth: None (or API Key with header X-API-Key)"
echo "   4. Select Create → Add to agent"
echo ""
echo " ─── Test with curl ───"
echo "   # Initialize:"
echo "   curl -X POST http://${VM_IP}:${MCP_PORT}/mcp \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -H 'Accept: application/json, text/event-stream' \\"
echo "     -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}'"
echo ""
echo "   # List tools:"
echo "   curl -X POST http://${VM_IP}:${MCP_PORT}/mcp \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -H 'Accept: application/json, text/event-stream' \\"
echo "     -d '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}'"
echo ""
echo "   # Call ask_database tool:"
echo "   curl -X POST http://${VM_IP}:${MCP_PORT}/mcp \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -H 'Accept: application/json, text/event-stream' \\"
echo "     -d '{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"ask_database\",\"arguments\":{\"question\":\"How many products are there?\"}}}'"
echo ""
echo "============================================================"
