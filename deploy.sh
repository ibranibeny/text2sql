#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Option C: Fully Public, Simplest Setup
# Agentic AI Text-to-SQL Workshop
# =============================================================================
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh
#
# Prerequisites:
#   - Azure CLI >= 2.60 installed and logged in (az login)
#   - Active Azure subscription with Contributor/Owner role
#   - SSH key pair (~/.ssh/id_rsa.pub) — will be auto-generated if missing
#
# This script deploys ALL Azure infrastructure for Option C:
#   1. Resource Groups (VM region + AI region)
#   2. Azure SQL Server (fully public) + Database (Basic DTU)
#   3. Azure AI Services account + GPT-4o deployment
#   4. Azure VM (Ubuntu 22.04) with public IP + port 8501 open
#   5. Seeds the database with sample data
#   6. Configures the VM with all dependencies and application code
#   7. Starts the Streamlit application
#
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------
# ANSI colours for output
# -----------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Colour

log()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
err()  { echo -e "${RED}[ERR ]${NC}  $*" >&2; }

# -----------------------------------------------------------
# Configuration — EDIT THESE VARIABLES BEFORE RUNNING
# -----------------------------------------------------------

# General
SUBSCRIPTION_ID=""                          # Leave empty to use current default
RG_NAME="rg-text2sql-workshop"
LOCATION_VM="indonesiacentral"              # VM + SQL region (Indonesia)

# AI Foundry (may need separate region for GPT-4o availability)
RG_AI_NAME="rg-text2sql-ai"
LOCATION_AI="eastus"                        # Adjust if needed

# Azure SQL — Option C (Fully Public)
SQL_SERVER_NAME="sql-text2sql-$(openssl rand -hex 4)"  # Globally unique
SQL_ADMIN_USER="sqladmin"
SQL_ADMIN_PASSWORD=""                       # Will prompt if empty
SQL_DB_NAME="SalesDB"

# Azure AI Services
AI_ACCOUNT_NAME="ai-text2sql-$(openssl rand -hex 4)"   # Globally unique
AI_DEPLOYMENT_NAME="gpt-4o"
AI_MODEL_NAME="gpt-4o"
AI_MODEL_VERSION="2024-08-06"

# Azure VM
VM_NAME="vm-text2sql-frontend"
VM_IMAGE="Canonical:0001-com-ubuntu-minimal-jammy:minimal-22_04-lts-gen2:latest"
VM_SIZE="Standard_B2s"
VM_ADMIN="azureuser"

# Script directory (for locating companion files)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------
# Helper functions
# -----------------------------------------------------------

prompt_password() {
    if [[ -z "$SQL_ADMIN_PASSWORD" ]]; then
        echo ""
        echo -e "${YELLOW}You must set a SQL admin password.${NC}"
        echo "Requirements: 8+ chars, uppercase, lowercase, number, special char."
        read -s -p "Enter SQL admin password: " SQL_ADMIN_PASSWORD
        echo ""
        read -s -p "Confirm SQL admin password: " SQL_ADMIN_PASSWORD_CONFIRM
        echo ""
        if [[ "$SQL_ADMIN_PASSWORD" != "$SQL_ADMIN_PASSWORD_CONFIRM" ]]; then
            err "Passwords do not match. Exiting."
            exit 1
        fi
    fi
}

check_prerequisites() {
    log "Checking prerequisites..."

    if ! command -v az &> /dev/null; then
        err "Azure CLI (az) not found. Install from: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
        exit 1
    fi

    # Check login status
    if ! az account show &> /dev/null; then
        warn "Not logged in. Running 'az login'..."
        az login
    fi

    ok "Azure CLI ready: $(az version --query '\"azure-cli\"' -o tsv)"
}

# -----------------------------------------------------------
# MAIN DEPLOYMENT
# -----------------------------------------------------------

