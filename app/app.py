"""
app.py — Streamlit Chat Frontend for Text-to-SQL
=================================================

A conversational interface that allows users to ask natural language
questions about the SalesDB database. Uses agent.py for the AI pipeline.

Run:
  streamlit run app.py --server.port 8501 --server.headless true
"""

import streamlit as st
import pandas as pd
from agent import process_question

# -----------------------------------------------------------
# Page configuration
# -----------------------------------------------------------
st.set_page_config(
    page_title="Text-to-SQL Assistant",
    page_icon="🤖",
    layout="wide",
    initial_sidebar_state="expanded",
)

# -----------------------------------------------------------
# Sidebar
# -----------------------------------------------------------
with st.sidebar:
    st.title("🤖 Text-to-SQL Assistant")
    st.markdown("""
    **Agentic AI Workshop Demo**

    Ask natural language questions about the **SalesDB** database
    and get instant answers powered by GPT-4o.

    ---

    **Database Tables:**
    - `Customers` — 10 customers (Indonesia)
    - `Products` — 10 products (Electronics, Furniture, Stationery)
    - `Orders` — 13 orders (Jan–Jul 2024)
    - `OrderItems` — 22 line items

    ---

    **Sample Questions:**
    """)

    sample_questions = [
        "Show the top 5 customers by total spending",
        "What is the total revenue by product category?",
        "Which orders are still being processed?",
        "How many customers joined each month in 2023?",
        "What is the average order value?",
        "List products that have never been ordered",
        "Show monthly revenue trends for 2024",
        "Who ordered the most expensive product?",
    ]

    for q in sample_questions:
        if st.button(q, key=f"sample_{q}", use_container_width=True):
            st.session_state["pending_question"] = q

    st.markdown("---")
    st.caption("Powered by Azure AI Foundry + Azure SQL")

# -----------------------------------------------------------
# Chat history
# -----------------------------------------------------------
if "messages" not in st.session_state:
    st.session_state.messages = []

# Display existing chat messages
for msg in st.session_state.messages:
    with st.chat_message(msg["role"]):
        st.markdown(msg["content"])

        # Show SQL and results in expanders for assistant messages
        if msg["role"] == "assistant" and "sql" in msg:
            if msg["sql"]:
                with st.expander("🔍 Generated SQL"):
                    st.code(msg["sql"], language="sql")
            if msg.get("columns") and msg.get("rows"):
                with st.expander(f"📊 Query Results ({len(msg['rows'])} rows)"):
                    df = pd.DataFrame(msg["rows"], columns=msg["columns"])
                    st.dataframe(df, use_container_width=True)

# -----------------------------------------------------------
# Handle input
# -----------------------------------------------------------
# Check for pending question from sidebar buttons
pending = st.session_state.pop("pending_question", None)
user_input = st.chat_input("Ask a question about the database...") or pending

if user_input:
    # Display and store user message
    st.session_state.messages.append({"role": "user", "content": user_input})
    with st.chat_message("user"):
        st.markdown(user_input)

    # Process with AI agent
    with st.chat_message("assistant"):
        with st.spinner("Thinking... 🧠"):
            result = process_question(user_input)

        if result["error"]:
            st.error(f"⚠️ {result['error']}")
            assistant_msg = {
                "role": "assistant",
                "content": f"⚠️ {result['error']}",
            }
        else:
            # Display answer
            st.markdown(result["answer"])

            # Display SQL in expander
            if result["sql"]:
                with st.expander("🔍 Generated SQL"):
                    st.code(result["sql"], language="sql")

            # Display results in expander
            if result["columns"] and result["rows"]:
                with st.expander(f"📊 Query Results ({len(result['rows'])} rows)"):
                    df = pd.DataFrame(result["rows"], columns=result["columns"])
                    st.dataframe(df, use_container_width=True)

            assistant_msg = {
                "role": "assistant",
                "content": result["answer"],
                "sql": result["sql"],
                "columns": result["columns"],
                "rows": result["rows"],
            }

        st.session_state.messages.append(assistant_msg)
