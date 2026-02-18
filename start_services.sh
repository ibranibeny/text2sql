#!/usr/bin/env bash
# =============================================================================
# start_services.sh — Start Streamlit + MCP Server (HTTP & HTTPS)
# =============================================================================
#
# Starts all three services:
#   1. Streamlit app        → http://0.0.0.0:8501
#   2. MCP Server (HTTPS)   → https://0.0.0.0:8003/mcp
#   3. MCP Server (HTTP)    → http://0.0.0.0:8004/mcp
#
# Usage:
#   chmod +x start_services.sh
#   ./start_services.sh              # Start all services
#   ./start_services.sh --stop       # Stop all services
#   ./start_services.sh --status     # Check service status
#   ./start_services.sh --logs       # Tail all logs
#
# Prerequisites:
#   - Python venv with dependencies installed
#   - .env file configured (see .env.template)
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
APP_DIR="$SCRIPT_DIR/app"
MCP_DIR="$SCRIPT_DIR/mcp_server"
LOG_DIR="$SCRIPT_DIR/logs"
PID_DIR="$SCRIPT_DIR/.pids"

STREAMLIT_PORT="${STREAMLIT_PORT:-8501}"
MCP_HTTPS_PORT="${MCP_PORT:-8003}"
MCP_HTTP_PORT="${MCP_HTTP_PORT:-8004}"

# Detect Python / venv
if [[ -d "$SCRIPT_DIR/venv" ]]; then
    PYTHON="$SCRIPT_DIR/venv/bin/python"
    STREAMLIT="$SCRIPT_DIR/venv/bin/streamlit"
elif [[ -d "$SCRIPT_DIR/.venv" ]]; then
    PYTHON="$SCRIPT_DIR/.venv/bin/python"
    STREAMLIT="$SCRIPT_DIR/.venv/bin/streamlit"
else
    PYTHON="$(command -v python3 || command -v python)"
    STREAMLIT="$(command -v streamlit)"
fi

# -----------------------------------------------------------
# Helper functions
# -----------------------------------------------------------
ensure_dirs() {
    mkdir -p "$LOG_DIR" "$PID_DIR"
}

is_running() {
    local pidfile="$PID_DIR/$1.pid"
    if [[ -f "$pidfile" ]]; then
        local pid
        pid=$(cat "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$pidfile"
    fi
    return 1
}

get_pid() {
    local pidfile="$PID_DIR/$1.pid"
    [[ -f "$pidfile" ]] && cat "$pidfile" || echo ""
}

wait_for_port() {
    local port=$1
    local name=$2
    local max_wait=15
    local elapsed=0
    while ! (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [[ $elapsed -ge $max_wait ]]; then
            warn "$name did not start on port $port within ${max_wait}s"
            return 1
        fi
    done
    return 0
}

# -----------------------------------------------------------
# Start services
# -----------------------------------------------------------
start_streamlit() {
    if is_running "streamlit"; then
        warn "Streamlit is already running (PID $(get_pid streamlit))"
        return
    fi

    log "Starting Streamlit on port $STREAMLIT_PORT..."
    cd "$APP_DIR"
    nohup "$STREAMLIT" run app.py \
        --server.port="$STREAMLIT_PORT" \
        --server.headless=true \
        --server.address=0.0.0.0 \
        > "$LOG_DIR/streamlit.log" 2>&1 &
    echo $! > "$PID_DIR/streamlit.pid"
    cd "$SCRIPT_DIR"

    if wait_for_port "$STREAMLIT_PORT" "Streamlit"; then
        ok "Streamlit started (PID $(get_pid streamlit)) → http://0.0.0.0:$STREAMLIT_PORT"
    fi
}

start_mcp_server() {
    if is_running "mcp_server"; then
        warn "MCP Server is already running (PID $(get_pid mcp_server))"
        return
    fi

    log "Starting MCP Server..."
    log "  HTTPS → port $MCP_HTTPS_PORT"
    log "  HTTP  → port $MCP_HTTP_PORT"

    cd "$MCP_DIR"
    MCP_PORT="$MCP_HTTPS_PORT" \
    MCP_HTTP_PORT="$MCP_HTTP_PORT" \
    MCP_ENABLE_HTTPS="true" \
    nohup "$PYTHON" server.py \
        > "$LOG_DIR/mcp_server.log" 2>&1 &
    echo $! > "$PID_DIR/mcp_server.pid"
    cd "$SCRIPT_DIR"

    if wait_for_port "$MCP_HTTP_PORT" "MCP HTTP"; then
        ok "MCP HTTP  started → http://0.0.0.0:$MCP_HTTP_PORT/mcp"
    fi
    if wait_for_port "$MCP_HTTPS_PORT" "MCP HTTPS"; then
        ok "MCP HTTPS started → https://0.0.0.0:$MCP_HTTPS_PORT/mcp"
    fi
    ok "MCP Server PID: $(get_pid mcp_server)"
}

start_all() {
    echo ""
    echo -e "${BOLD}============================================================${NC}"
    echo -e "${BOLD}  Text-to-SQL — Starting All Services${NC}"
    echo -e "${BOLD}============================================================${NC}"
    echo ""

    ensure_dirs

    # Verify .env exists
    if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
        err ".env file not found! Copy .env.template to .env and configure it."
        exit 1
    fi

    # Export .env for child processes
    set -a
    source "$SCRIPT_DIR/.env"
    set +a

    start_streamlit
    start_mcp_server

    echo ""
    echo -e "${BOLD}============================================================${NC}"
    echo -e "${GREEN}  All services started!${NC}"
    echo -e "${BOLD}============================================================${NC}"
    echo ""
    echo -e "  Streamlit App  : ${CYAN}http://0.0.0.0:$STREAMLIT_PORT${NC}"
    echo -e "  MCP (HTTPS)    : ${CYAN}https://0.0.0.0:$MCP_HTTPS_PORT/mcp${NC}"
    echo -e "  MCP (HTTP)     : ${CYAN}http://0.0.0.0:$MCP_HTTP_PORT/mcp${NC}"
    echo ""
    echo -e "  Logs           : ${YELLOW}$LOG_DIR/${NC}"
    echo -e "  Stop           : ${YELLOW}$0 --stop${NC}"
    echo -e "  Status         : ${YELLOW}$0 --status${NC}"
    echo ""
}

# -----------------------------------------------------------
# Stop services
# -----------------------------------------------------------
stop_service() {
    local name=$1
    if is_running "$name"; then
        local pid
        pid=$(get_pid "$name")
        log "Stopping $name (PID $pid)..."
        kill "$pid" 2>/dev/null || true
        # Wait for graceful shutdown
        local waited=0
        while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 10 ]]; do
            sleep 1
            waited=$((waited + 1))
        done
        # Force kill if still running
        if kill -0 "$pid" 2>/dev/null; then
            warn "$name did not stop gracefully, sending SIGKILL..."
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$PID_DIR/$name.pid"
        ok "$name stopped."
    else
        warn "$name is not running."
    fi
}

