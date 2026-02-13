# Stage 4 — MCP Server (Model Context Protocol)

## Overview

Stage 4 exposes the Text-to-SQL agent as a **Model Context Protocol (MCP)** server
using **Streamable HTTP** transport. This enables **Microsoft Copilot Studio** to
discover and invoke the agent's tools automatically.

| Layer | Port | Protocol | Purpose |
|-------|------|----------|---------|
| Streamlit | 8501 | HTTP | Chat UI (Stage 1) |
| FastAPI | 8000 | REST | Copilot Studio connector (Stage 2) |
| A2A | 8002 | JSON-RPC | Agent-to-Agent (Stage 3) |
| **MCP** | **8003** | **MCP/Streamable HTTP** | **Copilot Studio MCP (Stage 4)** |

## Architecture

```
┌──────────────────────┐      MCP Streamable HTTP       ┌─────────────────────┐
│  Microsoft Copilot   │  ────────────────────────────►  │    MCP Server       │
│  Studio              │  POST /mcp (JSON-RPC 2.0)      │    (port 8003)      │
│                      │  ◄────────────────────────────  │                     │
└──────────────────────┘      JSON / SSE responses       │  ┌───────────────┐  │
                                                         │  │  agent.py     │  │
                                                         │  │  ┌─────────┐  │  │
                                                         │  │  │ GPT-4o  │  │  │
                                                         │  │  │Azure SQL│  │  │
                                                         │  │  └─────────┘  │  │
                                                         │  └───────────────┘  │
                                                         └─────────────────────┘
```

## What is MCP?

The **Model Context Protocol** (MCP) is an open standard for connecting AI models
to external data sources and tools. Key concepts:

- **Tools** — Functions the AI can call (like `ask_database`, `run_sql_query`)
- **Resources** — Data the AI can read (like the database schema)
- **Transports** — How client/server communicate (Streamable HTTP for remote servers)
- **JSON-RPC 2.0** — The wire protocol for all MCP messages

MCP lifecycle:
1. **Initialize** — Client sends capabilities, server responds with its capabilities
2. **tools/list** — Client discovers available tools
3. **tools/call** — Client invokes a tool with arguments
4. **resources/list** — Client discovers available resources

## MCP Tools Exposed

| Tool | Description | Arguments |
|------|-------------|-----------|
| `ask_database` | Full NL-to-SQL pipeline: question → SQL → execute → answer | `question` (string) |
| `get_database_schema` | Returns complete database schema | *(none)* |
| `run_sql_query` | Execute a raw T-SQL SELECT query | `sql_query` (string) |

## Prerequisites

- Stage 1 deployed (VM, Azure SQL, Azure OpenAI)
- Azure CLI logged in (`az login`)

## Deploy

```bash
chmod +x deploy_stage4.sh
./deploy_stage4.sh
```

## Test with curl

### 1. Initialize (MCP handshake)

```bash
curl -X POST http://<VM_IP>:8003/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2025-03-26",
      "capabilities": {},
      "clientInfo": {"name": "test-client", "version": "1.0"}
    }
  }'
```

Expected response:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-03-26",
    "capabilities": { "tools": {} },
    "serverInfo": { "name": "Text2SQL Database Assistant", "version": "..." }
  }
}
```

### 2. List tools

```bash
curl -X POST http://<VM_IP>:8003/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}'
```

### 3. Call a tool

```bash
curl -X POST http://<VM_IP>:8003/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "ask_database",
      "arguments": {"question": "How many products are there?"}
    }
  }'
```

## Connect from Microsoft Copilot Studio

### Option 1: MCP Onboarding Wizard (Recommended)

1. Open your agent in **Copilot Studio**
2. Go to **Tools** → **Add a tool** → **New tool**
3. Select **Model Context Protocol**
4. Fill in:
   - **Server name**: `Text2SQL Database`
   - **Server description**: `Queries the SalesDB database using natural language. Has tools to ask questions, view schema, and run SQL queries.`
   - **Server URL**: `http://<VM_IP>:8003/mcp`
5. **Authentication**: Select `None` (or `API Key` with header name `X-API-Key`)
6. Click **Create** → **Add to agent**

Copilot Studio automatically discovers the tools via MCP protocol negotiation.

### Option 2: Custom Connector (OpenAPI)

Create an OpenAPI schema for the MCP server:

```yaml
swagger: '2.0'
info:
  title: Text2SQL MCP Server
  description: MCP server for natural language database queries
  version: 1.0.0
host: <VM_IP>:8003
basePath: /
schemes:
  - http
paths:
  /mcp:
    post:
      summary: Text2SQL Database Assistant
      x-ms-agentic-protocol: mcp-streamable-1.0
      operationId: InvokeMCP
      responses:
        '200':
          description: Success
```

1. Go to **Tools** → **Add a tool** → **New tool** → **Custom connector**
2. Import the OpenAPI YAML above
3. Complete setup in Power Apps

## Key Differences: MCP vs A2A vs REST

| Feature | REST API (Stage 2) | A2A (Stage 3) | MCP (Stage 4) |
|---------|-------------------|---------------|----------------|
| Protocol | HTTP REST | JSON-RPC (A2A spec) | JSON-RPC (MCP spec) |
| Discovery | OpenAPI/Swagger | Agent Card | `initialize` + `tools/list` |
| Invocation | `POST /api/ask` | `tasks/send` | `tools/call` |
| Streaming | No | SSE (optional) | SSE (Streamable HTTP) |
| Tool Schema | Manual OpenAPI | Agent Skills | Auto from Python types |
| Copilot Studio | Custom connector | Not supported | **Native MCP support** |
| Best For | Traditional APIs | Agent-to-agent | AI platform integration |

## Files

| File | Description |
|------|-------------|
| `mcp_server/server.py` | MCP server with tools (FastMCP + Streamable HTTP) |
| `deploy_stage4.sh` | Automated deployment script |
| `WORKSHOP_STAGE4_MCP.md` | This documentation |

## Troubleshooting

### Service not starting
```bash
# Check logs
sudo journalctl -u text2sql-mcp -f

# Restart
sudo systemctl restart text2sql-mcp
```

### Port not reachable
```bash
# Check NSG rule exists
az network nsg rule list --resource-group rg-text2sql-workshop \
  --nsg-name <NSG_NAME> --query "[?name=='AllowMCP']" -o table

# Check service is listening
sudo ss -tlnp | grep 8003
```

### MCP errors
```bash
# Test initialize
curl -v -X POST http://<VM_IP>:8003/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```
