"""
server.py — MCP Server for Text-to-SQL Agent (Stage 4)
=======================================================

Exposes the Text-to-SQL pipeline as a Model Context Protocol (MCP) server
using Streamable HTTP transport. Designed for Microsoft Copilot Studio
integration.

Architecture:
  Copilot Studio  →  MCP (Streamable HTTP)  →  agent.py  →  Azure SQL + GPT-4o

Endpoint: POST /mcp  (MCP Streamable HTTP - JSON-RPC 2.0)
Health:   GET  /health

Tools:
  - ask_database        Full NL-to-SQL pipeline (question → SQL → execute → answer)
  - get_database_schema Return the database schema (tables, columns, keys)
  - run_sql_query       Execute a raw T-SQL SELECT query

Usage:
  python server.py                  # Default port 8003
  MCP_PORT=9000 python server.py    # Custom port
"""

import os
import sys
import logging
from datetime import datetime, date
from decimal import Decimal

# Add parent directory to path so we can import agent.py
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from dotenv import load_dotenv

load_dotenv()

from mcp.server.fastmcp import FastMCP

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
logger = logging.getLogger("text2sql-mcp")

PORT = int(os.getenv("MCP_PORT", "8003"))

# ---------------------------------------------------------------------------
# MCP Server
# ---------------------------------------------------------------------------
mcp = FastMCP(
    "Text2SQL Database Assistant",
    instructions=(
        "A Text-to-SQL agent for the SalesDB database on Azure SQL. "
        "It converts natural language questions about sales data into T-SQL queries, "
        "executes them, and returns natural language answers. "
        "The database contains Products, Customers, Orders, and OrderItems tables."
    ),
    host="0.0.0.0",
    port=PORT,
    stateless_http=True,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _safe(val):
    """Convert non-JSON-serializable types to safe values."""
    if isinstance(val, (datetime, date)):
        return val.isoformat()
    if isinstance(val, Decimal):
        return float(val)
    if isinstance(val, bytes):
        return val.hex()
    return val


# ---------------------------------------------------------------------------
# MCP Tools
# ---------------------------------------------------------------------------
@mcp.tool()
def ask_database(question: str) -> str:
    """
    Ask a natural language question about the SalesDB database.

    Generates a SQL query from the question, executes it against Azure SQL,
    and returns a natural language answer with the supporting SQL and data.

    Examples:
      - "How many products are there?"
      - "Show me the top 5 customers by total order amount"
      - "What is the total revenue for electronics?"
      - "List all orders placed in the last 30 days"

    Args:
        question: A natural language question about the sales database

    Returns:
        Natural language answer with SQL query and data results
    """
    import agent

    logger.info(f"ask_database: {question}")
    result = agent.process_question(question)

    if result.get("error"):
        return f"Error: {result['error']}"

    parts = [result.get("answer", "No answer generated.")]

    if result.get("sql"):
        parts.append(f"\nSQL Query:\n{result['sql']}")

    if result.get("columns") and result.get("rows"):
        cols = result["columns"]
        rows = result["rows"]
        parts.append(f"\nData ({len(rows)} rows):")
        parts.append(" | ".join(cols))
        for row in rows[:25]:
            parts.append(" | ".join(str(_safe(v)) for v in row))
        if len(rows) > 25:
            parts.append(f"... and {len(rows) - 25} more rows")

    return "\n".join(parts)


@mcp.tool()
def get_database_schema() -> str:
    """
    Get the complete SalesDB database schema.

    Returns all tables, columns, data types, primary keys, foreign keys,
    relationships, and row counts. Use this to understand what data is
    available before asking questions.

    Returns:
        Database schema as formatted text
    """
    import agent

    logger.info("get_database_schema called")
    return agent.discover_schema()


@mcp.tool()
def run_sql_query(sql_query: str) -> str:
    """
    Execute a T-SQL SELECT query against the SalesDB database.

    Use this when you have a specific SQL query to run directly.
    Only SELECT queries are supported (the database user has read-only access).

    Args:
        sql_query: A T-SQL SELECT query (e.g., "SELECT TOP 10 * FROM Products")

    Returns:
        Query results as formatted text with column headers and rows
    """
    import agent

    logger.info(f"run_sql_query: {sql_query[:100]}")
    try:
        columns, rows = agent.execute_sql(sql_query)
        if not columns:
            return "Query executed successfully but returned no results."
        parts = [f"Results ({len(rows)} rows):", " | ".join(columns)]
        for row in rows[:50]:
            parts.append(" | ".join(str(_safe(v)) for v in row))
        if len(rows) > 50:
            parts.append(f"... and {len(rows) - 50} more rows")
        return "\n".join(parts)
    except Exception as e:
        return f"SQL Error: {str(e)}"


# ---------------------------------------------------------------------------
# MCP Resource
# ---------------------------------------------------------------------------
@mcp.resource("schema://salesdb")
def salesdb_schema() -> str:
    """Complete SalesDB database schema with tables, columns, and relationships."""
    import agent

    return agent.discover_schema()


# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    logger.info(f"Starting Text2SQL MCP server on port {PORT}")
    logger.info(f"MCP endpoint: http://0.0.0.0:{PORT}/mcp")
    mcp.run(transport="streamable-http")
