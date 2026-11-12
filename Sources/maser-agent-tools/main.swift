// The MCP server that `claude` starts for Maser's review agent.
//
// It speaks MCP on standard input and output: it answers the handshake and the tool list itself, and forwards each
// tool call to the running Maser over the session's Unix socket. It touches neither GitHub nor the repository. Maser
// passes the socket's path and the session's token in the environment (`MASER_AGENT_SOCKET`, `MASER_AGENT_TOKEN`)
// through the MCP config it gives `claude`, which keeps them out of the process list.

import Foundation
import MaserCore

let environment = ProcessInfo.processInfo.environment
guard let socketPath = environment["MASER_AGENT_SOCKET"], let token = environment["MASER_AGENT_TOKEN"] else {
    FileHandle.standardError.write(Data("maser-agent-tools: MASER_AGENT_SOCKET and MASER_AGENT_TOKEN must be set\n".utf8))
    exit(2)
}

while let line = readLine() {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    let answer = await AgentTools.respond(to: line, token: token) { call in
        try AgentToolServer.send(call, to: socketPath)
    }
    if let answer {
        FileHandle.standardOutput.write(Data((answer + "\n").utf8))
    }
}
