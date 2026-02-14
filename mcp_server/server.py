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
import ssl
from pathlib import Path
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
# HTTPS / SSL Configuration
# ---------------------------------------------------------------------------
SSL_CERTFILE = os.getenv("MCP_SSL_CERTFILE", "")
SSL_KEYFILE = os.getenv("MCP_SSL_KEYFILE", "")
ENABLE_HTTPS = os.getenv("MCP_ENABLE_HTTPS", "true").lower() in ("1", "true", "yes")

# Default certificate paths (auto-generated self-signed if not provided)
DEFAULT_CERT_DIR = Path(__file__).parent / "certs"
DEFAULT_CERTFILE = DEFAULT_CERT_DIR / "server.crt"
DEFAULT_KEYFILE = DEFAULT_CERT_DIR / "server.key"


def _generate_self_signed_cert(cert_path: Path, key_path: Path) -> None:
    """Generate a self-signed certificate for development/workshop use."""
    try:
        from cryptography import x509
        from cryptography.x509.oid import NameOID
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        import datetime as _dt

        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

        subject = issuer = x509.Name([
            x509.NameAttribute(NameOID.COMMON_NAME, "text2sql-mcp"),
            x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Text2SQL Workshop"),
        ])

        cert = (
            x509.CertificateBuilder()
            .subject_name(subject)
            .issuer_name(issuer)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(_dt.datetime.now(_dt.timezone.utc))
            .not_valid_after(_dt.datetime.now(_dt.timezone.utc) + _dt.timedelta(days=365))
            .add_extension(
                x509.SubjectAlternativeName([
                    x509.DNSName("localhost"),
                    x509.DNSName("*"),
                    x509.IPAddress(ipaddress.IPv4Address("127.0.0.1")),
                    x509.IPAddress(ipaddress.IPv4Address("0.0.0.0")),
                ]),
                critical=False,
            )
            .sign(key, hashes.SHA256())
        )

        cert_path.parent.mkdir(parents=True, exist_ok=True)

        cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        key_path.write_bytes(
            key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.TraditionalOpenSSL,
                serialization.NoEncryption(),
            )
        )
        # Restrict key file permissions
        os.chmod(key_path, 0o600)

        logger.info(f"Generated self-signed certificate: {cert_path}")
    except ImportError:
        logger.error(
            "Cannot generate self-signed cert: 'cryptography' package not installed. "
            "Install with: pip install cryptography"
        )
        raise


def _resolve_ssl_paths() -> tuple:
    """Resolve SSL cert/key file paths. Returns (certfile, keyfile) or (None, None)."""
    if not ENABLE_HTTPS:
        logger.info("HTTPS disabled (MCP_ENABLE_HTTPS=false)")
        return None, None

    # Use explicitly provided paths
    if SSL_CERTFILE and SSL_KEYFILE:
        cert, key = Path(SSL_CERTFILE), Path(SSL_KEYFILE)
        if cert.is_file() and key.is_file():
            logger.info(f"Using provided SSL cert: {cert}")
            return str(cert), str(key)
        else:
            logger.error(f"SSL cert/key not found: {cert}, {key}")
            raise FileNotFoundError(f"SSL files not found: {cert}, {key}")

    # Auto-generate self-signed if defaults don't exist
    if not DEFAULT_CERTFILE.is_file() or not DEFAULT_KEYFILE.is_file():
        logger.info("No SSL certificates found — generating self-signed certificate...")
        _generate_self_signed_cert(DEFAULT_CERTFILE, DEFAULT_KEYFILE)

    return str(DEFAULT_CERTFILE), str(DEFAULT_KEYFILE)


import ipaddress  # needed for SAN IP addresses in cert generation

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
    certfile, keyfile = _resolve_ssl_paths()

    if certfile and keyfile:
        scheme = "https"
        logger.info(f"Starting Text2SQL MCP server on port {PORT} (HTTPS)")
        logger.info(f"MCP endpoint: https://0.0.0.0:{PORT}/mcp")
        logger.info(f"SSL cert: {certfile}")

        import uvicorn

        app = mcp.streamable_http_app()
        uvicorn.run(
            app,
            host="0.0.0.0",
            port=PORT,
            ssl_certfile=certfile,
            ssl_keyfile=keyfile,
            log_level="info",
        )
    else:
        logger.info(f"Starting Text2SQL MCP server on port {PORT} (HTTP)")
        logger.info(f"MCP endpoint: http://0.0.0.0:{PORT}/mcp")
        mcp.run(transport="streamable-http")
