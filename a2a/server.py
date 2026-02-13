"""
server.py — A2A Protocol Server for Text-to-SQL Agent (Stage 3)
================================================================

Implements the Google Agent-to-Agent (A2A) protocol, exposing the
Text-to-SQL agentic pipeline as a discoverable remote agent.

Any A2A-compatible client (GitHub Copilot, other AI agents) can:
  1. Discover this agent via GET /.well-known/agent.json
  2. Send tasks via POST / (JSON-RPC: tasks/send)
  3. Query task status via POST / (JSON-RPC: tasks/get)
  4. Cancel tasks via POST / (JSON-RPC: tasks/cancel)

Run:
  uvicorn server:app --host 0.0.0.0 --port 8002
"""

import os
from typing import Optional

from fastapi import FastAPI, HTTPException, Request, Security, Depends
from fastapi.security import APIKeyHeader
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from dotenv import load_dotenv

from models import (
    AgentAuthentication,
    AgentCapabilities,
    AgentCard,
    AgentProvider,
    AgentSkill,
    JSONRPCRequest,
    JSONRPCResponse,
    Message,
    Part,
    TaskCancelParams,
    TaskQueryParams,
    TaskSendParams,
    TextPart,
)
from handler import handle_task_cancel, handle_task_get, handle_task_send

load_dotenv()

# -----------------------------------------------------------
# Configuration
# -----------------------------------------------------------
A2A_PORT = int(os.getenv("A2A_PORT", "8002"))
HOST_URL = os.getenv("A2A_HOST_URL", f"http://localhost:{A2A_PORT}")

# -----------------------------------------------------------
# FastAPI app
# -----------------------------------------------------------
app = FastAPI(
    title="Text-to-SQL A2A Agent Server",
    description=(
        "An Agent-to-Agent (A2A) protocol server exposing the Text-to-SQL "
        "pipeline as a remote agent. Supports agent discovery, task submission, "
        "and task management via JSON-RPC 2.0."
    ),
    version="3.0.0",
    docs_url="/docs",
    redoc_url="/redoc",
)

# CORS — allow any A2A client
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# -----------------------------------------------------------
# API Key authentication (optional — same as Stage 2)
# -----------------------------------------------------------
API_KEY = os.getenv("API_KEY", "")
api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)


async def verify_api_key(api_key: Optional[str] = Security(api_key_header)):
    """Validate the X-API-Key header. Skip if no API_KEY is configured."""
    if not API_KEY:
        return
    if api_key != API_KEY:
        raise HTTPException(
            status_code=403,
            detail="Invalid or missing API key. Provide X-API-Key header.",
        )


# -----------------------------------------------------------
# Agent Card
# -----------------------------------------------------------
def build_agent_card() -> AgentCard:
    """Build the Agent Card for /.well-known/agent.json."""
    return AgentCard(
        name="Text-to-SQL Agent",
        description=(
            "An agentic AI agent that converts natural language questions into "
            "T-SQL queries against a SalesDB database containing Indonesian "
            "sales data. Uses Azure OpenAI GPT-4o for SQL generation and "
            "result synthesis. Ask questions about customers, products, orders, "
            "revenue, and sales analytics."
        ),
        url=HOST_URL,
        version="3.0.0",
        documentationUrl=f"{HOST_URL}/docs",
        provider=AgentProvider(
            organization="Text-to-SQL Workshop",
            url=HOST_URL,
        ),
        capabilities=AgentCapabilities(
            streaming=False,
            pushNotifications=False,
            stateTransitionHistory=True,
        ),
        authentication=AgentAuthentication(
            schemes=["apiKey"] if API_KEY else [],
        ),
        defaultInputModes=["text"],
        defaultOutputModes=["text", "data"],
        skills=[
            AgentSkill(
                id="text-to-sql",
                name="Text-to-SQL Query",
                description=(
                    "Converts natural language questions into T-SQL queries, "
                    "executes them against an Azure SQL Database (SalesDB), "
                    "and returns a natural language answer with the SQL query "
                    "and raw results."
                ),
                tags=["sql", "database", "analytics", "sales", "text-to-sql"],
                examples=[
                    "Show me the top 5 customers by total spending",
                    "What is the total revenue by product category?",
                    "Which orders are still being processed?",
                    "How many customers joined each month in 2023?",
                    "What is the average order value?",
                    "List products that have never been ordered",
                    "Show monthly revenue trends for 2024",
                    "Who ordered the most expensive product?",
                ],
                inputModes=["text"],
                outputModes=["text", "data"],
            ),
            AgentSkill(
                id="schema-discovery",
                name="Database Schema Discovery",
                description=(
                    "Returns the database schema including all tables, columns, "
                    "data types, primary keys, foreign keys, and row counts. "
                    "Use this to understand what data is available."
                ),
                tags=["schema", "metadata", "database", "tables"],
                examples=[
                    "What tables are in the database?",
                    "Show me the database schema",
                    "What columns does the Products table have?",
                ],
                inputModes=["text"],
                outputModes=["text"],
            ),
        ],
    )


# -----------------------------------------------------------
# JSON-RPC error helpers
# -----------------------------------------------------------
def _jsonrpc_error(rpc_id, code: int, message: str, data=None) -> JSONResponse:
    """Return a JSON-RPC 2.0 error response."""
    error = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    return JSONResponse(
        content={
            "jsonrpc": "2.0",
            "id": rpc_id,
            "error": error,
        }
    )