stop_all() {
    echo ""
    echo -e "${BOLD}  Stopping All Services${NC}"
    echo ""
    stop_service "streamlit"
    stop_service "mcp_server"
    echo ""
    ok "All services stopped."
}

# -----------------------------------------------------------
# Status
# -----------------------------------------------------------
show_status() {
    echo ""
    echo -e "${BOLD}  Service Status${NC}"
    echo -e "  ──────────────────────────────────────"

    for svc in streamlit mcp_server; do
        if is_running "$svc"; then
            echo -e "  ${GREEN}●${NC} $svc  (PID $(get_pid $svc))"
        else
            echo -e "  ${RED}●${NC} $svc  (stopped)"
        fi
    done

    echo ""

    # Port check
    for port_info in "$STREAMLIT_PORT:Streamlit" "$MCP_HTTPS_PORT:MCP-HTTPS" "$MCP_HTTP_PORT:MCP-HTTP"; do
        local port="${port_info%%:*}"
        local label="${port_info##*:}"
        if (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null; then
            echo -e "  ${GREEN}●${NC} Port $port ($label) — listening"
        else
            echo -e "  ${RED}●${NC} Port $port ($label) — not listening"
        fi
    done
    echo ""
}

# -----------------------------------------------------------
# Logs
# -----------------------------------------------------------
tail_logs() {
    log "Tailing all logs (Ctrl+C to stop)..."
    echo ""
    tail -f "$LOG_DIR"/streamlit.log "$LOG_DIR"/mcp_server.log 2>/dev/null
}

# -----------------------------------------------------------
# Main
# -----------------------------------------------------------
case "${1:-}" in
    --stop|-s)
        stop_all
        ;;
    --status|-t)
        show_status
        ;;
    --logs|-l)
        tail_logs
        ;;
    --help|-h)
        echo "Usage: $0 [--stop|--status|--logs|--help]"
        echo ""
        echo "  (no args)   Start all services (Streamlit + MCP HTTP/HTTPS)"
        echo "  --stop      Stop all running services"
        echo "  --status    Show service and port status"
        echo "  --logs      Tail all service logs"
        echo "  --help      Show this help message"
        ;;
    *)
        start_all
        ;;
esac