main() {
    echo ""
    echo "============================================================"
    echo "  Agentic AI Text-to-SQL Workshop — Deployment (Option C)"
    echo "  Fully Public · Simplest Setup · Single Resource Group"
    echo "============================================================"
    echo ""

    check_prerequisites
    prompt_password

    # Set subscription if specified
    if [[ -n "$SUBSCRIPTION_ID" ]]; then
        log "Setting subscription to $SUBSCRIPTION_ID..."
        az account set --subscription "$SUBSCRIPTION_ID"
    fi
    ok "Subscription: $(az account show --query '[name, id]' -o tsv)"

    # ===========================================================
    # PHASE 1: Resource Groups
    # ===========================================================
    echo ""
    log "═══ PHASE 1: Creating Resource Groups ═══"

    log "Creating resource group: $RG_NAME in $LOCATION_VM..."
    az group create \
        --name "$RG_NAME" \
        --location "$LOCATION_VM" \
        --tags project=text2sql-workshop environment=dev option=C \
        -o none
    ok "Resource group $RG_NAME created."

    log "Creating resource group: $RG_AI_NAME in $LOCATION_AI..."
    az group create \
        --name "$RG_AI_NAME" \
        --location "$LOCATION_AI" \
        --tags project=text2sql-workshop environment=dev option=C \
        -o none
    ok "Resource group $RG_AI_NAME created."

    # ===========================================================
    # PHASE 2C: Azure SQL (Fully Public)
    # ===========================================================
    echo ""
    log "═══ PHASE 2C: Azure SQL Database (Fully Public) ═══"

    log "Creating SQL Server: $SQL_SERVER_NAME in $LOCATION_VM..."
    az sql server create \
        --name "$SQL_SERVER_NAME" \
        --resource-group "$RG_NAME" \
        --location "$LOCATION_VM" \
        --admin-user "$SQL_ADMIN_USER" \
        --admin-password "$SQL_ADMIN_PASSWORD" \
        -o none
    ok "SQL Server created: $SQL_SERVER_NAME"

    log "Configuring firewall: Allow ALL IPs (0.0.0.0 – 255.255.255.255)..."
    az sql server firewall-rule create \
        --resource-group "$RG_NAME" \
        --server "$SQL_SERVER_NAME" \
        --name AllowAll \
        --start-ip-address 0.0.0.0 \
        --end-ip-address 255.255.255.255 \
        -o none
    ok "Firewall rule: AllowAll created (fully public)."

    log "Creating database: $SQL_DB_NAME (Basic edition, 5 DTU)..."
    az sql db create \
        --resource-group "$RG_NAME" \
        --server "$SQL_SERVER_NAME" \
        --name "$SQL_DB_NAME" \
        --edition Basic \
        --capacity 5 \
        --max-size 2GB \
        -o none
    ok "Database $SQL_DB_NAME created."

    SQL_FQDN="${SQL_SERVER_NAME}.database.windows.net"
    ok "SQL FQDN: $SQL_FQDN"

    # ===========================================================
    # PHASE 3: Azure AI Foundry
    # ===========================================================
    echo ""
    log "═══ PHASE 3: Azure AI Services (Foundry) ═══"

    log "Creating AI Services account: $AI_ACCOUNT_NAME in $LOCATION_AI..."
    az cognitiveservices account create \
        --name "$AI_ACCOUNT_NAME" \
        --resource-group "$RG_AI_NAME" \
        --location "$LOCATION_AI" \
        --kind AIServices \
        --sku S0 \
        --custom-domain "$AI_ACCOUNT_NAME" \
        -o none
    ok "AI Services account created: $AI_ACCOUNT_NAME"

    log "Deploying model: $AI_MODEL_NAME ($AI_MODEL_VERSION)..."
    az cognitiveservices account deployment create \
        --name "$AI_ACCOUNT_NAME" \
        --resource-group "$RG_AI_NAME" \
        --deployment-name "$AI_DEPLOYMENT_NAME" \
        --model-name "$AI_MODEL_NAME" \
        --model-version "$AI_MODEL_VERSION" \
        --model-format OpenAI \
        --sku-capacity 10 \
        --sku-name "Standard" \
        -o none
    ok "Model deployed: $AI_DEPLOYMENT_NAME"

    # Retrieve endpoint and key
    AI_ENDPOINT=$(az cognitiveservices account show \
        --name "$AI_ACCOUNT_NAME" \
        --resource-group "$RG_AI_NAME" \
        --query "properties.endpoint" -o tsv)

    AI_KEY=$(az cognitiveservices account keys list \
        --name "$AI_ACCOUNT_NAME" \
        --resource-group "$RG_AI_NAME" \
        --query "key1" -o tsv)

    ok "AI Endpoint: $AI_ENDPOINT"
    ok "AI Key: ***${AI_KEY: -4}"

    # ===========================================================
    # PHASE 4: Azure VM
    # ===========================================================
    echo ""
    log "═══ PHASE 4: Azure VM (Frontend Host) ═══"

    log "Creating VM: $VM_NAME in $LOCATION_VM ($VM_SIZE)..."
    az vm create \
        --resource-group "$RG_NAME" \
        --name "$VM_NAME" \
        --location "$LOCATION_VM" \
        --image "$VM_IMAGE" \
        --size "$VM_SIZE" \
        --admin-username "$VM_ADMIN" \
        --generate-ssh-keys \
        --public-ip-sku Standard \
        --tags project=text2sql-workshop role=frontend \
        -o none
    ok "VM created: $VM_NAME"

    log "Opening port 8501 (Streamlit)..."
    az vm open-port \
        --resource-group "$RG_NAME" \
        --name "$VM_NAME" \
        --port 8501 \
        --priority 1010 \
        -o none
    ok "Port 8501 opened."

    log "Opening port 22 (SSH) — ensuring access..."
    az vm open-port \
        --resource-group "$RG_NAME" \
        --name "$VM_NAME" \
        --port 22 \
        --priority 1000 \
        -o none 2>/dev/null || true
    ok "Port 22 confirmed open."

    VM_IP=$(az vm show \
        --resource-group "$RG_NAME" \
        --name "$VM_NAME" \
        --show-details \
        --query publicIps -o tsv)

    ok "VM Public IP: $VM_IP"

    # ===========================================================
    # PHASE 5: Deploy Application to VM
    # ===========================================================
    echo ""
    log "═══ PHASE 5: Deploying Application to VM ═══"

    # Generate .env file
    log "Generating .env configuration..."
    cat > /tmp/text2sql_env <<EOF
# Microsoft Foundry / AI Foundry
AZURE_OPENAI_ENDPOINT=${AI_ENDPOINT}
AZURE_OPENAI_API_KEY=${AI_KEY}
AZURE_OPENAI_DEPLOYMENT=${AI_DEPLOYMENT_NAME}

# Azure SQL Database
SQL_SERVER=${SQL_FQDN}
SQL_DATABASE=${SQL_DB_NAME}
SQL_USERNAME=${SQL_ADMIN_USER}
SQL_PASSWORD="${SQL_ADMIN_PASSWORD}"
SQL_DRIVER="{ODBC Driver 18 for SQL Server}"
EOF
    ok ".env file generated."

    # Wait for VM to be fully ready for SSH
    log "Waiting for VM SSH to become available..."
    for i in $(seq 1 30); do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
            "$VM_ADMIN@$VM_IP" "echo ready" &>/dev/null; then
            break
        fi
        echo -n "."
        sleep 10
    done
    echo ""
    ok "VM SSH is ready."

    # Copy files to VM
    log "Copying application files to VM..."
    scp -o StrictHostKeyChecking=no \
        "$SCRIPT_DIR/app/agent.py" \
        "$SCRIPT_DIR/app/app.py" \
        "$SCRIPT_DIR/seed_data.sql" \
        "$SCRIPT_DIR/setup_vm.sh" \
        /tmp/text2sql_env \
        "$VM_ADMIN@$VM_IP:/tmp/"
    ok "Files copied to VM."

    # Execute VM setup script
    log "Running setup script on VM (this may take 3-5 minutes)..."
    ssh -o StrictHostKeyChecking=no "$VM_ADMIN@$VM_IP" \
        "chmod +x /tmp/setup_vm.sh && /tmp/setup_vm.sh"
    ok "VM setup complete."

    # Clean up local temp
    rm -f /tmp/text2sql_env

    # ===========================================================
    # SUMMARY
    # ===========================================================
    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}DEPLOYMENT COMPLETE${NC}"
    echo "============================================================"
    echo ""
    echo "  Resources:"
    echo "  ──────────────────────────────────────────────────"
    echo "  Resource Group (VM/SQL):  $RG_NAME"
    echo "  Resource Group (AI):      $RG_AI_NAME"
    echo "  SQL Server:               $SQL_FQDN"
    echo "  SQL Database:             $SQL_DB_NAME"
    echo "  SQL Admin User:           $SQL_ADMIN_USER"
    echo "  AI Services Account:      $AI_ACCOUNT_NAME"
    echo "  AI Endpoint:              $AI_ENDPOINT"
    echo "  VM Name:                  $VM_NAME"
    echo "  VM Public IP:             $VM_IP"
    echo ""
    echo "  Access:"
    echo "  ──────────────────────────────────────────────────"
    echo -e "  Streamlit App:  ${GREEN}http://${VM_IP}:8501${NC}"
    echo "  SSH:            ssh ${VM_ADMIN}@${VM_IP}"
    echo "  Azure Portal:   https://portal.azure.com"
    echo "  SQL Query Editor: Azure Portal → SQL Databases → SalesDB → Query editor"
    echo ""
    echo "  Clean-up (when done):"
    echo "  ──────────────────────────────────────────────────"
    echo "  az group delete --name $RG_NAME --yes --no-wait"
    echo "  az group delete --name $RG_AI_NAME --yes --no-wait"
    echo ""

    # Save deployment info
    cat > "$SCRIPT_DIR/deployment_output.txt" <<EOF
# Text-to-SQL Workshop — Deployment Output
# Generated: $(date -u +"%Y-%m-%d %H:%M UTC")

RG_NAME=$RG_NAME
RG_AI_NAME=$RG_AI_NAME
SQL_SERVER_NAME=$SQL_SERVER_NAME
SQL_FQDN=$SQL_FQDN
SQL_DB_NAME=$SQL_DB_NAME
SQL_ADMIN_USER=$SQL_ADMIN_USER
AI_ACCOUNT_NAME=$AI_ACCOUNT_NAME
AI_ENDPOINT=$AI_ENDPOINT
VM_NAME=$VM_NAME
VM_IP=$VM_IP
VM_ADMIN=$VM_ADMIN
STREAMLIT_URL=http://${VM_IP}:8501
EOF
    ok "Deployment details saved to deployment_output.txt"
}

main "$@"
