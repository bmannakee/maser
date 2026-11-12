# Spike: the stdio MCP server claude starts, forwarding each tool call to "Maser" over a Unix socket.
# Usage: helper.py <socket path> <token>
import json
import socket
import sys

SOCKET, TOKEN = sys.argv[1], sys.argv[2]

TOOLS = [
    {
        "name": "pr_context",
        "description": "The pull request under review: title, description, commits, and the full diff.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "show_diagram",
        "description": "Draw a diagram on the user's canvas. Cite source lines for each element.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "format": {"type": "string", "enum": ["mermaid", "dot"]},
                "source": {"type": "string"},
                "elements": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "id": {"type": "string"},
                            "citation": {"type": "string", "description": "path:start-end"},
                            "change": {"type": "string", "enum": ["added", "removed", "changed", "unchanged"]},
                        },
                        "required": ["id"],
                    },
                },
            },
            "required": ["title", "format", "source"],
        },
    },
    {
        "name": "add_review_comment",
        "description": "Add a line comment to the user's pending review.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "line": {"type": "integer"},
                "side": {"type": "string", "enum": ["LEFT", "RIGHT"]},
                "body": {"type": "string"},
            },
            "required": ["path", "line", "body"],
        },
    },
]


def forward(name, arguments):
    """Sends one call to Maser and returns its text answer."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(SOCKET)
        s.sendall((json.dumps({"token": TOKEN, "tool": name, "arguments": arguments}) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    return json.loads(data)


def reply(message_id, result=None, error=None):
    message = {"jsonrpc": "2.0", "id": message_id}
    if error:
        message["error"] = error
    else:
        message["result"] = result
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    if not line.strip():
        continue
    request = json.loads(line)
    method, message_id = request.get("method"), request.get("id")
    if message_id is None:
        continue  # a notification
    if method == "initialize":
        reply(message_id, {
            "protocolVersion": request["params"].get("protocolVersion", "2025-06-18"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "maser", "version": "spike"},
        })
    elif method == "tools/list":
        reply(message_id, {"tools": TOOLS})
    elif method == "tools/call":
        answer = forward(request["params"]["name"], request["params"].get("arguments", {}))
        reply(message_id, {"content": [{"type": "text", "text": answer["text"]}], "isError": answer.get("isError", False)})
    elif method == "ping":
        reply(message_id, {})
    else:
        reply(message_id, error={"code": -32601, "message": f"unknown method {method}"})