def _jsonrpc_success(rpc_id, result) -> JSONResponse:
    """Return a JSON-RPC 2.0 success response."""
    return JSONResponse(
        content={
            "jsonrpc": "2.0",
            "id": rpc_id,
            "result": result,
        }
    )


def _parse_message(raw: dict) -> Message:
    """Parse a raw dict into a Message, handling Part union types."""
    parts = []
    for p in raw.get("parts", []):
        if isinstance(p, dict):
            ptype = p.get("type", "text")
            if ptype == "text":
                parts.append(TextPart(text=p.get("text", "")))
            else:
                parts.append(p)
        else:
            parts.append(p)
    return Message(
        role=raw.get("role", "user"),
        parts=parts,
        metadata=raw.get("metadata"),
    )


# -----------------------------------------------------------
# Routes
# -----------------------------------------------------------


@app.get("/.well-known/agent.json")
async def agent_card():
    """
    Agent Discovery — serve the Agent Card.
    A2A clients use this to discover the agent's capabilities, skills,
    and endpoint URL before sending tasks.
    """
    card = build_agent_card()
    return card.model_dump(exclude_none=True)


@app.post("/", dependencies=[Depends(verify_api_key)])
async def jsonrpc_endpoint(request: Request):
    """
    A2A JSON-RPC 2.0 endpoint.

    Supported methods:
      - tasks/send       — Send a message and get a response
      - tasks/get        — Get task status and results
      - tasks/cancel     — Cancel a running task
    """
    try:
        body = await request.json()
    except Exception:
        return _jsonrpc_error(None, -32700, "Parse error: invalid JSON")

    # Validate JSON-RPC structure
    jsonrpc = body.get("jsonrpc")
    if jsonrpc != "2.0":
        return _jsonrpc_error(
            body.get("id"), -32600, "Invalid Request: jsonrpc must be '2.0'"
        )

    rpc_id = body.get("id")
    method = body.get("method")
    params = body.get("params", {})

    if not method:
        return _jsonrpc_error(rpc_id, -32600, "Invalid Request: method is required")

    # -----------------------------------------------------------
    # tasks/send
    # -----------------------------------------------------------
    if method == "tasks/send":
        try:
            # Parse the message properly
            raw_message = params.get("message", {})
            message = _parse_message(raw_message)

            send_params = TaskSendParams(
                id=params.get("id", ""),
                sessionId=params.get("sessionId"),
                message=message,
                acceptedOutputModes=params.get("acceptedOutputModes", ["text"]),
                metadata=params.get("metadata"),
            )
            if not send_params.id:
                import uuid
                send_params.id = str(uuid.uuid4())

            task = handle_task_send(send_params)
            return _jsonrpc_success(rpc_id, task.model_dump(exclude_none=True))

        except Exception as e:
            return _jsonrpc_error(rpc_id, -32603, f"Internal error: {str(e)}")

    # -----------------------------------------------------------
    # tasks/get
    # -----------------------------------------------------------
    elif method == "tasks/get":
        try:
            query_params = TaskQueryParams(
                id=params.get("id", ""),
                historyLength=params.get("historyLength"),
            )
            task = handle_task_get(query_params)
            if task is None:
                return _jsonrpc_error(
                    rpc_id, -32001, "Task not found", {"taskId": params.get("id")}
                )
            return _jsonrpc_success(rpc_id, task.model_dump(exclude_none=True))

        except Exception as e:
            return _jsonrpc_error(rpc_id, -32603, f"Internal error: {str(e)}")

    # -----------------------------------------------------------
    # tasks/cancel
    # -----------------------------------------------------------
    elif method == "tasks/cancel":
        try:
            cancel_params = TaskCancelParams(id=params.get("id", ""))
            task = handle_task_cancel(cancel_params)
            if task is None:
                return _jsonrpc_error(
                    rpc_id, -32001, "Task not found", {"taskId": params.get("id")}
                )
            return _jsonrpc_success(rpc_id, task.model_dump(exclude_none=True))

        except Exception as e:
            return _jsonrpc_error(rpc_id, -32603, f"Internal error: {str(e)}")

    # -----------------------------------------------------------
    # Unknown method
    # -----------------------------------------------------------
    else:
        return _jsonrpc_error(
            rpc_id,
            -32601,
            f"Method not found: {method}",
            {"supportedMethods": ["tasks/send", "tasks/get", "tasks/cancel"]},
        )


# -----------------------------------------------------------
# Convenience endpoints (non-A2A, for debugging)
# -----------------------------------------------------------


@app.get("/health")
async def health_check():
    """Health check endpoint for monitoring."""
    return {
        "status": "healthy",
        "service": "text2sql-a2a-agent",
        "version": "3.0.0",
        "protocol": "A2A",
    }


@app.get("/", include_in_schema=False)
async def root():
    """Root redirect — show basic info."""
    return {
        "message": "Text-to-SQL A2A Agent Server v3.0.0",
        "protocol": "Agent-to-Agent (A2A)",
        "agent_card": "/.well-known/agent.json",
        "docs": "/docs",
        "health": "/health",
    }
