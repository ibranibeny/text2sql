#!/usr/bin/env bash
# =============================================================================
# cleanup.sh — Tear down all Azure resources from the Text-to-SQL Workshop
# =============================================================================
#
# Usage:
#   chmod +x cleanup.sh
#   ./cleanup.sh              # Interactive (prompts for confirmation)
#   ./cleanup.sh --yes        # Skip confirmation (CI/automation)
#
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
err()  { echo -e "${RED}[ERR ]${NC}  $*" >&2; }

# -----------------------------------------------------------
# Configuration — must match deploy.sh values
# -----------------------------------------------------------
RG_NAME="rg-text2sql-workshop"
RG_AI_NAME="rg-text2sql-ai"

# -----------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------
AUTO_CONFIRM=false
if [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]]; then
    AUTO_CONFIRM=true
fi

# -----------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------
if ! command -v az &> /dev/null; then
    err "Azure CLI (az) not found."
    exit 1
fi

if ! az account show &> /dev/null; then
    err "Not logged in. Run 'az login' first."
    exit 1
fi

echo ""
echo "============================================================"
echo -e "  ${RED}Text-to-SQL Workshop — Resource Cleanup${NC}"
echo "============================================================"
echo ""

# -----------------------------------------------------------
# Discover resources
# -----------------------------------------------------------
log "Checking resource groups..."

RG_EXISTS=false
RG_AI_EXISTS=false

if az group show --name "$RG_NAME" &> /dev/null; then
    RG_EXISTS=true
    RG_RESOURCES=$(az resource list --resource-group "$RG_NAME" --query "length([])" -o tsv 2>/dev/null || echo "?")
    echo -e "  ${CYAN}$RG_NAME${NC}  — $RG_RESOURCES resource(s)"
    az resource list --resource-group "$RG_NAME" --query "[].{Name:name, Type:type}" -o table 2>/dev/null || true
    echo ""
else
    warn "Resource group $RG_NAME does not exist."
fi

if az group show --name "$RG_AI_NAME" &> /dev/null; then
    RG_AI_EXISTS=true
    RG_AI_RESOURCES=$(az resource list --resource-group "$RG_AI_NAME" --query "length([])" -o tsv 2>/dev/null || echo "?")
    echo -e "  ${CYAN}$RG_AI_NAME${NC}  — $RG_AI_RESOURCES resource(s)"
    az resource list --resource-group "$RG_AI_NAME" --query "[].{Name:name, Type:type}" -o table 2>/dev/null || true
    echo ""
else
    warn "Resource group $RG_AI_NAME does not exist."
fi

if [[ "$RG_EXISTS" == false && "$RG_AI_EXISTS" == false ]]; then
    ok "Nothing to clean up — no resource groups found."
    exit 0
fi

# -----------------------------------------------------------
# Confirmation
# -----------------------------------------------------------
if [[ "$AUTO_CONFIRM" == false ]]; then
    echo ""
    echo -e "${RED}⚠  This will PERMANENTLY DELETE all resources above.${NC}"
    echo -e "${RED}   This action cannot be undone.${NC}"
    echo ""
    read -p "Type 'DELETE' to confirm: " CONFIRM
    if [[ "$CONFIRM" != "DELETE" ]]; then
        warn "Aborted. No resources were deleted."
        exit 0
    fi
fi

# -----------------------------------------------------------
# Delete resource groups
# -----------------------------------------------------------
echo ""

if [[ "$RG_EXISTS" == true ]]; then
    log "Deleting resource group: $RG_NAME..."
    az group delete --name "$RG_NAME" --yes --no-wait
    ok "$RG_NAME deletion initiated (async)."
fi

if [[ "$RG_AI_EXISTS" == true ]]; then
    log "Deleting resource group: $RG_AI_NAME..."
    az group delete --name "$RG_AI_NAME" --yes --no-wait
    ok "$RG_AI_NAME deletion initiated (async)."
fi

# -----------------------------------------------------------
# Clean up local artifacts
# -----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/deployment_output.txt" ]]; then
    rm -f "$SCRIPT_DIR/deployment_output.txt"
    ok "Removed deployment_output.txt"
fi

if [[ -f "$SCRIPT_DIR/.env" ]]; then
    rm -f "$SCRIPT_DIR/.env"
    ok "Removed .env"
fi

# -----------------------------------------------------------
# Summary
# -----------------------------------------------------------
echo ""
echo "============================================================"
echo -e "  ${GREEN}Cleanup initiated.${NC}"
echo "============================================================"
echo ""
echo "  Resource group deletion runs asynchronously."
echo "  Monitor progress:"
echo ""
[[ "$RG_EXISTS" == true ]]    && echo "    az group show --name $RG_NAME --query properties.provisioningState -o tsv"
[[ "$RG_AI_EXISTS" == true ]] && echo "    az group show --name $RG_AI_NAME --query properties.provisioningState -o tsv"
echo ""
echo "  Full deletion typically takes 2-5 minutes."
echo ""
