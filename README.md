# Text-to-SQL: Agentic AI Workshop

## Natural Language to SQL with Microsoft Azure AI Foundry

| Property | Value |
|---|---|
| **Project** | Agentic AI Text-to-SQL |
| **Version** | 1.0 |
| **Platform** | Microsoft Azure |
| **AI Model** | Azure OpenAI GPT-4o |
| **Database** | Azure SQL Database |
| **Language** | Python 3.10+ |

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Solution Architecture](#2-solution-architecture)
3. [Repository Structure](#3-repository-structure)
4. [Prerequisites](#4-prerequisites)
5. [Database Schema](#5-database-schema)
6. [Deployment Stages](#6-deployment-stages)
   - [Stage 1 — Base Infrastructure (deploy.sh)](#stage-1--base-infrastructure-deploysh)
   - [Stage 2 — FastAPI REST API (deploy_stage2.sh)](#stage-2--fastapi-rest-api-deploy_stage2sh)
   - [Stage 3 — A2A Agent Server (deploy_stage3.sh)](#stage-3--a2a-agent-server-deploy_stage3sh)
   - [Stage 4 — MCP Server (deploy_stage4.sh)](#stage-4--mcp-server-deploy_stage4sh)
7. [Service Port Summary](#7-service-port-summary)
8. [Authentication](#8-authentication)
9. [Cleanup](#9-cleanup)
10. [References](#10-references)

---

## 1. Introduction

This project implements an end-to-end **Agentic AI Text-to-SQL** solution deployed on Microsoft Azure. The system converts natural language questions into T-SQL queries, executes them against an Azure SQL Database, and returns human-readable answers synthesized by Azure OpenAI GPT-4o.

The solution is designed as a multi-stage workshop that progressively adds integration layers:

- **Stage 1**: Streamlit web frontend with a direct AI agent backend.
- **Stage 2**: FastAPI REST API enabling Microsoft Copilot Studio integration.
- **Stage 3**: Agent-to-Agent (A2A) protocol server for GitHub Copilot and other A2A-compatible agents.
- **Stage 4**: Model Context Protocol (MCP) server for Copilot Studio MCP-based tool discovery.

The core AI pipeline follows a two-stage LLM approach:

1. **SQL Generation** (temperature=0.0) — Converts natural language to T-SQL using dynamic schema discovery.
2. **Response Synthesis** (temperature=0.3) — Converts raw query results into natural language answers.

---

## 2. Solution Architecture

```
┌──────────────┐     HTTPS      ┌──────────────────────────────────────────┐
│              │ ──────────────> │  Azure VM (Ubuntu 22.04, Indonesia Central)│
│  End User    │                 │                                          │
│  (Browser /  │ <────────────── │  Streamlit  :8501  (Stage 1)             │
│   Copilot /  │    Response     │  FastAPI    :8000  (Stage 2)             │
│   GitHub)    │                 │  A2A Server :8002  (Stage 3)             │
│              │                 │  MCP Server :8003  HTTPS (Stage 4)       │
│              │                 │  MCP Server :8004  HTTP  (Stage 4)       │
└──────────────┘                 └──────────────┬──────────────┬────────────┘
                                                │              │
                                     SDK / REST │              │ Generated SQL
                                                v              v
                                 ┌──────────────────┐  ┌──────────────────┐
                                 │  Azure AI Services│  │  Azure SQL       │
                                 │  (GPT-4o)         │  │  Database        │
                                 │  East US / Sweden │  │  (SalesDB)       │
                                 │  Entra ID / MI    │  │  Indonesia Central│
                                 └──────────────────┘  └──────────────────┘
```

### Data Flow

1. The user submits a natural language question through one of the available interfaces.
2. The application calls `agent.py`, which invokes `discover_schema()` to dynamically retrieve the database schema from `INFORMATION_SCHEMA`.
3. The schema and question are sent to Azure OpenAI GPT-4o to generate a T-SQL query.
4. The generated SQL is executed against Azure SQL Database via `pyodbc`.
5. The raw query results are sent back to GPT-4o for natural language synthesis.
6. The final answer, along with the generated SQL and tabular data, is returned to the user.

---

## 3. Repository Structure

```
Text2SQL/
├── deploy.sh                  # Stage 1: Full infrastructure deployment
├── deploy_stage2.sh           # Stage 2: FastAPI REST API deployment
├── deploy_stage3.sh           # Stage 3: A2A Agent Server deployment
├── deploy_stage4.sh           # Stage 4: MCP Server deployment
├── cleanup.sh                 # Resource cleanup script
├── setup_vm.sh                # VM provisioning and configuration
├── seed_data.sql              # Sample database schema and data
├── deployment_output.txt      # Auto-generated deployment parameters
│
├── app/
│   ├── agent.py               # Core AI pipeline (schema discovery, SQL gen, synthesis)
│   └── app.py                 # Streamlit chat frontend (Stage 1)
│
├── api/
│   ├── main.py                # FastAPI REST API backend (Stage 2)
│   └── openapi_v2.json        # OpenAPI v2 specification for Copilot Studio
│
├── a2a/
│   ├── server.py              # A2A protocol server (Stage 3)
│   ├── handler.py             # A2A task handler (JSON-RPC request processing)
│   └── models.py              # A2A data models (AgentCard, Task, Message)
│
├── mcp_server/
│   └── server.py              # MCP server with HTTPS + Streamable HTTP transport (Stage 4)
│
├── WORKSHOP_TASKLIST.md        # Complete workshop implementation guide
├── WORKSHOP_STAGE2_COPILOT.md  # Stage 2 detailed instructions
├── WORKSHOP_STAGE3_A2A.md      # Stage 3 detailed instructions
└── WORKSHOP_STAGE4_MCP.md      # Stage 4 detailed instructions
```

---

## 4. Prerequisites

| Requirement | Details |
|---|---|
| Azure Subscription | Active subscription with Contributor or Owner role |
| Azure CLI | Version 2.60 or later (`az --version`) |
| Python | Version 3.10 or later |
| SSH Client | Required for VM remote access |
| Microsoft Foundry Access | Portal: https://ai.azure.com |
| GPT-4o Quota | Available in a supported region (East US, Sweden Central) |

> **Note**: As of this writing, Azure AI Foundry Agent Service model deployments may not be available in all regions. The VM is deployed in Indonesia Central for user proximity, while the AI Foundry resource resides in a supported region such as East US or Sweden Central.

---

## 5. Database Schema

The solution uses a sample **SalesDB** database containing Indonesian sales data with the following tables:

| Table | Description | Records |
|---|---|---|
| `Customers` | Customer profiles (Indonesia) | 10 |
| `Products` | Product catalog (Electronics, Furniture, Stationery) | 10 |
| `Orders` | Sales orders (January - July 2024) | 13 |
| `OrderItems` | Order line items | 22 |

The database is seeded automatically during Stage 1 deployment using `seed_data.sql`.

---

## 6. Deployment Stages

Each stage builds incrementally upon the previous one. Stage 1 is required as the foundation. Stages 2, 3, and 4 are independent of each other and can be deployed in any order after Stage 1.

---

### Stage 1 -- Base Infrastructure (deploy.sh)

**Purpose**: Provisions the complete Azure infrastructure and deploys the Streamlit web application as the primary user interface.

**Deployment Command**:

```bash
chmod +x deploy.sh
./deploy.sh
```

**Resources Created**:

| Resource | Configuration |
|---|---|
| Resource Group (VM/SQL) | `rg-text2sql-workshop` in Indonesia Central |
| Resource Group (AI) | `rg-text2sql-ai` in East US |
| Azure SQL Server | Fully public with SQL authentication |
| Azure SQL Database | SalesDB, Basic edition (5 DTU, 2 GB) |
| Azure AI Services | GPT-4o model deployment (Standard SKU) |
| Azure VM | Ubuntu 22.04 LTS, Standard_B2s, public IP |

**Deployment Phases**:

1. **Resource Groups** -- Creates two resource groups (VM region and AI region).
2. **Azure SQL Database** -- Provisions the SQL Server, configures a public firewall rule, creates the SalesDB database, and seeds it with sample data.
3. **Azure AI Services** -- Creates the AI Services account and deploys the GPT-4o model.
4. **Azure VM** -- Creates the Ubuntu VM with a public IP, assigns a system-managed identity, grants Cognitive Services OpenAI User role to the VM identity, and opens port 8501 on the Network Security Group.
5. **Application Setup** -- Installs Python dependencies, deploys `agent.py` and `app.py`, configures environment variables, and starts the Streamlit service via systemd.

**Access After Deployment**:

| Item | Value |
|---|---|
| Streamlit Application | `http://<VM_IP>:8501` |
| SSH Access | `ssh azureuser@<VM_IP>` |

**Core Component -- agent.py**:

The `agent.py` module serves as the backbone of the entire solution. It implements:

- **Dynamic Schema Discovery**: Queries `INFORMATION_SCHEMA` and `sys` catalog views to build a complete understanding of the database structure, including tables, columns, data types, primary keys, and foreign keys.
- **SQL Generation**: Constructs a system prompt with the discovered schema and uses GPT-4o (temperature=0.0) to generate precise T-SQL queries.
- **Query Execution**: Executes the generated SQL against Azure SQL Database via `pyodbc`.
- **Response Synthesis**: Sends the raw query results back to GPT-4o (temperature=0.3) to produce a natural language answer.
- **Schema Caching**: Caches the schema after the first discovery to avoid repeated database introspection.

---

### Stage 2 -- FastAPI REST API (deploy_stage2.sh)

**Purpose**: Adds a FastAPI REST API backend to expose the Text-to-SQL pipeline as a standard HTTP service. This enables integration with **Microsoft Copilot Studio** through an OpenAPI v2-based REST API tool.

**Deployment Command**:

```bash
chmod +x deploy_stage2.sh
./deploy_stage2.sh
```

**Prerequisites**: Stage 1 must be deployed.

**What is Deployed**:

| Component | Details |
|---|---|
| FastAPI Application | `api/main.py` running on Uvicorn |
| Port | 8000 |
| Authentication | API Key via `X-API-Key` header |
| Systemd Services | `text2sql-api` (FastAPI) + `text2sql-streamlit` (Streamlit) |
| NSG Rule | AllowFastAPI (port 8000, inbound) |

**API Endpoints**:

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/ask` | Submit a natural language question; returns SQL, results, and answer |
| `GET` | `/api/schema` | Retrieve the discovered database schema |
| `GET` | `/api/health` | Health check endpoint |

**Deployment Phases**:

1. **Verify Stage 1** -- Confirms the VM exists and retrieves its public IP.
2. **Upload main.py** -- Downloads `api/main.py` from the repository to the VM.
3. **Install Dependencies** -- Installs FastAPI and Uvicorn in the existing Python virtual environment.
4. **Configure API Key** -- Generates a random 256-bit API key and stores it in the `.env` file.
5. **Create Systemd Services** -- Configures and starts both `text2sql-api` and `text2sql-streamlit` as managed services.
6. **Open Port** -- Creates an NSG rule to allow inbound traffic on port 8000.
7. **Verify** -- Tests the health endpoint and confirms both services are active.

**Copilot Studio Integration**:

After deployment, the FastAPI backend can be connected to Microsoft Copilot Studio by:

1. Uploading the `openapi_v2.json` specification as a REST API tool.
2. Configuring the API key authentication in the Copilot Studio security settings.
3. Mapping the `/api/ask` endpoint to the conversational agent.

---

### Stage 3 -- A2A Agent Server (deploy_stage3.sh)

**Purpose**: Exposes the Text-to-SQL pipeline as a **Google Agent-to-Agent (A2A) protocol** server. This enables AI agents such as **GitHub Copilot** to discover the agent automatically and delegate database queries to it through the standardized A2A protocol.

**Deployment Command**:

```bash
chmod +x deploy_stage3.sh
./deploy_stage3.sh
```

**Prerequisites**: Stage 1 must be deployed. Stage 2 is recommended but not required.

**What is Deployed**:

| Component | Details |
|---|---|
| A2A Server | `a2a/server.py` running on Uvicorn |
| Port | 8002 |
| Protocol | JSON-RPC 2.0 over HTTP |
| Discovery | `GET /.well-known/agent.json` |
| Authentication | API Key via `X-API-Key` header (optional) |
| Systemd Service | `text2sql-a2a` |
| NSG Rule | AllowA2A (port 8002, inbound) |

**A2A Protocol Endpoints**:

| Method | Path | Description |
|---|---|---|
| `GET` | `/.well-known/agent.json` | Agent Card for capability discovery |
| `POST` | `/` | JSON-RPC 2.0 dispatch for `tasks/send`, `tasks/get`, `tasks/cancel` |

**A2A Protocol Operations**:

| JSON-RPC Method | Description |
|---|---|
| `tasks/send` | Submit a natural language question as a task |
| `tasks/get` | Query the status and result of a submitted task |
| `tasks/cancel` | Cancel a running task |

**Deployment Phases**:

1. **Verify Stage 1** -- Confirms the VM exists and retrieves its public IP.
2. **Upload A2A Files** -- Downloads `server.py`, `handler.py`, and `models.py` to the VM, creates symlinks for `agent.py` and `.env`.
3. **Install Dependencies** -- Installs FastAPI, Uvicorn, and Pydantic.
4. **Configure Environment** -- Sets `A2A_PORT` and `A2A_HOST_URL` in the `.env` file.
5. **Configure API Key** -- Reuses the existing API key from Stage 2 or generates a new one.
6. **Create Systemd Service** -- Configures and starts `text2sql-a2a` as a managed service.
7. **Open Port** -- Creates an NSG rule to allow inbound traffic on port 8002.
8. **Verify** -- Tests the Agent Card endpoint and JSON-RPC dispatch.

**GitHub Copilot Integration**:

After deployment, GitHub Copilot can be configured to communicate with the A2A server by adding the agent URL to the MCP/A2A configuration in VS Code settings:

```
http://<VM_IP>:8002
```

GitHub Copilot will automatically discover the agent capabilities through the `/.well-known/agent.json` endpoint and delegate database-related questions accordingly.

---

### Stage 4 -- MCP Server (deploy_stage4.sh)

**Purpose**: Adds a **Model Context Protocol (MCP)** server using **Streamable HTTP** transport. This provides an alternative integration path for **Microsoft Copilot Studio** with automatic tool discovery through the MCP standard.

**Deployment Command**:

```bash
chmod +x deploy_stage4.sh
./deploy_stage4.sh
```

**Prerequisites**: Stage 1 must be deployed.

**What is Deployed**:

| Component | Details |
|---|---|
| MCP Server | `mcp_server/server.py` using FastMCP SDK |
| HTTPS Port | 8003 (Copilot Studio / production clients) |
| HTTP Port | 8004 (VS Code / local MCP clients) |
| Protocol | MCP Streamable HTTP (JSON-RPC 2.0) |
| Endpoint | `POST /mcp` |
| TLS | Auto-generated self-signed certificate (or provide custom via env vars) |
| Systemd Service | `text2sql-mcp` |
| NSG Rules | AllowMCP (port 8003), AllowMCPHTTP (port 8004) |

**MCP Tools Exposed**:

| Tool | Description | Arguments |
|---|---|---|
| `ask_database` | Full NL-to-SQL pipeline: question to SQL to execution to answer | `question` (string) |
| `get_database_schema` | Returns the complete database schema (tables, columns, keys) | None |
| `run_sql_query` | Execute a raw T-SQL SELECT query directly | `sql_query` (string) |

**MCP Protocol Lifecycle**:

1. **Initialize** -- Client sends capabilities; server responds with its capabilities and tool list.
2. **tools/list** -- Client discovers available tools (`ask_database`, `get_database_schema`, `run_sql_query`).
3. **tools/call** -- Client invokes a tool with the specified arguments.
4. **resources/list** -- Client discovers available data resources (database schema).

**Deployment Phases**:

1. **Verify Stage 1** -- Confirms the VM exists and retrieves its public IP.
2. **Upload server.py** -- Copies the MCP server script to the VM.
3. **Create Symlinks** -- Links `agent.py` and `.env` from the parent directory.
4. **Install MCP SDK** -- Installs the `mcp[cli]>=1.5.0`, `cryptography`, and `uvicorn` Python packages.
5. **Create Systemd Service** -- Configures and starts `text2sql-mcp` as a managed service.
6. **Open Ports** -- Creates NSG rules to allow inbound traffic on ports 8003 (HTTPS) and 8004 (HTTP).
7. **Verify** -- Tests the MCP handshake and tool listing.

**HTTPS / SSL Configuration**:

The MCP server runs over **HTTPS** by default. On first startup it auto-generates a self-signed certificate under `mcp_server/certs/`. You can supply your own certificates via environment variables:

| Variable | Default | Description |
|---|---|---|
| `MCP_ENABLE_HTTPS` | `true` | Set to `false` to disable HTTPS (HTTP-only on port 8003) |
| `MCP_HTTP_PORT` | `8004` | Plain HTTP port for VS Code / local MCP clients |
| `MCP_SSL_CERTFILE` | *(auto-generated)* | Path to a PEM certificate file |
| `MCP_SSL_KEYFILE` | *(auto-generated)* | Path to a PEM private key file |

**Testing with curl**:

```bash
# MCP Initialize Handshake (HTTP — VS Code / local clients)
curl -X POST http://<VM_IP>:8004/mcp \
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

# MCP Initialize Handshake (HTTPS — use -k for self-signed cert)
curl -k -X POST https://<VM_IP>:8003/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{ ... same payload ... }'
```

**VS Code MCP Configuration** (`.vscode/mcp.json`):

```json
{
  "servers": {
    "Text2SQL": {
      "type": "http",
      "url": "http://<VM_IP>:8004/mcp"
    }
  }
}
```

---

## 7. Service Port Summary

After all four stages are deployed, the following services run concurrently on the Azure VM:

| Port | Service | Protocol | Stage | Client |
|---|---|---|---|---|
| 8501 | Streamlit | HTTP | Stage 1 | Web Browser |
| 8000 | FastAPI | REST / HTTP | Stage 2 | Microsoft Copilot Studio |
| 8002 | A2A Server | JSON-RPC 2.0 | Stage 3 | GitHub Copilot |
| 8003 | MCP Server (HTTPS) | MCP Streamable **HTTPS** | Stage 4 | Microsoft Copilot Studio |
| 8004 | MCP Server (HTTP) | MCP Streamable HTTP | Stage 4 | VS Code / local clients |

All services are managed by `systemd` and configured to restart automatically on failure.

---

## 8. Authentication

| Layer | Method | Details |
|---|---|---|
| Azure VM to Azure AI Services | Entra ID / Managed Identity | System-assigned identity with Cognitive Services OpenAI User role |
| Azure VM to Azure SQL Database | SQL Authentication | Username and password stored in `.env` |
| External Client to FastAPI (Stage 2) | API Key | `X-API-Key` header, 256-bit random key |
| External Client to A2A (Stage 3) | API Key (optional) | `X-API-Key` header, same key as Stage 2 |
| External Client to MCP (Stage 4) | None | HTTPS (:8003) with self-signed cert; plain HTTP (:8004) for VS Code |

---

## 9. Cleanup

To remove all deployed Azure resources:

```bash
# Option 1: Use the cleanup script
chmod +x cleanup.sh
./cleanup.sh

# Option 2: Manual resource group deletion
az group delete --name rg-text2sql-workshop --yes --no-wait
az group delete --name rg-text2sql-ai --yes --no-wait
```

This will permanently delete all resources including the VM, SQL Database, AI Services account, and associated networking components.

---

## 10. References

| Resource | URL |
|---|---|
| Azure OpenAI Service Documentation | https://learn.microsoft.com/en-us/azure/ai-services/openai/ |
| Azure SQL Database Documentation | https://learn.microsoft.com/en-us/azure/azure-sql/database/ |
| Azure AI Foundry | https://ai.azure.com |
| FastAPI Documentation | https://fastapi.tiangolo.com |
| Streamlit Documentation | https://docs.streamlit.io |
| Google A2A Protocol Specification | https://github.com/google/A2A |
| Model Context Protocol (MCP) | https://modelcontextprotocol.io |
| Microsoft Copilot Studio | https://learn.microsoft.com/en-us/microsoft-copilot-studio/ |
| Azure CLI Installation | https://learn.microsoft.com/en-us/cli/azure/install-azure-cli |
| DefaultAzureCredential | https://learn.microsoft.com/en-us/python/api/azure-identity/azure.identity.defaultazurecredential |

---

*This document is intended for educational and workshop purposes. All deployment configurations use simplified security settings (public endpoints, basic SKUs) suitable for learning environments. For production deployments, consult the Azure Well-Architected Framework and implement appropriate security controls including virtual network integration, private endpoints, and Azure Key Vault for secret management.*
