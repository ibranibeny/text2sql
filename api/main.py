"""
main.py — FastAPI REST API for Text-to-SQL Backend (Stage 2)
=============================================================

Exposes the Text-to-SQL agentic pipeline as a REST API for consumption
by Microsoft Copilot Studio or any HTTP client.

Endpoints:
  POST /api/ask      — Send a natural language question, receive SQL + answer
  GET  /api/schema   — Return the discovered database schema
  GET  /api/health   — Health check

Authentication:
  All /api/* endpoints require X-API-Key header matching API_KEY env var.

Run:
  uvicorn main:app --host 0.0.0.0 --port 8000
"""

import os
import time
from typing import Optional

from fastapi import FastAPI, HTTPException, Security, Depends
from fastapi.security import APIKeyHeader
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from dotenv import load_dotenv

# Import the existing agent module (same directory on VM)
import agent

load_dotenv()

# -----------------------------------------------------------
# FastAPI app
# -----------------------------------------------------------
app = FastAPI(
    title="Text-to-SQL API",
    description=(
        "An Agentic AI REST API that converts natural language questions into "
        "T-SQL queries against an Azure SQL Database (SalesDB) containing "
        "Indonesian sales data. Uses Azure OpenAI GPT-4o for query generation "
        "and result synthesis."
    ),
    version="2.0.0",
    docs_url="/docs",
    redoc_url="/redoc",
)

# CORS — allow Copilot Studio and browser testing
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# -----------------------------------------------------------
# API Key authentication
# -----------------------------------------------------------
API_KEY = os.getenv("API_KEY", "")
api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)


async def verify_api_key(api_key: Optional[str] = Security(api_key_header)):
    """Validate the X-API-Key header."""
    if not API_KEY:
        # If no API_KEY is configured, skip auth (dev mode)
        return
    if api_key != API_KEY:
        raise HTTPException(
            status_code=403,
            detail="Invalid or missing API key. Provide X-API-Key header.",
        )


# -----------------------------------------------------------
# Request / Response models
# -----------------------------------------------------------
class AskRequest(BaseModel):
    """Natural language question to convert to SQL."""

    question: str = Field(
        ...,
        description="The natural language question about the sales database.",
        min_length=3,
        max_length=1000,
        json_schema_extra={"example": "Show me the top 5 customers by total order amount"},
    )


class AskResponse(BaseModel):
    """Response containing the SQL query, results, and natural language answer."""

    question: str = Field(description="The original question that was asked.")
    answer: Optional[str] = Field(
        None, description="Natural language answer synthesized from the query results."
    )
    sql: Optional[str] = Field(
        None, description="The T-SQL query that was generated and executed."
    )
    columns: list[str] = Field(
        default_factory=list,
        description="Column names from the query result.",
    )
    rows: list[list] = Field(
        default_factory=list,
        description="Rows of data from the query result (max 50 rows).",
    )
    row_count: int = Field(0, description="Total number of rows returned.")
    error: Optional[str] = Field(
        None, description="Error message if the query failed."
    )
    elapsed_seconds: float = Field(
        0.0, description="Time taken to process the request in seconds."
    )


class SchemaResponse(BaseModel):
    """Database schema information."""

    schema_text: str = Field(
        description="Human-readable database schema with tables, columns, types, and relationships."
    )
    table_count: int = Field(description="Number of tables discovered.")


class HealthResponse(BaseModel):
    """Health check response."""

    status: str = Field(description="Service health status.")
    service: str = Field(description="Service name.")
    version: str = Field(description="API version.")


# -----------------------------------------------------------
# Endpoints
# -----------------------------------------------------------
@app.post(
    "/api/ask",
    response_model=AskResponse,
    summary="Ask a natural language question",
    description=(
        "Send a natural language question about sales data. The API converts "
        "it to a T-SQL query, executes it against the SalesDB database, and "
        "returns a natural language answer along with the SQL and raw results."
    ),
    dependencies=[Depends(verify_api_key)],
)
async def ask_question(request: AskRequest):
    start = time.time()

    result = agent.process_question(request.question)

    # Convert rows from tuples to lists for JSON serialization
    rows = [list(row) for row in result.get("rows", [])]

    return AskResponse(
        question=result["question"],
        answer=result.get("answer"),
        sql=result.get("sql"),
        columns=result.get("columns", []),
        rows=rows[:50],
        row_count=len(rows),
        error=result.get("error"),
        elapsed_seconds=round(time.time() - start, 2),
    )


@app.get(
    "/api/schema",
    response_model=SchemaResponse,
    summary="Get database schema",
    description=(
        "Retrieve the current database schema including all tables, columns, "
        "data types, primary keys, foreign keys, and row counts."
    ),
    dependencies=[Depends(verify_api_key)],
)
async def get_schema():
    try:
        schema_text = agent.discover_schema()
        table_count = schema_text.count("Table: ")
        return SchemaResponse(
            schema_text=schema_text,
            table_count=table_count,
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Schema discovery failed: {str(e)}")


@app.get(
    "/api/health",
    response_model=HealthResponse,
    summary="Health check",
    description="Returns the health status of the Text-to-SQL API service.",
    dependencies=[Depends(verify_api_key)],
)
async def health_check():
    return HealthResponse(
        status="healthy",
        service="text2sql-api",
        version="2.0.0",
    )


# -----------------------------------------------------------
# Root redirect
# -----------------------------------------------------------
@app.get("/", include_in_schema=False)
async def root():
    return {
        "message": "Text-to-SQL API v2.0.0",
        "docs": "/docs",
        "health": "/api/health",
    }
