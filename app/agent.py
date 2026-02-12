"""
agent.py — Agentic AI Text-to-SQL Backend
==========================================

Two-stage LLM pipeline:
  1. generate_sql()       – Converts natural language to SQL (temperature=0.0)
  2. synthesize_response() – Converts SQL results to natural language (temperature=0.3)

Dependencies:
  pip install openai pyodbc python-dotenv azure-identity

Environment variables (loaded from .env):
  AZURE_OPENAI_ENDPOINT, AZURE_OPENAI_DEPLOYMENT
  SQL_SERVER, SQL_DATABASE, SQL_USERNAME, SQL_PASSWORD, SQL_DRIVER

Authentication:
  Uses DefaultAzureCredential (Managed Identity on VM, or az login locally).
  No API keys required.
"""

import os
import json
import pyodbc
from openai import AzureOpenAI
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from dotenv import load_dotenv

load_dotenv()

# -----------------------------------------------------------
# Database schema context — injected into every LLM prompt
# -----------------------------------------------------------
DB_SCHEMA = """
Database: SalesDB

Table: Customers
  - CustomerID   (INT, PK)
  - FirstName    (NVARCHAR 50)
  - LastName     (NVARCHAR 50)
  - Email        (NVARCHAR 100, UNIQUE)
  - City         (NVARCHAR 50)
  - Country      (NVARCHAR 50, default 'Indonesia')
  - JoinDate     (DATE)

Table: Products
  - ProductID    (INT, PK)
  - ProductName  (NVARCHAR 100)
  - Category     (NVARCHAR 50)       — values: Electronics, Furniture, Stationery
  - Price        (DECIMAL 10,2)      — in IDR (Indonesian Rupiah)
  - Stock        (INT)

Table: Orders
  - OrderID      (INT, PK)
  - CustomerID   (INT, FK → Customers)
  - OrderDate    (DATE)
  - TotalAmount  (DECIMAL 12,2)      — in IDR
  - Status       (NVARCHAR 20)       — values: Completed, Shipped, Processing

Table: OrderItems
  - OrderItemID  (INT, PK)
  - OrderID      (INT, FK → Orders)
  - ProductID    (INT, FK → Products)
  - Quantity     (INT)
  - UnitPrice    (DECIMAL 10,2)      — in IDR
  - LineTotal    (computed: Quantity * UnitPrice)

Relationships:
  Orders.CustomerID   → Customers.CustomerID
  OrderItems.OrderID  → Orders.OrderID
  OrderItems.ProductID → Products.ProductID
"""

# -----------------------------------------------------------
# System prompts
# -----------------------------------------------------------
SYSTEM_PROMPT = f"""You are an expert SQL query generator for Microsoft SQL Server (Azure SQL).
Given a natural language question, generate ONLY the T-SQL query — no explanations, no markdown.

Rules:
1. Use only the tables and columns defined in the schema below.
2. Use T-SQL syntax (TOP instead of LIMIT, etc.).
3. Always qualify column names with table aliases when joining.
4. Use appropriate JOINs — prefer INNER JOIN unless LEFT JOIN is needed.
5. For aggregations, include GROUP BY for all non-aggregated columns.
6. Return ONLY the SQL query. No commentary, no code fences.
7. Prices are in IDR (Indonesian Rupiah).

Schema:
{DB_SCHEMA}
"""

SYNTHESIS_PROMPT = """You are a helpful data analyst assistant.
Given a user question, the SQL query that was executed, and the query results,
provide a clear, concise, natural language answer.

Rules:
1. Summarise the data — do not just dump raw rows.
2. Format currency values in IDR with thousand separators.
3. If no results were returned, say so clearly and suggest possible reasons.
4. Be conversational but professional.
5. If there are many rows, highlight key findings rather than listing all.
"""


def get_db_connection() -> pyodbc.Connection:
    """Establish a connection to Azure SQL Database."""
    conn_str = (
        f"DRIVER={os.getenv('SQL_DRIVER', '{ODBC Driver 18 for SQL Server}')};"
        f"SERVER={os.getenv('SQL_SERVER')};"
        f"DATABASE={os.getenv('SQL_DATABASE')};"
        f"UID={os.getenv('SQL_USERNAME')};"
        f"PWD={os.getenv('SQL_PASSWORD')};"
        "Encrypt=yes;"
        "TrustServerCertificate=no;"
        "Connection Timeout=30;"
    )
    return pyodbc.connect(conn_str)


