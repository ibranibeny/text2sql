"""
agent.py — Agentic AI Text-to-SQL Backend
==========================================

Two-stage LLM pipeline with DYNAMIC schema discovery:
  1. discover_schema()    – Queries INFORMATION_SCHEMA to learn the database
  2. generate_sql()       – Converts natural language to SQL (temperature=0.0)
  3. synthesize_response() – Converts SQL results to natural language (temperature=0.3)

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
import pyodbc
from openai import AzureOpenAI
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from dotenv import load_dotenv

load_dotenv()

# -----------------------------------------------------------
# Schema cache (populated once on first request)
# -----------------------------------------------------------
_schema_cache: str | None = None


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


def discover_schema() -> str:
    """
    Dynamically query the database to build a schema description.
    Reads tables, columns, data types, primary keys, and foreign keys
    from INFORMATION_SCHEMA and sys catalog views.
    Results are cached after first call.
    """
    global _schema_cache
    if _schema_cache is not None:
        return _schema_cache

    conn = get_db_connection()
    try:
        cursor = conn.cursor()

        # 1. Get all user tables and their columns
        cursor.execute("""
            SELECT
                c.TABLE_NAME,
                c.COLUMN_NAME,
                c.DATA_TYPE,
                c.CHARACTER_MAXIMUM_LENGTH,
                c.NUMERIC_PRECISION,
                c.NUMERIC_SCALE,
                c.IS_NULLABLE,
                c.COLUMN_DEFAULT
            FROM INFORMATION_SCHEMA.COLUMNS c
            INNER JOIN INFORMATION_SCHEMA.TABLES t
                ON c.TABLE_NAME = t.TABLE_NAME
                AND c.TABLE_SCHEMA = t.TABLE_SCHEMA
            WHERE t.TABLE_TYPE = 'BASE TABLE'
                AND t.TABLE_SCHEMA = 'dbo'
            ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION
        """)
        columns_data = cursor.fetchall()

        # 2. Get primary keys
        cursor.execute("""
            SELECT
                kcu.TABLE_NAME,
                kcu.COLUMN_NAME
            FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
            INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
                ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
            WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
                AND tc.TABLE_SCHEMA = 'dbo'
        """)
        pk_set = {(row[0], row[1]) for row in cursor.fetchall()}

        # 3. Get foreign keys
        cursor.execute("""
            SELECT
                fk_col.TABLE_NAME AS FK_Table,
                fk_col.COLUMN_NAME AS FK_Column,
                pk_col.TABLE_NAME AS PK_Table,
                pk_col.COLUMN_NAME AS PK_Column
            FROM INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS rc
            INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE fk_col
                ON rc.CONSTRAINT_NAME = fk_col.CONSTRAINT_NAME
            INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE pk_col
                ON rc.UNIQUE_CONSTRAINT_NAME = pk_col.CONSTRAINT_NAME
        """)
        fk_list = cursor.fetchall()

        # 4. Get computed columns
        cursor.execute("""
            SELECT
                OBJECT_NAME(object_id) AS TableName,
                name AS ColumnName,
                definition AS Expression
            FROM sys.computed_columns
        """)
        computed = {(row[0], row[1]): row[2] for row in cursor.fetchall()}

        # 5. Sample a few distinct values for key columns (helps LLM understand data)
        sample_values = {}
        for table_col in [("Orders", "Status"), ("Products", "Category")]:
            try:
                tbl, col = table_col
                cursor.execute(f"SELECT DISTINCT [{col}] FROM dbo.[{tbl}]")
                vals = [str(r[0]) for r in cursor.fetchall()]
                if vals:
                    sample_values[(tbl, col)] = vals
            except Exception:
                pass

        # 6. Get row counts
        row_counts = {}
        cursor.execute("""
            SELECT
                t.name AS TableName,
                SUM(p.rows) AS Cnt
            FROM sys.tables t
            INNER JOIN sys.partitions p ON t.object_id = p.object_id
            WHERE p.index_id IN (0, 1)
                AND t.schema_id = SCHEMA_ID('dbo')
            GROUP BY t.name
        """)
        for row in cursor.fetchall():
            row_counts[row[0]] = row[1]

    finally:
        conn.close()

    # Build schema string
    db_name = os.getenv("SQL_DATABASE", "SalesDB")
    lines = [f"Database: {db_name}", ""]

    # Group columns by table
    tables: dict[str, list] = {}
    for row in columns_data:
        tbl = row[0]
        if tbl not in tables:
            tables[tbl] = []
        tables[tbl].append(row)

    relationships = []

    for tbl, cols in sorted(tables.items()):
        count = row_counts.get(tbl, "?")
        lines.append(f"Table: {tbl}  ({count} rows)")

        for col_row in cols:
            _, col_name, dtype, char_len, num_prec, num_scale, nullable, default = col_row

            # Format type
            if char_len and char_len > 0:
                type_str = f"{dtype.upper()}({char_len})"
            elif num_prec and num_scale and num_scale > 0:
                type_str = f"{dtype.upper()}({num_prec},{num_scale})"
            else:
                type_str = dtype.upper()

            # Annotations
            annotations = []
            if (tbl, col_name) in pk_set:
                annotations.append("PK")
            if nullable == "NO" and (tbl, col_name) not in pk_set:
                annotations.append("NOT NULL")
            if (tbl, col_name) in computed:
                annotations.append(f"computed: {computed[(tbl, col_name)]}")
            if default:
                annotations.append(f"default: {default}")

            # Sample values
            if (tbl, col_name) in sample_values:
                vals = ", ".join(sample_values[(tbl, col_name)])
                annotations.append(f"values: {vals}")

            ann_str = f"  ({', '.join(annotations)})" if annotations else ""
            lines.append(f"  - {col_name}  {type_str}{ann_str}")

        lines.append("")

    # Foreign key relationships
    if fk_list:
        lines.append("Relationships:")
        for fk_row in fk_list:
            fk_tbl, fk_col, pk_tbl, pk_col = fk_row
            lines.append(f"  {fk_tbl}.{fk_col} -> {pk_tbl}.{pk_col}")
            relationships.append(f"{fk_tbl}.{fk_col} -> {pk_tbl}.{pk_col}")
        lines.append("")

    schema_str = "\n".join(lines)
    _schema_cache = schema_str
    return schema_str


def get_system_prompt() -> str:
    """Build the system prompt with dynamically discovered schema."""
    schema = discover_schema()
    return f"""You are an expert SQL query generator for Microsoft SQL Server (Azure SQL).
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
{schema}
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
    system_prompt = get_system_prompt()
    response = client.chat.completions.create(
        model=os.getenv("AZURE_OPENAI_DEPLOYMENT", "gpt-4o"),
        messages=[
            {"role": "system", "content": system_prompt},
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
    if rows:
        result_str = " | ".join(columns) + "\n"
        result_str += "-" * len(result_str) + "\n"
        for row in rows[:50]:
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
    End-to-end pipeline: question -> SQL -> execute -> synthesise -> answer.

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


def reset_schema_cache():
    """Clear the cached schema (useful if tables change)."""
    global _schema_cache
    _schema_cache = None


# -----------------------------------------------------------
# CLI test harness
# -----------------------------------------------------------
if __name__ == "__main__":
    import sys

    if len(sys.argv) > 1:
        q = " ".join(sys.argv[1:])
    else:
        q = "Show me the top 5 customers by total order amount"

    print(f"\nDiscovering database schema...")
    schema = discover_schema()
    print(f"Schema discovered:\n{schema}\n")

    print(f"Question: {q}\n")
    res = process_question(q)

    if res["error"]:
        print(f"Error: {res['error']}")
    else:
        print(f"SQL:\n{res['sql']}\n")
        print(f"Results: {len(res['rows'])} rows")
        print(f"\nAnswer:\n{res['answer']}")
