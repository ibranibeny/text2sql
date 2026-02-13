"""
models.py — A2A Protocol Data Models
=====================================

Implements the Google Agent-to-Agent (A2A) protocol data models.
Follows the A2A specification for agent interoperability.

Reference: https://google.github.io/A2A/
"""

from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Any, Optional
from pydantic import BaseModel, Field


# -----------------------------------------------------------
# Agent Card models (/.well-known/agent.json)
# -----------------------------------------------------------


class AgentCapabilities(BaseModel):
    """Capabilities declared by the agent."""

    streaming: bool = False
    pushNotifications: bool = False
    stateTransitionHistory: bool = False


class AgentSkill(BaseModel):
    """A skill the agent can perform."""

    id: str
    name: str
    description: str
    tags: list[str] = Field(default_factory=list)
    examples: list[str] = Field(default_factory=list)
    inputModes: list[str] = Field(default_factory=lambda: ["text"])
    outputModes: list[str] = Field(default_factory=lambda: ["text"])


class AgentProvider(BaseModel):
    """Provider information for the agent."""

    organization: str
    url: Optional[str] = None


class AgentAuthentication(BaseModel):
    """Authentication schemes supported by the agent."""

    schemes: list[str] = Field(default_factory=lambda: ["apiKey"])
    credentials: Optional[str] = None


class AgentCard(BaseModel):
    """
    The Agent Card served at /.well-known/agent.json.
    Describes the agent's identity, capabilities, and skills.
    """

    name: str
    description: str
    url: str
    version: str = "1.0.0"
    documentationUrl: Optional[str] = None
    provider: Optional[AgentProvider] = None
    capabilities: AgentCapabilities = Field(default_factory=AgentCapabilities)
    authentication: Optional[AgentAuthentication] = None
    defaultInputModes: list[str] = Field(default_factory=lambda: ["text"])
    defaultOutputModes: list[str] = Field(default_factory=lambda: ["text"])
    skills: list[AgentSkill] = Field(default_factory=list)


# -----------------------------------------------------------
# Task models (JSON-RPC task lifecycle)
# -----------------------------------------------------------


class TaskState(str, Enum):
    """Task lifecycle states per A2A spec."""

    SUBMITTED = "submitted"
    WORKING = "working"
    INPUT_REQUIRED = "input-required"
    COMPLETED = "completed"
    CANCELED = "canceled"
    FAILED = "failed"


class TextPart(BaseModel):
    """A text content part."""

    type: str = "text"
    text: str


class DataPart(BaseModel):
    """A structured data content part."""

    type: str = "data"
    data: dict[str, Any]


class FilePart(BaseModel):
    """A file content part."""

    type: str = "file"
    file: dict[str, Any]


# Union type for parts
Part = TextPart | DataPart | FilePart


class Message(BaseModel):
    """A message in the A2A conversation."""

    role: str  # "user" or "agent"
    parts: list[Part]
    metadata: Optional[dict[str, Any]] = None


class TaskStatus(BaseModel):
    """Current status of a task."""

    state: TaskState
    message: Optional[Message] = None
    timestamp: str = Field(default_factory=lambda: datetime.utcnow().isoformat() + "Z")


class Artifact(BaseModel):
    """An output artifact produced by the agent."""

    name: Optional[str] = None
    description: Optional[str] = None
    parts: list[Part]
    index: int = 0
    metadata: Optional[dict[str, Any]] = None


class Task(BaseModel):
    """A task in the A2A protocol."""

    id: str
    sessionId: Optional[str] = None
    status: TaskStatus
    messages: list[Message] = Field(default_factory=list)
    artifacts: list[Artifact] = Field(default_factory=list)
    history: list[TaskStatus] = Field(default_factory=list)
    metadata: Optional[dict[str, Any]] = None


# -----------------------------------------------------------
# JSON-RPC models
# -----------------------------------------------------------


class JSONRPCRequest(BaseModel):
    """A JSON-RPC 2.0 request."""

    jsonrpc: str = "2.0"
    id: Optional[str | int] = None
    method: str
    params: Optional[dict[str, Any]] = None


class JSONRPCResponse(BaseModel):
    """A JSON-RPC 2.0 response."""

    jsonrpc: str = "2.0"
    id: Optional[str | int] = None
    result: Optional[Any] = None
    error: Optional[dict[str, Any]] = None


class TaskSendParams(BaseModel):
    """Parameters for tasks/send method."""

    id: str
    sessionId: Optional[str] = None
    message: Message
    acceptedOutputModes: list[str] = Field(default_factory=lambda: ["text"])
    metadata: Optional[dict[str, Any]] = None


class TaskQueryParams(BaseModel):
    """Parameters for tasks/get method."""

    id: str
    historyLength: Optional[int] = None


class TaskCancelParams(BaseModel):
    """Parameters for tasks/cancel method."""

    id: str
