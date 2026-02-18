#!/usr/bin/env bash
# =============================================================================
# start_remote.sh — Manage remote VM services via Azure CLI (az vm run-command)
# =============================================================================
#
# Uses 'az vm run-command invoke' to execute commands on the VM through the
# Azure management plane. No SSH or port 22 required.
#
# Automatically resolves VM details from deployment_output.txt or Azure CLI.
#
# Usage:
#   chmod +x start_remote.sh
#   ./start_remote.sh                     # Start all services
#   ./start_remote.sh --stop              # Stop all services
#   ./start_remote.sh --status            # Check service status
#   ./start_remote.sh --logs              # Show recent logs
#   ./start_remote.sh --restart           # Restart all services
#   ./start_remote.sh --rg myRG --vm myVM # Override resource group / VM name
#
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------
# ANSI colours
# -----------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERR ]${NC}  $*" >&2; }

# -----------------------------------------------------------
# Configuration
# -----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_FILE="$SCRIPT_DIR/deployment_output.txt"

RG_NAME="${RG_NAME:-rg-text2sql-workshop}"
VM_NAME="${VM_NAME:-vm-text2sql-frontend}"
VM_ADMIN="${VM_ADMIN:-azureuser}"
VM_IP=""
SQL_SERVER_NAME="${SQL_SERVER_NAME:-}"

REMOTE_APP_DIR="/home/$VM_ADMIN/text2sql"

# Ports (for summary display)
STREAMLIT_PORT=8501
MCP_HTTPS_PORT=8003
MCP_HTTP_PORT=8004

# -----------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------
ACTION="start"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stop|-s)       ACTION="stop";        shift ;;
        --status|-t)     ACTION="status";      shift ;;
        --logs|-l)       ACTION="logs";        shift ;;
        --mcp-logs)      ACTION="mcp-logs";    shift ;;
        --restart|-r)    ACTION="restart";     shift ;;
        --open-access)   ACTION="open-access"; shift ;;
        --rg)            RG_NAME="$2";     shift 2 ;;
        --vm)            VM_NAME="$2";     shift 2 ;;
        --help|-h)       ACTION="help";    shift ;;
        *)               err "Unknown option: $1"; exit 1 ;;
    esac
done

# -----------------------------------------------------------
# Step 1: Verify Azure CLI & resolve VM info
# -----------------------------------------------------------
check_az_cli() {
    if ! command -v az &>/dev/null; then
        err "Azure CLI (az) not found."
        err "  Install: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
        exit 1
    fi

    if ! az account show &>/dev/null 2>&1; then
        err "Not logged in to Azure CLI. Run: az login"
        exit 1
    fi

    ok "Azure CLI authenticated: $(az account show --query name -o tsv)"
}

resolve_vm_info() {
    echo ""
    log "Resolving VM info..."

    # Read from deployment_output.txt if available
    if [[ -f "$DEPLOYMENT_FILE" ]]; then
        local rg_from_file vm_from_file ip_from_file admin_from_file

        rg_from_file=$(grep -E '^RG_NAME=' "$DEPLOYMENT_FILE" | head -1 | cut -d'=' -f2 | tr -d '[:space:]')
        vm_from_file=$(grep -E '^VM_NAME=' "$DEPLOYMENT_FILE" | head -1 | cut -d'=' -f2 | tr -d '[:space:]')
        ip_from_file=$(grep -E '^VM_IP=' "$DEPLOYMENT_FILE" | head -1 | cut -d'=' -f2 | tr -d '[:space:]')
        admin_from_file=$(grep -E '^VM_ADMIN=' "$DEPLOYMENT_FILE" | head -1 | cut -d'=' -f2 | tr -d '[:space:]')
        sql_from_file=$(grep -E '^SQL_SERVER_NAME=' "$DEPLOYMENT_FILE" | head -1 | cut -d'=' -f2 | tr -d '[:space:]')

        # Only override if not set via CLI flags (defaults match template)
        [[ "$RG_NAME" == "rg-text2sql-workshop" && -n "$rg_from_file" ]] && RG_NAME="$rg_from_file"
        [[ "$VM_NAME" == "vm-text2sql-frontend" && -n "$vm_from_file" ]] && VM_NAME="$vm_from_file"
        [[ -n "$ip_from_file" ]] && VM_IP="$ip_from_file"
        [[ -n "$admin_from_file" ]] && VM_ADMIN="$admin_from_file"
        [[ -z "$SQL_SERVER_NAME" && -n "${sql_from_file:-}" ]] && SQL_SERVER_NAME="$sql_from_file"
        REMOTE_APP_DIR="/home/$VM_ADMIN/text2sql"

        ok "From deployment_output.txt:"
    fi

    # Get IP from Azure CLI if not resolved yet
    if [[ -z "$VM_IP" ]]; then
        VM_IP=$(az vm show -d \
            --resource-group "$RG_NAME" \
            --name "$VM_NAME" \
            --query publicIps -o tsv 2>/dev/null || echo "")
    fi

    # Verify VM exists
    local vm_state
    vm_state=$(az vm show -d \
        --resource-group "$RG_NAME" \
        --name "$VM_NAME" \
        --query powerState -o tsv 2>/dev/null || echo "")

    if [[ -z "$vm_state" ]]; then
        err "VM '$VM_NAME' not found in resource group '$RG_NAME'"
        err "  Check with: az vm list -g $RG_NAME -o table"
        exit 1
    fi

    echo -e "  Resource Group : ${CYAN}$RG_NAME${NC}"
    echo -e "  VM Name        : ${CYAN}$VM_NAME${NC}"
    echo -e "  VM IP          : ${CYAN}${VM_IP:-N/A}${NC}"
    echo -e "  VM State       : ${CYAN}$vm_state${NC}"
    echo ""

    if [[ "$vm_state" != "VM running" ]]; then
        err "VM is not running (state: $vm_state)"
        err "  Start it with: az vm start -g $RG_NAME -n $VM_NAME"
        exit 1
    fi

    ok "VM is running."
}

