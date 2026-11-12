// The Unix socket where Maser answers the review agent's tool calls.
//
// Each agent session gets a private folder (mode 700) holding the socket, and a random token. The `maser-agent-tools`
// helper, which `claude` starts, connects once per call, sends one JSON line with the token, the tool and its
// arguments, and reads one JSON line back. Maser listens on no network port, and a call without the session's token is
// refused before any work is done.

import Darwin
import Foundation

/// Listens on a Unix socket for one agent session's tool calls.
///
/// `@unchecked Sendable` is safe because the only mutable state, the listening descriptor, is guarded by `lock`, and the
/// handler is itself `Sendable`.
public final class AgentToolServer: @unchecked Sendable {
    /// Why the server couldn't start.
    public enum Failure: Error, Equatable, LocalizedError {
        /// The socket's path is longer than macOS allows (104 bytes).
        case pathTooLong(String)
        /// A socket call failed.
        case socket(String, Int32)

        /// A sentence for the Agent tab.
        public var errorDescription: String? {
            switch self {
            case let .pathTooLong(path): "The agent's socket path is too long: \(path)"
            case let .socket(call, code): "The agent's socket failed at \(call): \(String(cString: strerror(code)))"
            }
        }
    }

    /// The private folder holding the socket.
    public let folder: URL
    /// The socket's path.
    public let socketPath: String
    /// The secret every call must carry.
    public let token: String
    /// Does the work for a call that carried the right token.
    private let handler: @Sendable (AgentTools.Call) async -> AgentTools.Reply
    /// Guards `descriptor`.
    private let lock = NSLock()
    /// The listening socket, or -1 once stopped.
    private var descriptor: Int32 = -1

    /// The most a call may hold, so a runaway client can't exhaust memory.
    static let maxMessageBytes = 4_000_000

    /// Creates a private folder and starts listening in it.
    ///
    /// - Parameter handler: Runs a call with a valid token and returns the agent's answer.
    /// - Throws: `Failure` if the folder or socket can't be made.
    public init(handler: @escaping @Sendable (AgentTools.Call) async -> AgentTools.Reply) throws {
        // The system temporary folder is short enough for a socket path; Application Support isn't.
        var template = Array((FileManager.default.temporaryDirectory.path(percentEncoded: false) + "maser-XXXXXX").utf8CString)
        guard let made = mkdtemp(&template) else { throw Failure.socket("mkdtemp", errno) }
        folder = URL(filePath: String(cString: made))
        chmod(made, 0o700)
        socketPath = folder.appending(path: "s").path(percentEncoded: false)
        token = UUID().uuidString + UUID().uuidString
        self.handler = handler
        guard socketPath.utf8.count < 104 else { throw Failure.pathTooLong(socketPath) }

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failure.socket("socket", errno) }
        var address = Self.address(socketPath)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(listener, 16) == 0 else {
            let code = errno
            close(listener)
            throw Failure.socket("bind", code)
        }
        descriptor = listener
        let thread = Thread { [self] in acceptLoop(listener) }
        thread.name = "AgentToolServer"
        thread.start()
    }

    deinit { stop() }

    /// Stops listening and removes the socket and its folder.
    public func stop() {
        let listener = lock.withLock {
            defer { descriptor = -1 }
            return descriptor
        }
        guard listener >= 0 else { return }
        // Closing the socket ends the blocking accept().
        shutdown(listener, SHUT_RDWR)
        close(listener)
        try? FileManager.default.removeItem(at: folder)
    }

    /// Accepts connections until the socket is closed, handling each on its own task.
    ///
    /// - Parameter listener: The listening socket.
    private func acceptLoop(_ listener: Int32) {
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else {
                if errno == EINTR { continue }
                return
            }
            Task { await self.serve(connection) }
        }
    }

    /// Reads one call from a connection, answers it, and closes the connection.
    ///
    /// - Parameter connection: The accepted socket.
    private func serve(_ connection: Int32) async {
        defer { close(connection) }
        let reply: AgentTools.Reply
        if let data = Self.readLine(connection), let call = try? JSONDecoder().decode(AgentTools.Call.self, from: data) {
            reply =
                Self.tokensMatch(call.token, token)
                ? await handler(call) : AgentTools.Reply(text: "Refused: wrong session token.", isError: true)
        } else {
            reply = AgentTools.Reply(text: "Refused: the call couldn't be read.", isError: true)
        }
        Self.writeLine(connection, (try? JSONEncoder().encode(reply)) ?? Data())
    }

    // MARK: - Client

    /// Sends one call to a session's server and waits for its reply; what the helper does for each tool call.
    ///
    /// - Parameters:
    ///   - call: The call, with the session's token.
    ///   - socketPath: The server's socket.
    /// - Returns: Maser's reply.
    /// - Throws: `Failure` if the socket can't be reached, or a decoding error for an unreadable reply.
    public static func send(_ call: AgentTools.Call, to socketPath: String) throws -> AgentTools.Reply {
        let connection = socket(AF_UNIX, SOCK_STREAM, 0)
        guard connection >= 0 else { throw Failure.socket("socket", errno) }
        defer { close(connection) }
        var address = address(socketPath)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(connection, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure.socket("connect", errno) }
        writeLine(connection, try JSONEncoder().encode(call))
        guard let data = readLine(connection) else { throw Failure.socket("read", errno) }
        return try JSONDecoder().decode(AgentTools.Reply.self, from: data)
    }

    // MARK: - Socket helpers

    /// A Unix socket address for a path that fits.
    ///
    /// - Parameter path: The socket's path, under 104 bytes.
    /// - Returns: The address.
    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8.prefix(buffer.count - 1))
            buffer.copyBytes(from: bytes)
        }
        return address
    }

    /// Reads up to the first newline, or the end of the stream.
    ///
    /// - Parameter connection: The socket.
    /// - Returns: The bytes before the newline, or nil on an error, an empty message, or one over the size limit.
    private static func readLine(_ connection: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count <= maxMessageBytes {
            let count = read(connection, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            if let newline = buffer[0..<count].firstIndex(of: UInt8(ascii: "\n")) {
                data.append(contentsOf: buffer[0..<newline])
                return data
            }
            data.append(contentsOf: buffer[0..<count])
        }
        return data.isEmpty || data.count > maxMessageBytes ? nil : data
    }

    /// Writes a message and a newline.
    ///
    /// - Parameters:
    ///   - connection: The socket.
    ///   - data: The message, which mustn't contain a newline (JSON encoding never does).
    private static func writeLine(_ connection: Int32, _ data: Data) {
        var bytes = [UInt8](data)
        bytes.append(UInt8(ascii: "\n"))
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return }
            offset += written
        }
    }

    /// Compares two tokens in time that doesn't depend on where they differ.
    ///
    /// - Parameters:
    ///   - a: One token.
    ///   - b: The other.
    /// - Returns: True if they're equal.
    static func tokensMatch(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
