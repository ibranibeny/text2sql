"""
handler.py — A2A Task Handler for Text-to-SQL Agent
====================================================

Bridges the A2A protocol with the existing agent.py pipeline.
Manages task lifecycle: submitted → working → completed/failed.
"""

from __future__ import annotations

import threading
import uuid
from datetime import datetime
from typing import Optional

from models import (
    Artifact,
    DataPart,
    Message,
    Part,
    Task,
    TaskCancelParams,
    TaskQueryParams,
    TaskSendParams,
    TaskState,
    TaskStatus,
    TextPart,
)

# Import the existing agent module (same directory on VM after deployment)
import agent


class TaskStore:
    """Thread-safe in-memory task store."""

    def __init__(self) -> None:
        self._tasks: dict[str, Task] = {}
        self._lock = threading.Lock()

    def get(self, task_id: str) -> Optional[Task]:
        with self._lock:
            return self._tasks.get(task_id)

    def set(self, task: Task) -> None:
        with self._lock:
            self._tasks[task.id] = task

    def delete(self, task_id: str) -> bool:
        with self._lock:
            return self._tasks.pop(task_id, None) is not None


# Global task store
task_store = TaskStore()


def _extract_question(message: Message) -> str:
    """Extract the text question from a Message's parts."""
    texts = []
    for part in message.parts:
        if isinstance(part, TextPart):
            texts.append(part.text)
        elif isinstance(part, dict):
            # Handle raw dict from JSON deserialization
            if part.get("type") == "text":
                texts.append(part.get("text", ""))
    return " ".join(texts).strip()


def _now_iso() -> str:
    return datetime.utcnow().isoformat() + "Z"


def handle_task_send(params: TaskSendParams) -> Task:
    """
    Handle tasks/send — process a user message synchronously.

    1. Creates/retrieves the task
    2. Transitions to 'working'
    3. Runs the Text-to-SQL pipeline via agent.process_question()
    4. Transitions to 'completed' (or 'failed')
    5. Returns the updated task
    """
    task_id = params.id or str(uuid.uuid4())

    # Check for existing task
    task = task_store.get(task_id)

    if task is None:
        task = Task(
            id=task_id,
            sessionId=params.sessionId or str(uuid.uuid4()),
            status=TaskStatus(state=TaskState.SUBMITTED, timestamp=_now_iso()),
            messages=[],
            artifacts=[],
            history=[],
            metadata=params.metadata,
        )

    # Append user message
    task.messages.append(params.message)

    # Transition to working
    working_status = TaskStatus(state=TaskState.WORKING, timestamp=_now_iso())
    task.history.append(task.status)
    task.status = working_status
    task_store.set(task)

    # Extract question text
    question = _extract_question(params.message)

    if not question:
        # No question found — fail
        fail_msg = Message(
            role="agent",
            parts=[TextPart(text="No question found in the message. Please send a text question.")],
        )
        fail_status = TaskStatus(
            state=TaskState.FAILED,
            message=fail_msg,
            timestamp=_now_iso(),
        )
        task.history.append(task.status)
        task.status = fail_status
        task_store.set(task)
        return task

    try:
        # Run the Text-to-SQL pipeline
        result = agent.process_question(question)

        if result.get("error"):
            # Pipeline returned an error
            error_msg = Message(
                role="agent",
                parts=[TextPart(text=f"Error processing query: {result['error']}")],
            )
            fail_status = TaskStatus(
                state=TaskState.FAILED,
                message=error_msg,
                timestamp=_now_iso(),
            )
            task.history.append(task.status)
            task.status = fail_status
            task.messages.append(error_msg)
            task_store.set(task)
            return task

        # Build the agent response message
        answer_text = result.get("answer", "No answer generated.")
        agent_msg = Message(
            role="agent",
            parts=[TextPart(text=answer_text)],
        )

        # Build artifacts with structured data
        artifacts = []

        # Artifact 0: The natural language answer
        artifacts.append(
            Artifact(
                name="answer",
                description="Natural language answer to the user's question",
                parts=[TextPart(text=answer_text)],
                index=0,
            )
        )

        # Artifact 1: Structured result data (SQL, columns, rows)
        structured_data = {
            "question": result.get("question", question),
            "sql": result.get("sql"),
            "columns": result.get("columns", []),
            "rows": [list(row) for row in result.get("rows", [])][:50],
            "row_count": len(result.get("rows", [])),
        }
        artifacts.append(
            Artifact(
                name="query_result",
                description="Structured SQL query and result data",
                parts=[DataPart(data=structured_data)],
                index=1,
            )
        )

        # Transition to completed
        completed_status = TaskStatus(
            state=TaskState.COMPLETED,
            message=agent_msg,
            timestamp=_now_iso(),
        )
        task.history.append(task.status)
        task.status = completed_status
        task.messages.append(agent_msg)
        task.artifacts = artifacts
        task_store.set(task)
        return task

    except Exception as e:
        error_msg = Message(
            role="agent",
            parts=[TextPart(text=f"Internal error: {str(e)}")],
        )
        fail_status = TaskStatus(
            state=TaskState.FAILED,
            message=error_msg,
            timestamp=_now_iso(),
        )
        task.history.append(task.status)
        task.status = fail_status
        task.messages.append(error_msg)
        task_store.set(task)
        return task


def handle_task_get(params: TaskQueryParams) -> Optional[Task]:
    """
    Handle tasks/get — retrieve a task by ID.
    Optionally truncate history to historyLength.
    """
    task = task_store.get(params.id)
    if task is None:
        return None

    if params.historyLength is not None:
        # Return only the last N history entries
        task_copy = task.model_copy(deep=True)
        task_copy.history = task_copy.history[-params.historyLength :]
        return task_copy

    return task


def handle_task_cancel(params: TaskCancelParams) -> Optional[Task]:
    """
    Handle tasks/cancel — cancel a task.
    Only tasks in submitted/working state can be canceled.
    """
    task = task_store.get(params.id)
    if task is None:
        return None

    if task.status.state in (TaskState.SUBMITTED, TaskState.WORKING):
        cancel_msg = Message(
            role="agent",
            parts=[TextPart(text="Task was canceled by the user.")],
        )
        cancel_status = TaskStatus(
            state=TaskState.CANCELED,
            message=cancel_msg,
            timestamp=_now_iso(),
        )
        task.history.append(task.status)
        task.status = cancel_status
        task_store.set(task)

    return task