# -----------------------------------------------------------
# Step 2: Ensure public network access (SQL + NSG)
# -----------------------------------------------------------
ensure_public_access() {
    echo ""
    log "Ensuring public network access..."

    # --- Azure SQL: enable public network access ---
    if [[ -z "$SQL_SERVER_NAME" ]]; then
        # Try to discover SQL server from resource group
        SQL_SERVER_NAME=$(az sql server list \
            --resource-group "$RG_NAME" \
            --query "[0].name" -o tsv 2>/dev/null || echo "")
    fi

    if [[ -n "$SQL_SERVER_NAME" ]]; then
        local sql_public
        sql_public=$(az sql server show \
            --resource-group "$RG_NAME" \
            --name "$SQL_SERVER_NAME" \
            --query publicNetworkAccess -o tsv 2>/dev/null || echo "")

        if [[ "$sql_public" == "Disabled" ]]; then
            log "SQL Server '$SQL_SERVER_NAME' has public access disabled. Enabling..."
            az sql server update \
                --resource-group "$RG_NAME" \
                --name "$SQL_SERVER_NAME" \
                --enable-public-network true \
                -o none 2>/dev/null
            ok "SQL Server public network access enabled."
        else
            ok "SQL Server public network access: already enabled."
        fi
    else
        warn "No SQL Server found in $RG_NAME — skipping SQL public access check."
    fi

    # --- NSG: ensure service ports are open on subnet NSG ---
    local subnet_nsg
    subnet_nsg=$(az network nsg list \
        --resource-group "$RG_NAME" \
        --query "[?contains(name, 'Subnet')].name | [0]" -o tsv 2>/dev/null || echo "")

    if [[ -n "$subnet_nsg" ]]; then
        # Check if our allow rule already exists
        local rule_exists
        rule_exists=$(az network nsg rule show \
            --resource-group "$RG_NAME" \
            --nsg-name "$subnet_nsg" \
            --name AllowServicePorts \
            --query name -o tsv 2>/dev/null || echo "")

        if [[ -z "$rule_exists" ]]; then
            log "Opening ports $STREAMLIT_PORT, $MCP_HTTPS_PORT, $MCP_HTTP_PORT on subnet NSG..."
            az network nsg rule create \
                --resource-group "$RG_NAME" \
                --nsg-name "$subnet_nsg" \
                --name AllowServicePorts \
                --priority 120 \
                --direction Inbound \
                --access Allow \
                --protocol Tcp \
                --source-address-prefixes '*' \
                --source-port-ranges '*' \
                --destination-address-prefixes '*' \
                --destination-port-ranges $STREAMLIT_PORT $MCP_HTTPS_PORT $MCP_HTTP_PORT \
                -o none 2>/dev/null
            ok "Subnet NSG ports opened."
        else
            ok "Subnet NSG: AllowServicePorts rule already exists."
        fi
    else
        ok "No subnet-level NSG found — skipping."
    fi

    echo ""
}

