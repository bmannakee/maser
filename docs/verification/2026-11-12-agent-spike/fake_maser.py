# Spike: stands in for Maser's tool server. Listens on a Unix socket, checks the token, logs each call, answers.
# Usage: fake_maser.py <socket path> <token> <log path>
import json
import os
import socket
import sys

SOCKET, TOKEN, LOG = sys.argv[1], sys.argv[2], sys.argv[3]
DESCRIPTION = open(sys.argv[4]).read() if len(sys.argv) > 4 else "Adds a safety transition."

DIFF = """diff --git a/Sources/Door.swift b/Sources/Door.swift
--- a/Sources/Door.swift
+++ b/Sources/Door.swift
@@ -13,6 +13,8 @@ struct Door {
         case (.locked, "unlock"): state = .closed
+        // Safety: an obstruction while closing reopens the door.
+        case (.closing, "obstructed"): state = .opening
         default: break
"""

ANSWERS = {
    "pr_context": json.dumps({
        "title": "Reopen the door when it's obstructed while closing",
        "description": DESCRIPTION,
        "commits": [{"oid": "5feda13", "message": "Door controller"}],
        "diff": DIFF,
    }),
    "show_diagram": "Shown on the canvas.",
    "add_review_comment": "Added to your pending review.",
}

if os.path.exists(SOCKET):
    os.remove(SOCKET)
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(SOCKET)
os.chmod(SOCKET, 0o600)
server.listen()
while True:
    connection, _ = server.accept()
    with connection:
        data = b""
        while not data.endswith(b"\n"):
            chunk = connection.recv(65536)
            if not chunk:
                break
            data += chunk
        call = json.loads(data)
        ok = call.get("token") == TOKEN
        with open(LOG, "a") as log:
            log.write(json.dumps({"tool": call.get("tool"), "tokenOK": ok, "arguments": call.get("arguments")}) + "\n")
        answer = {"text": ANSWERS.get(call.get("tool"), "unknown tool")} if ok else {"text": "bad token", "isError": True}
        connection.sendall((json.dumps(answer) + "\n").encode())
