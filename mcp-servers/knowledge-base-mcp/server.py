"""Knowledge Base MCP Server — exposes LlamaStack vector store search as tools."""

import os
import json
import logging
import urllib.request
import urllib.error
from mcp.server.fastmcp import FastMCP

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("knowledge-base-mcp")

LLAMASTACK_URL = os.environ.get(
    "LLAMASTACK_URL",
    "http://self-healing-agent-service.rhoai-project.svc.cluster.local:8321",
)
VECTOR_STORE_ID = os.environ.get("VECTOR_STORE_ID", "")
VECTOR_STORE_NAME = os.environ.get("VECTOR_STORE_NAME", "ops-knowledge-base")
DEFAULT_TOP_K = int(os.environ.get("DEFAULT_TOP_K", "5"))

mcp = FastMCP(
    "Knowledge Base",
    instructions=(
        "This server provides access to the operational knowledge base "
        "containing runbooks, reference patterns, and best practices for "
        "OpenShift cluster operations. Use 'search_knowledge_base' to find "
        "relevant operational guidance for alerts, incidents, or procedures."
    ),
)


def _http_json(url: str, method: str = "GET", payload: dict | None = None) -> dict:
    """Send an HTTP request and return parsed JSON."""
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"Content-Type": "application/json"} if data else {}
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


_cached_store_id: str | None = None


def _resolve_store_id() -> str:
    global _cached_store_id
    if _cached_store_id:
        return _cached_store_id
    if VECTOR_STORE_ID:
        _cached_store_id = VECTOR_STORE_ID
        return VECTOR_STORE_ID

    resp = _http_json(f"{LLAMASTACK_URL}/v1/vector_stores")
    stores = resp.get("data", []) if isinstance(resp, dict) else resp
    for s in stores:
        sid = s.get("id", "") if isinstance(s, dict) else str(s)
        sname = s.get("name", "") if isinstance(s, dict) else ""
        if sname == VECTOR_STORE_NAME or sid == VECTOR_STORE_NAME:
            _cached_store_id = sid
            log.info("Resolved vector store '%s' -> %s", VECTOR_STORE_NAME, sid)
            return sid
    raise ValueError(f"Vector store '{VECTOR_STORE_NAME}' not found")


def _format_search_results(data: list[dict]) -> str:
    parts = []
    for i, hit in enumerate(data, 1):
        filename = hit.get("filename", "")
        score = hit.get("score", 0)
        content_blocks = hit.get("content", [])
        text = "\n".join(
            b.get("text", "") for b in content_blocks if isinstance(b, dict)
        ).strip()
        if not text:
            text = str(content_blocks)

        header = f"### Result {i}"
        if filename:
            header += f" — {filename}"
        if isinstance(score, (int, float)):
            header += f" (score: {score:.2f})"

        parts.append(f"{header}\n{text}")
    return "\n\n---\n\n".join(parts) if parts else "No results found."


@mcp.tool()
def search_knowledge_base(query: str, max_results: int = DEFAULT_TOP_K) -> str:
    """Search the operational knowledge base for runbooks, remediation
    procedures, and reference patterns related to OpenShift cluster alerts,
    incidents, or operations.

    Use this tool when you need guidance on:
    - How to remediate a specific alert (e.g. KubeNodeNotReady, ClusterOperatorDegraded)
    - Approved operational procedures and runbooks
    - Ansible module patterns for Kubernetes/OpenShift automation
    - Best practices for cluster recovery

    Args:
        query: Natural language description of what you're looking for.
               Be specific — include alert names, component names, or
               symptom descriptions for best results.
        max_results: Number of results to return (1-10, default 5).
    """
    max_results = max(1, min(10, max_results))
    store_id = _resolve_store_id()
    log.info("Searching knowledge base for: %s (top %d)", query, max_results)

    resp = _http_json(
        f"{LLAMASTACK_URL}/v1/vector_stores/{store_id}/search",
        method="POST",
        payload={"query": query, "max_num_results": max_results},
    )

    data = resp.get("data", []) if isinstance(resp, dict) else resp
    if not data:
        return "No relevant documents found in the knowledge base."

    return _format_search_results(data)


@mcp.tool()
def list_knowledge_base_documents() -> str:
    """List all documents indexed in the operational knowledge base.

    Use this to understand what knowledge is available before searching.
    Returns document names and types (runbooks, references, etc.).
    """
    store_id = _resolve_store_id()

    resp = _http_json(
        f"{LLAMASTACK_URL}/v1/vector_stores/{store_id}/search",
        method="POST",
        payload={"query": "list all runbooks and references", "max_num_results": 20},
    )

    data = resp.get("data", []) if isinstance(resp, dict) else resp
    seen = set()
    docs = []
    for hit in data:
        fname = hit.get("filename", "")
        if fname and fname not in seen:
            seen.add(fname)
            doc_type = "runbook" if "runbook" in fname.lower() else "reference"
            docs.append(f"- **{fname}** ({doc_type})")

    if not docs:
        return "No documents found in the knowledge base."

    return f"**Knowledge Base Documents** ({len(docs)} indexed):\n\n" + "\n".join(docs)


if __name__ == "__main__":
    mcp.run(transport="stdio")