# -----------------------------------------------------------
# Step 3: Run command on VM via az vm run-command invoke
# -----------------------------------------------------------
az_run() {
    local script="$1"
    local description="${2:-Running command}"

    log "$description..."

    local output
    output=$(az vm run-command invoke \
        --resource-group "$RG_NAME" \
        --name "$VM_NAME" \
        --command-id RunShellScript \
        --scripts "$script" \
        --query "value[0].message" \
        -o tsv 2>&1)

    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        err "Command failed (exit code $exit_code)"
        echo "$output"
        return 1
    fi

    echo "$output"
    return 0
}

# -----------------------------------------------------------
# Actions
# -----------------------------------------------------------
do_start() {
    ensure_public_access

    echo ""
    echo -e "${BOLD}============================================================${NC}"
    echo -e "${BOLD}  Starting Services on $VM_NAME${NC}"
    echo -e "${BOLD}============================================================${NC}"
    echo ""

    az_run "
        cd $REMOTE_APP_DIR && \
        source .env 2>/dev/null && \
        bash start_services.sh
    " "Starting Streamlit + MCP Server (HTTP & HTTPS)"

    echo ""
    echo -e "${BOLD}============================================================${NC}"
    echo -e "${GREEN}  Services started!${NC}"
    echo -e "${BOLD}============================================================${NC}"
    echo ""
    if [[ -n "$VM_IP" ]]; then
        echo -e "  Streamlit App  : ${CYAN}http://$VM_IP:$STREAMLIT_PORT${NC}"
        echo -e "  MCP (HTTPS)    : ${CYAN}https://$VM_IP:$MCP_HTTPS_PORT/mcp${NC}"
        echo -e "  MCP (HTTP)     : ${CYAN}http://$VM_IP:$MCP_HTTP_PORT/mcp${NC}"
    fi
    echo ""
}

do_stop() {
    echo ""
    log "Stopping services on $VM_NAME..."
    echo ""

    az_run "
        cd $REMOTE_APP_DIR && \
        bash start_services.sh --stop
    " "Stopping all services"

    echo ""
    ok "Services stopped."
}

do_restart() {
    ensure_public_access

    echo ""
    log "Restarting services on $VM_NAME..."
    echo ""

    az_run "
        cd $REMOTE_APP_DIR && \
        bash start_services.sh --stop && \
        sleep 2 && \
        source .env 2>/dev/null && \
        bash start_services.sh
    " "Restarting all services"

    echo ""
    ok "Services restarted."
    if [[ -n "$VM_IP" ]]; then
        echo ""
        echo -e "  Streamlit App  : ${CYAN}http://$VM_IP:$STREAMLIT_PORT${NC}"
        echo -e "  MCP (HTTPS)    : ${CYAN}https://$VM_IP:$MCP_HTTPS_PORT/mcp${NC}"
        echo -e "  MCP (HTTP)     : ${CYAN}http://$VM_IP:$MCP_HTTP_PORT/mcp${NC}"
    fi
}

do_status() {
    echo ""
    echo -e "${BOLD}  Service Status — $VM_NAME ($VM_IP)${NC}"
    echo -e "  ──────────────────────────────────────"
    echo ""

    az_run "
        echo '=== Process Check ==='
        echo ''
        echo 'Streamlit:'
        pgrep -fa streamlit && echo '  → RUNNING' || echo '  → NOT RUNNING'
        echo ''
        echo 'MCP Server (python server.py):'
        pgrep -fa 'python.*server.py' && echo '  → RUNNING' || echo '  → NOT RUNNING'
        echo ''
        echo '=== Port Check ==='
        echo ''
        for p in $STREAMLIT_PORT $MCP_HTTPS_PORT $MCP_HTTP_PORT; do
            if ss -tlnp | grep -q \":\$p \"; then
                echo \"  Port \$p — LISTENING\"
            else
                echo \"  Port \$p — NOT LISTENING\"
            fi
        done
        echo ''
        echo '=== Systemd Service ==='
        systemctl is-active text2sql.service 2>/dev/null && echo '  text2sql.service → ACTIVE' || echo '  text2sql.service → INACTIVE or not found'
        echo ''
        echo '=== Disk & Memory ==='
        echo ''
        df -h / | tail -1 | awk '{print \"  Disk: \" \$3 \" used / \" \$2 \" total (\" \$5 \")\"}'
        free -h | awk '/^Mem:/{print \"  Memory: \" \$3 \" used / \" \$2 \" total\"}'
        echo ''
        echo '=== Uptime ==='
        uptime
    " "Checking service status"
}

