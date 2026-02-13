# Stage 3 — Agent-to-Agent (A2A) Protocol Server × Text-to-SQL

## Agentic AI Workshop: Exposing the Text-to-SQL Agent via A2A for GitHub Copilot

| Property | Value |
|---|---|
| **Document Version** | 1.0 |
| **Last Updated** | 2026-02-13 |
| **Author** | Workshop Facilitator |
| **Stage** | 3 of 3 |
| **Prerequisite** | Stage 1 (Streamlit frontend) completed |
| **Estimated Duration** | 60 minutes |

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Phase 1 — Understand the A2A Protocol](#4-phase-1--understand-the-a2a-protocol)
5. [Phase 2 — Build the A2A Server](#5-phase-2--build-the-a2a-server)
6. [Phase 3 — Deploy to Azure VM](#6-phase-3--deploy-to-azure-vm)
7. [Phase 4 — Test the A2A Server](#7-phase-4--test-the-a2a-server)
8. [Phase 5 — Connect GitHub Copilot via A2A](#8-phase-5--connect-github-copilot-via-a2a)
9. [Phase 6 — Test End-to-End](#9-phase-6--test-end-to-end)
10. [Phase 7 — Cleanup](#10-phase-7--cleanup)
11. [Troubleshooting](#11-troubleshooting)
12. [References](#12-references)

---

## 1. Overview

### 1.1 Purpose

Stage 1 deployed a Streamlit web app. Stage 2 added a FastAPI REST API for Copilot Studio integration. **Stage 3** exposes the same Text-to-SQL pipeline as an **Agent-to-Agent (A2A) protocol** server, enabling AI agents like **GitHub Copilot** to discover and communicate with it directly.

The A2A protocol (developed by Google) provides a standardized way for AI agents to:
- **Discover** other agents and their capabilities
- **Send tasks** to remote agents
- **Receive results** in a structured format
- **Manage task lifecycle** (create, query, cancel)

This means GitHub Copilot can autonomously find your Text-to-SQL agent, understand what it can do, and delegate database questions to it — all through a standard protocol.

### 1.2 What Changes from Stage 2

| Component | Stage 2 | Stage 3 |
|---|---|---|
| **Protocol** | REST API (OpenAPI v2) | A2A (JSON-RPC 2.0) |
| **Discovery** | Manual OpenAPI spec upload | Automatic via `/.well-known/agent.json` |
| **Client** | Copilot Studio | GitHub Copilot / any A2A agent |
| **Communication** | HTTP REST (JSON) | JSON-RPC 2.0 over HTTP |
| **Task model** | Stateless request/response | Stateful task lifecycle |
| **Port** | 8000 | 8002 |

### 1.3 What Stays the Same

- Azure SQL Database (SalesDB) with the same sample data
- Azure AI Services (GPT-4o) with Entra ID / Managed Identity
- Azure VM (Ubuntu 22.04) in Indonesia Central
- `agent.py` — Dynamic schema discovery + two-stage LLM pipeline
- Streamlit (port 8501) and FastAPI (port 8000) continue running

---

## 2. Architecture

```
                         ┌─────────────────────────────┐
                         │   GitHub Copilot (VS Code)   │
                         │                              │
                         │  1. GET /.well-known/         │
                         │     agent.json                │
                         │     (discover capabilities)   │
                         │                              │
                         │  2. POST / (JSON-RPC)         │
                         │     tasks/send                │
                         │     "Show top 5 customers"    │
                         │                              │
                         │  3. Receive task result        │
                         │     with answer + SQL + data   │
                         └──────────────┬───────────────┘
                                        │ A2A Protocol
                                        │ (JSON-RPC 2.0)
                                        ▼
┌──────────────────────────────────────────────────────────┐
│              Azure VM (Indonesia Central)                 │
│                                                          │
│  ┌────────────────────┐  ┌──────────────┐  ┌──────────┐ │
│  │ A2A Agent Server   │  │  FastAPI API  │  │Streamlit │ │
│  │ Port 8002          │  │  Port 8000    │  │Port 8501 │ │
│  │                    │  │  (Stage 2)    │  │(Stage 1) │ │
│  │ /.well-known/      │  │              │  │          │ │
│  │   agent.json       │  │  POST /api/   │  │          │ │
│  │                    │  │    ask        │  │          │ │
│  │ POST /             │  │              │  │          │ │
│  │  tasks/send        │  │              │  │          │ │
│  │  tasks/get         │  │              │  │          │ │
│  │  tasks/cancel      │  │              │  │          │ │
│  └────────┬───────────┘  └──────┬───────┘  └────┬─────┘ │
│           │                     │                │       │
│           └─────────┬───────────┘                │       │
│                     ▼                            │       │
│           ┌──────────────────┐                   │       │
│           │    agent.py      │◄──────────────────┘       │
│           │ (Text-to-SQL     │                           │
│           │  Pipeline)       │                           │
│           └────────┬─────────┘                           │
│                    │                                     │
└────────────────────┼─────────────────────────────────────┘
                     │
          ┌──────────┘──────────┐
          ▼                     ▼
┌───────────────────┐ ┌──────────────────────┐
│  Azure SQL        │ │  Azure AI Services   │
│  (SalesDB)        │ │  (GPT-4o)            │
│  Indonesia Central│ │  East US             │
└───────────────────┘ └──────────────────────┘
```

---

## 3. Prerequisites

### 3.1 Stage 1 Must Be Completed

The following resources from Stage 1 must exist:

| Resource | Resource Group | Purpose |
|---|---|---|
| `vm-text2sql-frontend` | `rg-text2sql-workshop` | Hosts the A2A server |
| `sql-text2sql-*` | `rg-text2sql-workshop` | Azure SQL with SalesDB |
| `ai-text2sql-*` | `rg-text2sql-ai` | Azure AI Services (GPT-4o) |

### 3.2 Tools

- Azure CLI (`az`) installed and logged in
- VS Code with GitHub Copilot extension
- `curl` for testing

---

## 4. Phase 1 — Understand the A2A Protocol

### 4.1 What Is A2A?

The **Agent-to-Agent (A2A)** protocol is an open standard that enables AI agents to communicate with each other. It defines:

1. **Agent Card** — A JSON document at `/.well-known/agent.json` that describes the agent (name, description, capabilities, skills)
2. **JSON-RPC 2.0** — The transport protocol for task management
3. **Task Lifecycle** — A state machine: `submitted` → `working` → `completed`/`failed`/`canceled`

### 4.2 A2A vs REST API (Stage 2)

| Aspect | REST API (Stage 2) | A2A (Stage 3) |
|---|---|---|
| **Discovery** | Manual (upload OpenAPI spec) | Automatic (`/.well-known/agent.json`) |
| **Protocol** | REST (HTTP verbs + URL paths) | JSON-RPC 2.0 (single POST endpoint) |
| **Task state** | Stateless | Stateful (task lifecycle) |
| **Interop** | Any HTTP client | Any A2A-compatible agent |
| **Schema** | OpenAPI v2/v3 | Agent Card (custom JSON) |
| **Auth** | API Key header | API Key header (same) |

### 4.3 A2A Protocol Flow

```
Client (GitHub Copilot)                 Server (Text-to-SQL Agent)
        │                                          │
        │── GET /.well-known/agent.json ──────────►│
        │◄─────────── Agent Card (JSON) ───────────│
        │                                          │
        │── POST / ───────────────────────────────►│
        │   {                                      │
        │     "jsonrpc": "2.0",                    │
        │     "method": "tasks/send",              │
        │     "params": {                          │
        │       "id": "task-123",                  │
        │       "message": {                       │
        │         "role": "user",                  │
        │         "parts": [{"type":"text",        │
        │           "text":"Top 5 customers"}]     │
        │       }                                  │
        │     }                                    │
        │   }                                      │
        │                                          │
        │◄─── JSON-RPC Response ───────────────────│
        │   {                                      │
        │     "result": {                          │
        │       "id": "task-123",                  │
        │       "status": {"state":"completed"},   │
        │       "artifacts": [...]                 │
        │     }                                    │
        │   }                                      │
        │                                          │
```

> **Reference**: A2A Protocol Specification — https://google.github.io/A2A/

---

## 5. Phase 2 — Build the A2A Server

### 5.1 File Structure

Stage 3 adds three files in the `a2a/` directory:

```
a2a/
├── models.py      # A2A protocol data models (Pydantic)
├── handler.py     # Task handler — bridges A2A ↔ agent.py
└── server.py      # FastAPI server implementing A2A protocol
```

### 5.2 File: `a2a/models.py` — Protocol Data Models

This file defines all A2A protocol data models using Pydantic:

| Model | Purpose |
|---|---|
| `AgentCard` | Agent discovery document |
| `AgentSkill` | A capability the agent advertises |
| `Task` | A unit of work with lifecycle state |
| `Message` | A message with typed parts (text, data, file) |
| `Artifact` | An output produced by the agent |
| `JSONRPCRequest/Response` | JSON-RPC 2.0 envelope |

### 5.3 File: `a2a/handler.py` — Task Handler

The handler bridges A2A tasks with the existing `agent.py` pipeline:

1. **`handle_task_send()`** — Receives a user message, extracts the question text, calls `agent.process_question()`, and returns the result as a completed task with artifacts
2. **`handle_task_get()`** — Retrieves a task by ID from the in-memory store
3. **`handle_task_cancel()`** — Cancels a task if it's still in submitted/working state

Task results include two artifacts:
- **Artifact 0** (`answer`) — The natural language answer (text)
- **Artifact 1** (`query_result`) — Structured data with SQL, columns, rows

### 5.4 File: `a2a/server.py` — FastAPI A2A Server

The main server exposes:

| Endpoint | Method | Purpose |
|---|---|---|
| `/.well-known/agent.json` | GET | Agent Card for discovery |
| `/` | POST | JSON-RPC 2.0 endpoint for `tasks/send`, `tasks/get`, `tasks/cancel` |
| `/health` | GET | Health check |
| `/docs` | GET | Swagger UI |

### 5.5 Agent Card

The Agent Card at `/.well-known/agent.json` advertises:

```json
{
  "name": "Text-to-SQL Agent",
  "description": "An agentic AI agent that converts natural language questions...",
  "url": "http://<VM_IP>:8002",
  "version": "3.0.0",
  "capabilities": {
    "streaming": false,
    "pushNotifications": false,
    "stateTransitionHistory": true
  },
  "skills": [
    {
      "id": "text-to-sql",
      "name": "Text-to-SQL Query",
      "description": "Converts natural language questions into T-SQL queries...",
      "tags": ["sql", "database", "analytics", "sales"],
      "examples": [
        "Show me the top 5 customers by total spending",
        "What is the total revenue by product category?"
      ]
    },
    {
      "id": "schema-discovery",
      "name": "Database Schema Discovery",
      "description": "Returns the database schema..."
    }
  ]
}
```

---

## 6. Phase 3 — Deploy to Azure VM

### 6.1 Option A: Automated Deployment (Recommended)

```bash
chmod +x deploy_stage3.sh
./deploy_stage3.sh
```

The script performs:
1. Verifies Stage 1 resources exist
2. Uploads `a2a/models.py`, `a2a/handler.py`, `a2a/server.py` to the VM
3. Creates symlinks so `handler.py` can import `agent.py`
4. Installs FastAPI + Pydantic in the existing venv
5. Adds A2A config to `.env` (port, host URL)
6. Creates `text2sql-a2a` systemd service on port 8002
7. Opens port 8002 on the NSG
8. Verifies the health and agent card endpoints

### 6.2 Option B: Manual Deployment

#### Step 1 — Upload files to the VM

```bash
VM_IP=$(az vm show -g rg-text2sql-workshop -n vm-text2sql-frontend \
    --show-details --query publicIps -o tsv)

ssh azureuser@${VM_IP} "mkdir -p /home/azureuser/text2sql/a2a"

scp a2a/models.py a2a/handler.py a2a/server.py \
    azureuser@${VM_IP}:/home/azureuser/text2sql/a2a/
```

#### Step 2 — Create symlinks

```bash
ssh azureuser@${VM_IP} << 'EOF'
cd /home/azureuser/text2sql/a2a
ln -sf ../agent.py agent.py
ln -sf ../.env .env
EOF
```

#### Step 3 — Install dependencies

```bash
ssh azureuser@${VM_IP} << 'EOF'
cd /home/azureuser/text2sql
source venv/bin/activate
pip install fastapi uvicorn[standard] pydantic
EOF
```

#### Step 4 — Add A2A config to .env

```bash
ssh azureuser@${VM_IP} << EOF
echo "A2A_PORT=8002" >> /home/azureuser/text2sql/.env
echo "A2A_HOST_URL=http://${VM_IP}:8002" >> /home/azureuser/text2sql/.env
EOF
```

#### Step 5 — Create systemd service

```bash
ssh azureuser@${VM_IP} << 'EOF'
sudo tee /etc/systemd/system/text2sql-a2a.service > /dev/null << 'UNIT'
[Unit]
Description=Text2SQL A2A Agent Server
After=network.target

[Service]
Type=simple
User=azureuser
WorkingDirectory=/home/azureuser/text2sql/a2a
EnvironmentFile=/home/azureuser/text2sql/.env
ExecStart=/home/azureuser/text2sql/venv/bin/uvicorn server:app --host=0.0.0.0 --port=8002
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable text2sql-a2a
sudo systemctl start text2sql-a2a
EOF
```

#### Step 6 — Open port 8002 on NSG

```bash
az network nsg rule create \
    --resource-group rg-text2sql-workshop \
    --nsg-name nsg-text2sql \
    --name AllowA2A \
    --priority 1030 \
    --destination-port-ranges 8002 \
    --access Allow \
    --protocol Tcp \
    --direction Inbound
```

---

## 7. Phase 4 — Test the A2A Server

### 7.1 Health Check

```bash
curl http://${VM_IP}:8002/health | python3 -m json.tool
```

Expected:
```json
{
    "status": "healthy",
    "service": "text2sql-a2a-agent",
    "version": "3.0.0",
    "protocol": "A2A"
}
```

### 7.2 Agent Card Discovery

```bash
curl http://${VM_IP}:8002/.well-known/agent.json | python3 -m json.tool
```

Verify the response contains:
- `name`: "Text-to-SQL Agent"
- `skills`: 2 skills listed
- `url`: matches your VM IP

### 7.3 Send a Task (tasks/send)

```bash
curl -X POST http://${VM_IP}:8002/ \
  -H "Content-Type: application/json" \
  -H "X-API-Key: YOUR_API_KEY" \
  -d '{
    "jsonrpc": "2.0",
    "id": "1",
    "method": "tasks/send",
    "params": {
      "id": "test-task-1",
      "message": {
        "role": "user",
        "parts": [{"type": "text", "text": "Show me the top 5 customers by total order amount"}]
      }
    }
  }' | python3 -m json.tool
```

Expected response structure:
```json
{
    "jsonrpc": "2.0",
    "id": "1",
    "result": {
        "id": "test-task-1",
        "status": {
            "state": "completed",
            "message": {
                "role": "agent",
                "parts": [{"type": "text", "text": "Here are the top 5 customers..."}]
            }
        },
        "artifacts": [
            {
                "name": "answer",
                "parts": [{"type": "text", "text": "Here are the top 5 customers..."}]
            },
            {
                "name": "query_result",
                "parts": [{"type": "data", "data": {"sql": "SELECT TOP 5...", "rows": [...]}}]
            }
        ]
    }
}
```

### 7.4 Query a Task (tasks/get)

```bash
curl -X POST http://${VM_IP}:8002/ \
  -H "Content-Type: application/json" \
  -H "X-API-Key: YOUR_API_KEY" \
  -d '{
    "jsonrpc": "2.0",
    "id": "2",
    "method": "tasks/get",
    "params": {
      "id": "test-task-1"
    }
  }' | python3 -m json.tool
```

### 7.5 Cancel a Task (tasks/cancel)

```bash
curl -X POST http://${VM_IP}:8002/ \
  -H "Content-Type: application/json" \
  -H "X-API-Key: YOUR_API_KEY" \
  -d '{
    "jsonrpc": "2.0",
    "id": "3",
    "method": "tasks/cancel",
    "params": {
      "id": "test-task-1"
    }
  }' | python3 -m json.tool
```

---

## 8. Phase 5 — Connect GitHub Copilot via A2A

### 8.1 Configure VS Code

Add the A2A agent to your VS Code settings to allow GitHub Copilot to discover and use it:

1. Open VS Code Settings (`Ctrl+,`)
2. Open `settings.json` (click the `{}` icon)
3. Add the following configuration:

```json
{
  "github.copilot.chat.agents": {
    "text2sql": {
      "url": "http://<VM_IP>:8002"
    }
  }
}
```

Replace `<VM_IP>` with your actual VM public IP address.

### 8.2 Using the Agent in Copilot Chat

Once configured, you can invoke the Text-to-SQL agent in GitHub Copilot Chat:

1. Open the **Copilot Chat** panel in VS Code (`Ctrl+Shift+I`)
2. Type `@text2sql` followed by your question:

```
@text2sql Show me the top 5 customers by total spending
```

```
@text2sql What is the total revenue by product category?
```

```
@text2sql Which orders are still being processed?
```

Copilot will:
1. Discover the agent's capabilities via the Agent Card
2. Send a `tasks/send` JSON-RPC request with your question
3. Display the natural language answer in the chat

### 8.3 How It Works Under the Hood

```
┌────────────────────────────────────────────────────────────┐
│ VS Code + GitHub Copilot                                   │
│                                                            │
│  User types: @text2sql Show me top 5 customers             │
│                                                            │
│  1. Copilot reads /.well-known/agent.json                  │
│     → Discovers "Text-to-SQL Agent" with skills            │
│                                                            │
│  2. Copilot sends JSON-RPC to POST /                       │
│     → method: "tasks/send"                                 │
│     → message: "Show me top 5 customers"                   │
│                                                            │
│  3. A2A server calls agent.process_question()              │
│     → generate_sql() → execute_sql() → synthesize()        │
│                                                            │
│  4. Task result returned with artifacts                    │
│     → Artifact 0: Natural language answer                  │
│     → Artifact 1: SQL + raw data                           │
│                                                            │
│  5. Copilot displays the answer in chat                    │
└────────────────────────────────────────────────────────────┘
```

---

## 9. Phase 6 — Test End-to-End

### 9.1 Test Scenarios

| # | Copilot Chat Input | Expected Behavior |
|---|---|---|
| 1 | `@text2sql Show me all electronics products` | Returns product list with prices in IDR |
| 2 | `@text2sql Who are the top 3 customers by order amount?` | Returns customer ranking |
| 3 | `@text2sql How many orders are still processing?` | Returns count of processing orders |
| 4 | `@text2sql What is the total revenue by product category?` | Returns aggregated revenue |
| 5 | `@text2sql Show me orders from Jakarta customers` | Returns filtered orders |
| 6 | `@text2sql What tables are in the database?` | Returns schema information |

### 9.2 Compare All Three Stages

| Aspect | Stage 1 (Streamlit) | Stage 2 (Copilot Studio) | Stage 3 (A2A) |
|---|---|---|---|
| **Frontend** | Streamlit web app | Copilot Studio | GitHub Copilot |
| **Protocol** | In-process | REST API (OpenAPI) | A2A (JSON-RPC) |
| **Discovery** | N/A | Manual spec upload | Automatic Agent Card |
| **Port** | 8501 | 8000 | 8002 |
| **Auth** | None | API Key | API Key |
| **State** | Session-based | Stateless | Stateful (tasks) |
| **Interop** | Browser only | Copilot Studio only | Any A2A agent |
| **Developer UX** | Web browser | Teams/Web | VS Code IDE |

---

## 10. Phase 7 — Cleanup

### 10.1 Remove Stage 3 Only

```bash
# SSH into the VM
VM_IP=$(az vm show -g rg-text2sql-workshop -n vm-text2sql-frontend \
    --show-details --query publicIps -o tsv)
ssh azureuser@${VM_IP}

# Stop and remove A2A service
sudo systemctl stop text2sql-a2a
sudo systemctl disable text2sql-a2a
sudo rm /etc/systemd/system/text2sql-a2a.service
sudo systemctl daemon-reload

# Remove A2A files
rm -rf /home/azureuser/text2sql/a2a

# Remove A2A env vars
sed -i '/^A2A_/d' /home/azureuser/text2sql/.env

exit

# Remove NSG rule
NSG_NAME=$(az network nsg list --resource-group rg-text2sql-workshop --query "[0].name" -o tsv)
az network nsg rule delete \
    --resource-group rg-text2sql-workshop \
    --nsg-name "$NSG_NAME" \
    --name AllowA2A
```

Also remove the agent from VS Code settings:
1. Open `settings.json`
2. Delete the `"text2sql"` entry from `"github.copilot.chat.agents"`

### 10.2 Full Cleanup (All Stages)

```bash
./cleanup.sh --yes
```

---

## 11. Troubleshooting

### 11.1 Agent Card Not Accessible

- Verify port 8002 is open: `az network nsg rule list --resource-group rg-text2sql-workshop --nsg-name <NSG> -o table`
- Test: `curl http://<VM_IP>:8002/.well-known/agent.json`
- Check service status: `ssh azureuser@<VM_IP> "sudo systemctl status text2sql-a2a"`

### 11.2 tasks/send Returns Error

- Check the A2A service logs: `ssh azureuser@<VM_IP> "sudo journalctl -u text2sql-a2a -n 50"`
- Verify agent.py is accessible: `ssh azureuser@<VM_IP> "ls -la /home/azureuser/text2sql/a2a/agent.py"`
- Test the symlink: `ssh azureuser@<VM_IP> "cd /home/azureuser/text2sql/a2a && python3 -c 'import agent; print(agent)'"` 

### 11.3 GitHub Copilot Not Connecting

- Ensure VS Code settings are correct (`settings.json`)
- Verify the URL is reachable from your development machine
- Check if Copilot A2A agent support is enabled in your Copilot subscription
- Try the agent card URL in a browser first

### 11.4 JSON-RPC Returns -32601 (Method Not Found)

- Supported methods: `tasks/send`, `tasks/get`, `tasks/cancel`
- Ensure `method` field is exactly one of the above (case-sensitive)
- Ensure `jsonrpc` field is `"2.0"`

### 11.5 Task Stuck in "working" State

- The pipeline runs synchronously; long-running queries may time out
- Check Azure SQL connectivity: `ssh azureuser@<VM_IP> "cd /home/azureuser/text2sql && python3 -c 'import agent; print(agent.discover_schema()[:100])'"` 
- Check GPT-4o quota/availability in the Azure AI resource

### 11.6 API Key Issues

- The A2A server reuses the same `API_KEY` from `.env` as Stage 2
- Pass it via `X-API-Key` header in JSON-RPC requests
- The `/.well-known/agent.json` endpoint does NOT require auth (per A2A spec)

---

## 12. References

### A2A Protocol

| Topic | URL |
|---|---|
| A2A Protocol Specification | https://google.github.io/A2A/ |
| A2A GitHub Repository | https://github.com/google/A2A |
| A2A Agent Card Spec | https://google.github.io/A2A/#/documentation/agent_card |
| JSON-RPC 2.0 Specification | https://www.jsonrpc.org/specification |

### GitHub Copilot

| Topic | URL |
|---|---|
| GitHub Copilot Extensions | https://docs.github.com/en/copilot/building-copilot-extensions |
| Copilot Chat Agents | https://docs.github.com/en/copilot/using-github-copilot/using-extensions-to-integrate-external-tools |
| VS Code Copilot Settings | https://code.visualstudio.com/docs/copilot/copilot-settings |

### Azure

| Topic | URL |
|---|---|
| Azure VM run-command | https://learn.microsoft.com/en-us/cli/azure/vm/run-command |
| NSG rules | https://learn.microsoft.com/en-us/cli/azure/network/nsg/rule |
| Managed Identity | https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview |
| Azure OpenAI Service | https://learn.microsoft.com/en-us/azure/ai-services/openai/overview |

### Backend

| Topic | URL |
|---|---|
| FastAPI documentation | https://fastapi.tiangolo.com/ |
| Pydantic v2 | https://docs.pydantic.dev/latest/ |
| Uvicorn ASGI server | https://www.uvicorn.org/ |

---

*End of Stage 3 Workshop Guide*
