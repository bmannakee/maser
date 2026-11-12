# Spike: drives one claude process turn by turn, as Maser will: write a message, read events until its result.
# Usage: driver.py <output jsonl> [--resume <session id>] -- <message>...
import json, os, subprocess, sys
S = os.environ["SPIKE"]  # the spike folder: repo/, mcp.json
args = sys.argv[1:]
out = open(args.pop(0), "w")
resume = []
if args[0] == "--resume":
    resume = ["--resume", args[1]]
    args = args[2:]
messages = args[args.index("--") + 1:]
command = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
           "--tools", "Read,Grep,Glob", "--strict-mcp-config", "--mcp-config", f"{S}/mcp.json", "--setting-sources", "user",
           "--permission-mode", "dontAsk", "--allowedTools", "mcp__maser__pr_context",
           "mcp__maser__show_diagram", "mcp__maser__add_review_comment", "--max-budget-usd", "1.5", "--effort", "low"] + resume
claude = subprocess.Popen(command, cwd=f"{S}/repo", stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
for message in messages:
    claude.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": message}}) + "\n")
    claude.stdin.flush()
    for line in claude.stdout:
        out.write(line)
        event = json.loads(line)
        if event.get("type") == "result":
            print(f"[{event['session_id']}] ${event['total_cost_usd']:.4f} denials={event['permission_denials']}\n{event['result']}\n")
            break
claude.stdin.close()
claude.wait()
print("exit", claude.returncode)