def get_openai_client() -> AzureOpenAI:
    """Create an Azure OpenAI client using Entra ID (Managed Identity)."""
    credential = DefaultAzureCredential()
    token_provider = get_bearer_token_provider(
        credential, "https://cognitiveservices.azure.com/.default"
    )
    return AzureOpenAI(
        azure_endpoint=os.getenv("AZURE_OPENAI_ENDPOINT"),
        azure_ad_token_provider=token_provider,
        api_version="2024-08-01-preview",
    )


def generate_sql(client: AzureOpenAI, question: str) -> str:
    """Stage 1: Convert natural language question to T-SQL."""
    response = client.chat.completions.create(
        model=os.getenv("AZURE_OPENAI_DEPLOYMENT", "gpt-4o"),
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": question},
        ],
        temperature=0.0,
        max_tokens=500,
    )
    sql = response.choices[0].message.content.strip()

    # Strip markdown code fences if the model includes them
    if sql.startswith("```"):
        lines = sql.split("\n")
        lines = [l for l in lines if not l.startswith("```")]
        sql = "\n".join(lines).strip()

    return sql


def execute_sql(sql: str) -> tuple[list[str], list[tuple]]:
    """Execute a SQL query and return (columns, rows)."""
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(sql)
        columns = [desc[0] for desc in cursor.description] if cursor.description else []
        rows = cursor.fetchall()
        return columns, [tuple(row) for row in rows]
    finally:
        conn.close()


def synthesize_response(
    client: AzureOpenAI,
    question: str,
    sql: str,
    columns: list[str],
    rows: list[tuple],
) -> str:
    """Stage 2: Convert SQL results to natural language answer."""
    # Format results as a readable table
    if rows:
        result_str = " | ".join(columns) + "\n"
        result_str += "-" * len(result_str) + "\n"
        for row in rows[:50]:  # Cap at 50 rows for context window
            result_str += " | ".join(str(v) for v in row) + "\n"
        if len(rows) > 50:
            result_str += f"\n... and {len(rows) - 50} more rows."
    else:
        result_str = "(No results returned)"

    user_msg = (
        f"User question: {question}\n\n"
        f"SQL query executed:\n{sql}\n\n"
        f"Results ({len(rows)} rows):\n{result_str}"
    )

    response = client.chat.completions.create(
        model=os.getenv("AZURE_OPENAI_DEPLOYMENT", "gpt-4o"),
        messages=[
            {"role": "system", "content": SYNTHESIS_PROMPT},
            {"role": "user", "content": user_msg},
        ],
        temperature=0.3,
        max_tokens=800,
    )
    return response.choices[0].message.content.strip()


def process_question(question: str) -> dict:
    """
    End-to-end pipeline: question → SQL → execute → synthesise → answer.

    Returns:
        dict with keys: question, sql, columns, rows, answer, error
    """
    result = {
        "question": question,
        "sql": None,
        "columns": [],
        "rows": [],
        "answer": None,
        "error": None,
    }

    try:
        client = get_openai_client()

        # Stage 1: Generate SQL
        sql = generate_sql(client, question)
        result["sql"] = sql

        # Stage 2: Execute SQL
        columns, rows = execute_sql(sql)
        result["columns"] = columns
        result["rows"] = rows

        # Stage 3: Synthesise natural language answer
        answer = synthesize_response(client, question, sql, columns, rows)
        result["answer"] = answer

    except pyodbc.Error as e:
        result["error"] = f"Database error: {str(e)}"
    except Exception as e:
        result["error"] = f"Error: {str(e)}"

    return result


# -----------------------------------------------------------
# CLI test harness
# -----------------------------------------------------------
if __name__ == "__main__":
    import sys

    if len(sys.argv) > 1:
        q = " ".join(sys.argv[1:])
    else:
        q = "Show me the top 5 customers by total order amount"

    print(f"\n📝 Question: {q}\n")
    res = process_question(q)

    if res["error"]:
        print(f"❌ {res['error']}")
    else:
        print(f"🔍 SQL:\n{res['sql']}\n")
        print(f"📊 Results: {len(res['rows'])} rows")
        print(f"\n💬 Answer:\n{res['answer']}")