do_logs() {
    echo ""
    echo -e "${BOLD}  Recent Logs — $VM_NAME${NC}"
    echo -e "  ──────────────────────────────────────"
    echo ""

    az_run "
        echo '=== Streamlit Log (last 30 lines) ==='
        echo ''
        tail -30 $REMOTE_APP_DIR/logs/streamlit.log 2>/dev/null || echo '  (no log file found)'
        echo ''
        echo '=== MCP Server Log (last 30 lines) ==='
        echo ''
        tail -30 $REMOTE_APP_DIR/logs/mcp_server.log 2>/dev/null || echo '  (no log file found)'
        echo ''
        echo '=== Systemd Journal (last 20 lines) ==='
        echo ''
        journalctl -u text2sql.service --no-pager -n 20 2>/dev/null || echo '  (no journal entries)'
    " "Fetching recent logs"
}

do_mcp_logs() {
    echo ""
    echo -e "${BOLD}  MCP Access Logs — $VM_NAME${NC}"
    echo -e "  ──────────────────────────────────────"
    echo ""

    az_run "
        LOG_FILE=$REMOTE_APP_DIR/logs/mcp_access.log
        if [ ! -f \"\$LOG_FILE\" ]; then
            echo '  (no MCP access log file found)'
            echo '  Log file expected at: $REMOTE_APP_DIR/logs/mcp_access.log'
            exit 0
        fi

        TOTAL=\$(wc -l < \"\$LOG_FILE\")
        echo \"Total requests logged: \$TOTAL\"
        echo ''

        echo '=== Last 50 MCP Access Log Entries ==='
        echo ''
        tail -50 \"\$LOG_FILE\"
        echo ''

        echo '=== Request Summary (by RPC method) ==='
        echo ''
        grep -oP 'rpc=\\K[^ |]+' \"\$LOG_FILE\" | sort | uniq -c | sort -rn
        echo ''

        echo '=== Top 10 Client IPs ==='
        echo ''
        awk -F'|' '{print \$2}' \"\$LOG_FILE\" | awk -F: '{print \$1}' | sed 's/^ *//' | sort | uniq -c | sort -rn | head -10
        echo ''

        echo '=== Tool Usage (by tool name) ==='
        echo ''
        grep -oP 'tool=\\K[^ |]+' \"\$LOG_FILE\" | sort | uniq -c | sort -rn
    " "Fetching MCP access logs"
}

show_help() {
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Manage Text-to-SQL services on an Azure VM using 'az vm run-command invoke'."
    echo "No SSH or port 22 required — commands run via the Azure management plane."
    echo ""
    echo "Options:"
    echo "  (no args)       Start all services (Streamlit + MCP HTTP/HTTPS)"
    echo "  --stop          Stop all remote services"
    echo "  --status        Check process, port, disk, and memory status"
    echo "  --logs          Show recent service logs (last 30 lines)"
    echo "  --mcp-logs      Show MCP access logs with request summary"
    echo "  --restart       Stop + start all services"
    echo "  --open-access   Only ensure public access (SQL + NSG) without starting"
    echo "  --rg <NAME>     Override resource group (default: rg-text2sql-workshop)"
    echo "  --vm <NAME>     Override VM name (default: vm-text2sql-frontend)"
    echo "  --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Start services"
    echo "  $0 --status                           # Check if services are running"
    echo "  $0 --stop                             # Stop services"
    echo "  $0 --restart                          # Restart services"
    echo "  $0 --logs                             # View recent logs"
    echo "  $0 --mcp-logs                         # View MCP access logs + stats"
    echo "  $0 --rg myRG --vm myVM --status       # Custom RG/VM"
    echo ""
}

# -----------------------------------------------------------
# Main
# -----------------------------------------------------------
if [[ "$ACTION" == "help" ]]; then
    show_help
    exit 0
fi

check_az_cli
resolve_vm_info

case "$ACTION" in
    start)       do_start             ;;
    stop)        do_stop              ;;
    status)      do_status            ;;
    logs)        do_logs              ;;
    mcp-logs)    do_mcp_logs          ;;
    restart)     do_restart           ;;
    open-access) ensure_public_access ;;
esac
