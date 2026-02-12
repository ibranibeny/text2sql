# Stage 2 — Microsoft Copilot Studio × Text-to-SQL REST API

## Agentic AI Workshop: Connecting Copilot Studio to a Custom Backend API

| Property | Value |
|---|---|
| **Document Version** | 2.0 |
| **Last Updated** | 2026-02-12 |
| **Author** | Workshop Facilitator |
| **Stage** | 2 of 2 |
| **Prerequisite** | Stage 1 (Streamlit frontend) completed |
| **Estimated Duration** | 90 minutes |

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Phase 1 — Build the FastAPI Backend](#4-phase-1--build-the-fastapi-backend)
5. [Phase 2 — Deploy to Azure VM](#5-phase-2--deploy-to-azure-vm)
6. [Phase 3 — Generate the OpenAPI Specification](#6-phase-3--generate-the-openapi-specification)
7. [Phase 4 — Create a Copilot Studio Agent](#7-phase-4--create-a-copilot-studio-agent)
8. [Phase 5 — Connect REST API Tool to the Agent](#8-phase-5--connect-rest-api-tool-to-the-agent)
9. [Phase 6 — Test and Publish](#9-phase-6--test-and-publish)
10. [Phase 7 — Cleanup](#10-phase-7--cleanup)
11. [Troubleshooting](#11-troubleshooting)
12. [References](#12-references)

---

## 1. Overview

### 1.1 Purpose

Stage 1 of this workshop deployed a Streamlit web application as the frontend for the Text-to-SQL agentic AI pipeline. Stage 2 replaces the Streamlit frontend with **Microsoft Copilot Studio**, connecting it to the same Azure SQL + Azure OpenAI backend through a **REST API** built with FastAPI.

This architecture demonstrates a production-grade pattern: the backend exposes a well-defined API with an OpenAPI specification, and the conversational frontend is handled by Copilot Studio — no custom UI code required.

### 1.2 What Changes from Stage 1

| Component | Stage 1 | Stage 2 |
|---|---|---|
| **Frontend** | Streamlit (Python web app) | Microsoft Copilot Studio |
| **Backend** | `agent.py` called directly by `app.py` | FastAPI REST API wrapping `agent.py` |
| **Protocol** | In-process Python calls | HTTPS REST (JSON) |
| **Deployment** | systemd → streamlit | systemd → uvicorn |
| **Auth (API)** | N/A (same process) | API Key header |
| **Discovery** | N/A | OpenAPI v2 specification |

### 1.3 What Stays the Same

- Azure SQL Database (SalesDB) with the same sample data
- Azure AI Services (GPT-4o) with Entra ID / Managed Identity authentication
- Azure VM (Ubuntu 22.04) in Indonesia Central
- Dynamic schema discovery (`discover_schema()`)
- Two-stage LLM pipeline (generate SQL → synthesize answer)

---

## 2. Architecture

```
┌──────────────────────────────────────────────────────────┐
│                   Microsoft Copilot Studio                │
│                                                          │
│  ┌──────────────┐    ┌───────────────────────────────┐   │
│  │  User Chat   │───▶│  REST API Tool (OpenAPI v2)   │   │
│  │  Interface   │◀───│  POST /api/ask                │   │
│  └──────────────┘    └───────────────┬───────────────┘   │
│                                      │                    │
└──────────────────────────────────────┼────────────────────┘
                                       │ HTTPS + API Key
                                       ▼
┌──────────────────────────────────────────────────────────┐
│              Azure VM (Indonesia Central)                 │
│              FastAPI + Uvicorn (port 8000)                │
│                                                          │
│  ┌─────────────────────────────────────────────────────┐ │
│  │  POST /api/ask                                      │ │
│  │    → discover_schema()  [INFORMATION_SCHEMA query]  │ │
│  │    → generate_sql()     [GPT-4o, temperature=0.0]   │ │
│  │    → execute_sql()      [pyodbc → Azure SQL]        │ │
│  │    → synthesize_response() [GPT-4o, temp=0.3]       │ │
│  │    → return JSON { answer, sql, rows }              │ │
│  └───────────────────┬─────────────────┬───────────────┘ │
│                      │                 │                  │
└──────────────────────┼─────────────────┼──────────────────┘
                       │                 │
            ┌──────────┘                 └──────────┐
            ▼                                       ▼
┌───────────────────────┐             ┌──────────────────────┐
│  Azure SQL Database   │             │  Azure AI Services   │
│  (SalesDB)            │             │  (GPT-4o)            │
│  Indonesia Central    │             │  East US              │
│  SQL Auth             │             │  Entra ID / MI        │
└───────────────────────┘             └──────────────────────┘
```

---

## 3. Prerequisites

### 3.1 Stage 1 Must Be Completed

The following resources from Stage 1 must exist:

| Resource | Resource Group | Purpose |
|---|---|---|
| `vm-text2sql-frontend` | `rg-text2sql-workshop` | Hosts the FastAPI backend |
| `sql-text2sql-*` | `rg-text2sql-workshop` | Azure SQL with SalesDB |
| `ai-text2sql-*` | `rg-text2sql-ai` | Azure AI Services (GPT-4o) |

### 3.2 Copilot Studio Access

- A **Microsoft Copilot Studio** license (trial or paid)
  - Sign up: https://copilotstudio.microsoft.com
  - Documentation: https://learn.microsoft.com/en-us/microsoft-copilot-studio/fundamentals-what-is-copilot-studio
- A **Power Platform environment** (created automatically with Copilot Studio)

### 3.3 Tools

- Azure CLI (`az`) installed and logged in
- `curl` or a browser for testing the API

---

## 4. Phase 1 — Build the FastAPI Backend

### 4.1 Understanding the API Design

The FastAPI backend wraps the existing `agent.py` pipeline and exposes three endpoints:

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/ask` | POST | Send a natural language question, receive SQL + answer |
| `/api/schema` | GET | Return the discovered database schema |
| `/api/health` | GET | Health check for monitoring |

**Authentication**: All `/api/*` endpoints require an `X-API-Key` header matching the `API_KEY` environment variable.

### 4.2 File: `api/main.py`

This file is provided in the repository at `api/main.py`. Key design decisions:

1. **FastAPI** was chosen over Flask for automatic OpenAPI spec generation — Copilot Studio requires an OpenAPI v2 specification to register a REST API tool.

2. **API Key authentication** via `X-API-Key` header — simple, stateless, and supported natively by Copilot Studio's REST API tool authentication.

3. **Structured JSON responses** — Copilot Studio can extract fields from the response to use in its conversation flow.

**Request/Response schema for `POST /api/ask`:**

```json
// Request
{
  "question": "Show me all electronics products"
}

// Response
{
  "question": "Show me all electronics products",
  "answer": "Here are the electronics products in the database...",
  "sql": "SELECT ProductName, Price FROM dbo.Products WHERE Category = 'Electronics'",
  "columns": ["ProductName", "Price"],
  "rows": [["Laptop ProBook 14", 12500000.00], ...],
  "row_count": 6,
  "error": null
}
```

> **Reference**: FastAPI documentation — https://fastapi.tiangolo.com/
>
> **Reference**: Uvicorn ASGI server — https://www.uvicorn.org/

### 4.3 File: `openapi_v2.json`

Copilot Studio requires an **OpenAPI v2** (Swagger) specification. FastAPI natively generates OpenAPI v3.1, so we provide a manually curated v2 file for Copilot Studio import.

This file is provided in the repository at `api/openapi_v2.json`.

---

## 5. Phase 2 — Deploy to Azure VM

### 5.1 Option A: Automated Deployment (Recommended)

If you already have Stage 1 deployed, run the Stage 2 deployment script to replace Streamlit with FastAPI on the existing VM:

```bash
chmod +x deploy_stage2.sh
./deploy_stage2.sh
```

The script performs:
1. Generates a random API key for the REST API
2. Uploads `api/main.py` to the VM
3. Installs FastAPI + Uvicorn in the existing Python venv
4. Replaces the systemd service (text2sql → text2sql-api)
5. Opens port 8000 on the NSG
6. Verifies the health endpoint

### 5.2 Option B: Manual Deployment

If you prefer to deploy manually, follow these steps:

#### Step 1 — Upload main.py to the VM

```bash
VM_IP=$(az vm show -g rg-text2sql-workshop -n vm-text2sql-frontend \
    --show-details --query publicIps -o tsv)

scp api/main.py azureuser@${VM_IP}:/home/azureuser/text2sql/main.py
```

#### Step 2 — SSH into the VM and install dependencies

```bash
ssh azureuser@${VM_IP}

cd /home/azureuser/text2sql
source venv/bin/activate
pip install fastapi uvicorn[standard]
```

#### Step 3 — Add API_KEY to .env

```bash
# Generate a random API key
API_KEY=$(openssl rand -hex 32)
echo "API_KEY=\"${API_KEY}\"" >> .env
echo "Your API Key: ${API_KEY}"
```

#### Step 4 — Create the systemd service

```bash
sudo tee /etc/systemd/system/text2sql-api.service > /dev/null << 'UNIT'
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
```

#### Step 5 — Stop the Streamlit service (optional)

```bash
sudo systemctl stop text2sql
sudo systemctl disable text2sql
```

#### Step 6 — Open port 8000 on NSG

```bash
az network nsg rule create \
    --resource-group rg-text2sql-workshop \
    --nsg-name nsg-text2sql \
    --name AllowFastAPI \
    --priority 1020 \
    --destination-port-ranges 8000 \
    --access Allow \
    --protocol Tcp \
    --direction Inbound
```

#### Step 7 — Verify

```bash
curl -s http://${VM_IP}:8000/api/health \
    -H "X-API-Key: ${API_KEY}" | python3 -m json.tool
```

Expected output:
```json
{
    "status": "healthy",
    "service": "text2sql-api",
    "version": "2.0.0"
}
```

> **Reference**: Azure CLI `az network nsg rule create` — https://learn.microsoft.com/en-us/cli/azure/network/nsg/rule?view=azure-cli-latest#az-network-nsg-rule-create
>
> **Reference**: Azure CLI `az vm run-command invoke` — https://learn.microsoft.com/en-us/cli/azure/vm/run-command?view=azure-cli-latest#az-vm-run-command-invoke

---

## 6. Phase 3 — Generate the OpenAPI Specification

### 6.1 Download the Auto-Generated Spec

FastAPI auto-generates an OpenAPI v3.1 specification at `/openapi.json`:

```bash
curl -s http://${VM_IP}:8000/openapi.json \
    -H "X-API-Key: ${API_KEY}" > openapi_v3.json
```

### 6.2 Convert to OpenAPI v2 (Required for Copilot Studio)

Copilot Studio requires **OpenAPI v2** format. You have two options:

**Option A** — Use the provided `api/openapi_v2.json` from the repository (pre-built).

**Option B** — Use an online converter:
1. Go to https://converter.swagger.io/
2. Paste the v3 spec
3. Download the v2 output

**Option C** — Use `api-spec-converter` (npm):
```bash
npm install -g api-spec-converter
api-spec-converter openapi_v3.json --from=openapi_3 --to=swagger_2 > openapi_v2.json
```

### 6.3 Verify the Spec

Validate the OpenAPI v2 spec at: https://editor.swagger.io/

> **Reference**: OpenAPI Specification v2.0 — https://swagger.io/specification/v2/
>
> **Reference**: Copilot Studio REST API tool requirements — https://learn.microsoft.com/en-us/microsoft-copilot-studio/agent-extend-action-rest-api

---

## 7. Phase 4 — Create a Copilot Studio Agent

### 7.1 Sign In to Copilot Studio

1. Navigate to https://copilotstudio.microsoft.com
2. Sign in with your Microsoft 365 / organizational account
3. Select or create an **environment** for this workshop

### 7.2 Create a New Agent

1. On the Home page, select **Create** → **New agent**
2. Configure the agent:

| Field | Value |
|---|---|
| **Name** | `Sales Data Assistant` |
| **Description** | `An AI agent that answers natural language questions about sales data by converting them to SQL queries and returning insights.` |
| **Instructions** | See below |
| **Language** | English |

3. In the **Instructions** field, enter:

```
You are a Sales Data Assistant that helps users query a SalesDB database 
containing Indonesian sales data. 

When a user asks a question about customers, products, orders, or order items:
1. Use the "Ask Question" tool to send their question to the backend API
2. Present the "answer" field from the response in a conversational format
3. If the user wants to see the raw SQL, show the "sql" field
4. If there is an error, explain it clearly and suggest rephrasing

The database contains:
- Customers (10 records, Indonesian cities)
- Products (Electronics, Furniture, Stationery — prices in IDR)
- Orders (13 records, statuses: Completed, Shipped, Processing)
- OrderItems (22 line items)

Always format currency values in IDR with thousand separators.
Be conversational and helpful. If unsure, ask clarifying questions.
```

4. Select **Create**

> **Reference**: Create and delete agents — https://learn.microsoft.com/en-us/microsoft-copilot-studio/authoring-first-bot

---

## 8. Phase 5 — Connect REST API Tool to the Agent

### 8.1 Add the REST API Tool

1. In your agent, go to the **Tools** tab
2. Select **Add a tool**
3. Select **New tool** → **REST API**

### 8.2 Upload the OpenAPI Specification

1. Upload the `openapi_v2.json` file (from Phase 3)
2. Verify the detected endpoints:
   - `POST /api/ask` — Ask a natural language question
   - `GET /api/schema` — Get database schema
   - `GET /api/health` — Health check
3. Select **Next**

### 8.3 Configure API Details

| Field | Value |
|---|---|
| **Name** | `Text-to-SQL API` |
| **Description** | `A REST API that converts natural language questions into SQL queries against a SalesDB database containing Indonesian sales data. Use this tool whenever a user asks about customers, products, orders, or sales data. The API returns the SQL query, raw results, and a natural language answer.` |

Select **Next**.

### 8.4 Configure Authentication

1. Select **API key** as the authentication method
2. Configure:

| Field | Value |
|---|---|
| **Parameter label** | `API Key` |
| **Parameter name** | `X-API-Key` |
| **Parameter location** | `Header` |

3. Select **Next**

### 8.5 Select and Configure Tools

#### Tool 1: Ask Question (`POST /api/ask`)

| Field | Value |
|---|---|
| **Tool name** | `Ask Question` |
| **Tool description** | `Send a natural language question about sales data to the backend. The tool converts the question to SQL, executes it against the SalesDB database, and returns a natural language answer along with the SQL query and raw results. Use this for any question about customers, products, orders, order items, revenue, or sales analytics.` |

Review parameters:
- **Input**: `question` (string) — "The natural language question to ask about the sales database"
- **Output**: `answer` (string), `sql` (string), `row_count` (integer), `error` (string)

#### Tool 2: Get Schema (`GET /api/schema`) — Optional

| Field | Value |
|---|---|
| **Tool name** | `Get Database Schema` |
| **Tool description** | `Retrieve the current database schema showing all tables, columns, data types, and relationships. Use this when the user asks what data is available or wants to know the database structure.` |

Select **Next**.

### 8.6 Review and Publish

1. Review all configured tools
2. Select **Next** to publish
3. Wait for the publishing process to complete
4. Select **Create connection**
5. Enter the **API Key** (from Phase 2, Step 3)
6. Select **Create** to establish the connection
7. For each tool, select **Add and configure**

> **Reference**: Add tools from a REST API — https://learn.microsoft.com/en-us/microsoft-copilot-studio/agent-extend-action-rest-api
>
> **Reference**: Add tools to custom agents — https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-plugin-actions

---

## 9. Phase 6 — Test and Publish

### 9.1 Test in Copilot Studio

1. In the agent editor, open the **Test** pane (bottom-left)
2. Try these sample questions:

| # | Question | Expected Behavior |
|---|---|---|
| 1 | "Show me all electronics products" | Calls Ask Question tool, returns product list |
| 2 | "Who are the top 3 customers by order amount?" | Returns customer ranking with IDR amounts |
| 3 | "How many orders are still processing?" | Returns count of Processing orders |
| 4 | "What is the total revenue by product category?" | Returns aggregated revenue by category |
| 5 | "Show me orders from Jakarta customers" | Returns orders filtered by city |
| 6 | "What tables are in the database?" | Calls Get Schema tool (if configured) |

3. Verify that:
   - The agent correctly routes questions to the REST API tool
   - The `answer` field is presented conversationally
   - Error handling works (try an invalid question)

### 9.2 Publish the Agent

1. Select **Publish** in the top-right corner
2. Choose publishing channels:

| Channel | Description | Documentation |
|---|---|---|
| **Microsoft Teams** | Deploy as a Teams bot | [Publish to Teams](https://learn.microsoft.com/en-us/microsoft-copilot-studio/publication-add-bot-to-microsoft-teams) |
| **Demo website** | Quick shareable demo link | [Publish to demo website](https://learn.microsoft.com/en-us/microsoft-copilot-studio/publication-connect-bot-to-web-channels) |
| **Custom website** | Embed via iframe | [Publish to custom website](https://learn.microsoft.com/en-us/microsoft-copilot-studio/publication-connect-bot-to-web-channels) |
| **Microsoft 365 Copilot** | Extend M365 Copilot | [Extend M365 Copilot](https://learn.microsoft.com/en-us/microsoft-copilot-studio/microsoft-copilot-extend-copilot-extensions) |

3. For the workshop demo, select **Demo website** to get a shareable URL

> **Reference**: Publish and deploy agents — https://learn.microsoft.com/en-us/microsoft-copilot-studio/publication-fundamentals-publish-channels

### 9.3 Compare Stage 1 vs Stage 2

| Aspect | Stage 1 (Streamlit) | Stage 2 (Copilot Studio) |
|---|---|---|
| **Setup effort** | Low (deploy script) | Medium (API + Copilot config) |
| **UI customization** | Full control (Python/HTML) | Limited (Copilot Studio themes) |
| **Multi-channel** | Web only | Teams, Web, M365, Custom |
| **Authentication** | None (open web app) | API Key + user auth via Copilot |
| **Maintenance** | Maintain Python UI code | Copilot Studio manages UI |
| **Enterprise readiness** | Low | High (DLP, audit, governance) |
| **Conversation memory** | Per-session (Streamlit state) | Built-in (Copilot Studio) |

---

## 10. Phase 7 — Cleanup

### 10.1 Remove Stage 2 Only

To revert to Stage 1 (Streamlit):

```bash
# SSH into the VM
VM_IP=$(az vm show -g rg-text2sql-workshop -n vm-text2sql-frontend \
    --show-details --query publicIps -o tsv)
ssh azureuser@${VM_IP}

# Stop and disable FastAPI service
sudo systemctl stop text2sql-api
sudo systemctl disable text2sql-api
sudo rm /etc/systemd/system/text2sql-api.service
sudo systemctl daemon-reload

# Re-enable Streamlit service
sudo systemctl enable text2sql
sudo systemctl start text2sql

exit

# Remove NSG rule for port 8000
az network nsg rule delete \
    --resource-group rg-text2sql-workshop \
    --nsg-name nsg-text2sql \
    --name AllowFastAPI
```

Also delete the agent in Copilot Studio:
1. Go to https://copilotstudio.microsoft.com
2. Navigate to **Agents**
3. Select "Sales Data Assistant" → **Delete**

### 10.2 Full Cleanup (Both Stages)

Run the cleanup script from Stage 1:

```bash
./cleanup.sh --yes
```

This deletes both resource groups (`rg-text2sql-workshop` and `rg-text2sql-ai`).

---

## 11. Troubleshooting

### 11.1 API Returns 403 Forbidden

- Verify the `X-API-Key` header matches the `API_KEY` in `.env`
- Check: `curl -H "X-API-Key: YOUR_KEY" http://VM_IP:8000/api/health`

### 11.2 Copilot Studio Cannot Reach the API

- Ensure port 8000 is open on the NSG
- Ensure the VM has a public IP
- Test from your local machine first: `curl http://VM_IP:8000/api/health -H "X-API-Key: KEY"`
- Check if the VM's firewall (iptables/ufw) blocks the port

### 11.3 OpenAPI Spec Upload Fails

- Copilot Studio requires **OpenAPI v2** (Swagger 2.0) format
- Verify the file is valid JSON (not YAML)
- Validate at https://editor.swagger.io/
- Ensure the `host` field in the spec matches your VM's public IP

### 11.4 Tool Not Being Selected by Agent

- Improve the tool description with more synonyms and use cases
- Add trigger phrases to the agent's topics
- Check Copilot Studio's **Analytics** → **Tool usage** for insights

### 11.5 Token / Managed Identity Errors

- Same troubleshooting as Stage 1
- Verify: `az role assignment list --assignee $(az vm show -g rg-text2sql-workshop -n vm-text2sql-frontend --query identity.principalId -o tsv) -o table`

---

## 12. References

### Microsoft Copilot Studio

| Topic | URL |
|---|---|
| Copilot Studio overview | https://learn.microsoft.com/en-us/microsoft-copilot-studio/fundamentals-what-is-copilot-studio |
| Add tools to custom agents | https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-plugin-actions |
| REST API tools (preview) | https://learn.microsoft.com/en-us/microsoft-copilot-studio/agent-extend-action-rest-api |
| Publish to channels | https://learn.microsoft.com/en-us/microsoft-copilot-studio/publication-fundamentals-publish-channels |
| Publish to Teams | https://learn.microsoft.com/en-us/microsoft-copilot-studio/publication-add-bot-to-microsoft-teams |
| Generative orchestration | https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-generative-actions |

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
| Uvicorn ASGI server | https://www.uvicorn.org/ |
| OpenAPI v2 specification | https://swagger.io/specification/v2/ |
| Power Platform custom connectors | https://learn.microsoft.com/en-us/connectors/custom-connectors/ |

---

*End of Stage 2 Workshop Guide*
