// One PR's conversation with the review agent: the transcript, the `claude` process, its tool server and checkout.
//
// `AgentSession` is created with its `ReviewModel` and loads the PR's saved transcript. The first message prepares the
// read-only checkout of the diff's head commit, starts the tool server, and runs the user's `claude` with the
// confining command line from `AgentCommandLine`, resuming the saved session if there is one. The process stays up
// between turns; each message is written only after the previous turn's result. A new head commit, model or effort
// restarts it, resuming the same session, in the same per-PR checkout folder. Tool calls arrive on the tool server and
// are answered from what the review has loaded.

import Foundation
import MaserCore
import Observation

/// The review agent's conversation about one PR.
@MainActor @Observable
final class AgentSession {
    /// What the session is doing.
    enum Status: Equatable {
        /// Waiting for a message.
        case idle
        /// Getting ready to answer: preparing the checkout or starting `claude`.
        case preparing(String)
        /// The agent is answering.
        case answering
        /// The last attempt failed; the message says why.
        case failed(String)
    }

    /// The pull request the conversation is about.
    let pr: PullRequest
    /// The review the conversation belongs to, for the diff, threads and head commit.
    @ObservationIgnored weak var review: ReviewModel?
    /// The conversation as the Agent tab shows it.
    private(set) var transcript: AgentTranscript
    /// What the session is doing.
    private(set) var status = Status.idle
    /// The folder the agent reads, once prepared.
    private(set) var checkoutPath: String?
    /// The message being written.
    var draft = ""
    /// Set to ask the Agent tab to focus the message box; it clears this once it has.
    var focusRequest = false

    // Canvas
    /// The diagram on the canvas, by ID; nil shows the newest.
    var selectedDiagramID: String?
    /// The selected element of the diagram on the canvas, by its index in the agent's list.
    var selectedElement: Int?
    /// Whether the Agent tab shows the canvas beside the conversation.
    var showsCanvas = true
    /// Lines an element cites outside the diff, opened read-only from the checkout.
    var openedCitation: OpenedCitation?
    /// Renders diagrams, loaded with Pele on first use.
    @ObservationIgnored private var renderer: DiagramRenderer?
    /// The model the running session reports, for the attribution on the agent's comments.
    @ObservationIgnored private var sessionModel: String?

    /// The running `claude`, if any.
    @ObservationIgnored private var process: Process?
    /// Where messages are written to the running `claude`.
    @ObservationIgnored private var input: FileHandle?
    /// The tool server for the running `claude`.
    @ObservationIgnored private var server: AgentToolServer?
    /// What the running process was started with, to tell when it must restart.
    @ObservationIgnored private var running: (commit: String, model: String?, effort: AgentSettings.Effort?)?
    /// Counts processes started, so output from a stopped one is ignored.
    @ObservationIgnored private var generation = 0
    /// The end of the running process's standard error, to explain a failure.
    @ObservationIgnored private var errorTail = ErrorTail()
    /// The message sent with `--resume`, kept to send again on a new session if the old one can't be resumed.
    ///
    /// Cleared once the resumed session reports that it started.
    @ObservationIgnored private var resumedMessage: String?
    /// Whether the running process was started with `--resume`, until its first message is sent.
    @ObservationIgnored private var startedWithResume = false

    /// Where every PR's transcript is kept, beside the unsent text, in a folder named for the app's bundle.
    static let store = AgentTranscriptStore(
        directory: URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "dev.maser.Maser")
            .appending(path: "Agent/Conversations"))
    /// Where the agent's checkouts are kept.
    static let checkoutRoot = URL.applicationSupportDirectory.appending(
        path: Bundle.main.bundleIdentifier ?? "dev.maser.Maser"
    )
    .appending(path: "Agent/Checkouts")

    // Ending the session ends `claude` and removes the socket's folder.
    isolated deinit { stopProcess() }

    /// Creates the session for a PR, with its saved transcript.
    ///
    /// - Parameter pr: The pull request.
    init(pr: PullRequest) {
        self.pr = pr
        do {
            transcript = try Self.store.load(for: pr)
        } catch {
            NSLog("Couldn't read the agent conversation for %@: %@", pr.url.absoluteString, error.localizedDescription)
            transcript = AgentTranscript()
        }
    }

    // MARK: - What the tab shows

    /// The `[agent] allow` rule that lets the agent read this PR, or nil if it's off.
    var allowRule: AgentSettings.AllowRule? { ConfigStore.shared.settings.agent.allowRule(for: pr) }
    /// The model in use: this PR's choice, else the setting, else nil for the user's own default.
    var model: String? { transcript.model ?? ConfigStore.shared.settings.agent.model }
    /// The effort in use: this PR's choice, else the setting, else nil for the user's own default.
    var effort: AgentSettings.Effort? {
        transcript.effort.flatMap(AgentSettings.Effort.init(rawValue:)) ?? ConfigStore.shared.settings.agent.effort
    }
    /// Whether the conversation is about an older commit than the diff now shows.
    var isStale: Bool {
        guard let commit = transcript.commit, let head = review?.diffCommitID else { return false }
        return commit != head
    }
    /// Whether a message can be sent now.
    var canSend: Bool {
        allowRule != nil && review?.diffCommitID != nil && status != .answering && !isPreparing
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// Whether the session is getting ready.
    var isPreparing: Bool {
        if case .preparing = status { return true }
        return false
    }

    /// Chooses the model for this PR's conversation; nil goes back to the setting.
    ///
    /// - Parameter model: The model.
    func setModel(_ model: String?) {
        transcript.model = model?.isEmpty == true ? nil : model
        save()
    }

    /// Chooses the effort for this PR's conversation; nil goes back to the setting.
    ///
    /// - Parameter effort: The effort.
    func setEffort(_ effort: AgentSettings.Effort?) {
        transcript.effort = effort?.rawValue
        save()
    }

    // MARK: - Talking to the agent

    /// Sends `draft` to the agent, starting or restarting `claude` first when needed.
    ///
    /// Does nothing if the agent is off for this PR, the diff hasn't loaded, or a turn is under way.
    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, let head = review?.diffCommitID else { return }
        draft = ""
        var message = text
        if let old = transcript.commit, old != head {
            let note = "The PR's head moved from \(old.prefix(7)) to \(head.prefix(7)). The agent now reads the new commit."
            transcript.entries.append(.notice(note))
            message =
                "[Maser: the PR's head commit changed from \(old) to \(head) since your last answer. Your checkout "
                + "and pr_context now show \(head). Re-read what you rely on.]\n\n\(text)"
        }
        transcript.entries.append(.user(text))
        save()
        do {
            if process == nil || running?.commit != head || running?.model != model || running?.effort != effort {
                stopProcess()
                try await start(at: head)
            }
            transcript.commit = head
            save()
            status = .answering
            resumedMessage = startedWithResume ? message : nil
            startedWithResume = false
            write(message)
        } catch {
            status = .failed(error.localizedDescription)
            transcript.entries.append(.notice("Couldn't start the agent: \(error.localizedDescription)"))
            save()
        }
    }

    /// Stops the turn under way by stopping `claude`; the next message resumes the session.
    func stop() {
        guard status == .answering || isPreparing else { return }
        stopProcess()
        status = .idle
        transcript.entries.append(.notice("Stopped."))
        save()
    }

    /// Forgets the conversation: stops `claude`, and deletes the transcript and the session to resume.
    func clear() {
        stopProcess()
        let (model, effort) = (transcript.model, transcript.effort)
        transcript = AgentTranscript()
        transcript.model = model
        transcript.effort = effort
        status = .idle
        save()
    }

    /// Stops `claude` and the tool server, if they're running.
    func stopProcess() {
        generation += 1
        if let process, process.isRunning { process.terminate() }
        try? input?.close()
        process = nil
        input = nil
        running = nil
        server?.stop()
        server = nil
    }

    /// Prepares the checkout and starts `claude` in it.
    ///
    /// - Parameter head: The commit the conversation is about.
    /// - Throws: An error saying what's missing or failed, for the tab to show.
    private func start(at head: String) async throws {
        let settings = ConfigStore.shared.settings.agent
        status = .preparing("Finding claude…")
        guard let claude = await AgentCommandLine.locateClaude(configured: settings.claudePath) else {
            throw AgentFailure(
                settings.claudePath == nil
                    ? "claude wasn't found. Install Claude Code, or set [agent] claude in config.toml."
                    : "[agent] claude isn't an executable: \(settings.claudePath ?? "")")
        }
        guard let helper = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "maser-agent-tools"),
            FileManager.default.isExecutableFile(atPath: helper.path(percentEncoded: false))
        else { throw AgentFailure("Maser's agent helper (maser-agent-tools) is missing from the app.") }

        status = .preparing("Preparing a read-only checkout of \(head.prefix(7))…")
        let checkout = try await prepareCheckout(at: head)
        checkoutPath = checkout.path(percentEncoded: false)

        status = .preparing("Starting claude…")
        let server = try AgentToolServer { [weak self] call in
            await self?.answer(call) ?? AgentTools.Reply(text: "Maser closed this conversation.", isError: true)
        }
        let config = server.folder.appending(path: "mcp.json")
        try AgentCommandLine.mcpConfig(
            helper: helper.path(percentEncoded: false), socketPath: server.socketPath, token: server.token
        ).write(to: config)

        let process = Process()
        process.executableURL = claude
        process.arguments = AgentCommandLine.arguments(
            .init(
                mcpConfigPath: config.path(percentEncoded: false), systemPrompt: AgentCommandLine.systemPrompt(for: pr),
                model: model, effort: effort, maxBudgetUSD: settings.maxBudgetUSD, resumeSessionID: transcript.sessionID))
        process.currentDirectoryURL = checkout
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        generation += 1
        let thisGeneration = generation
        let (lines, continuation) = AsyncStream<String>.makeStream()
        let buffer = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in buffer.append(data) { continuation.yield(line) }
        }
        let tail = ErrorTail()
        errorTail = tail
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { tail.append(data) }
        }
        try process.run()
        startedWithResume = transcript.sessionID != nil
        self.process = process
        self.input = input.fileHandleForWriting
        self.server = server
        running = (head, model, effort)
        Task { [weak self] in
            for await line in lines {
                guard let self, self.generation == thisGeneration else { return }
                self.handle(line)
            }
            self?.ended(generation: thisGeneration)
        }
    }

    /// Returns the folder the agent reads: a read-only checkout of the commit, made or reused.
    ///
    /// - Parameter head: The commit.
    /// - Returns: The checkout's folder.
    /// - Throws: `AgentCheckout.Failure`, or the errors from finding `gh`.
    private func prepareCheckout(at head: String) async throws -> URL {
        #if DEBUG
            // The UI scenarios use a fixed folder: their recorded PRs' commits can't be fetched without real GitHub.
            if let folder = ProcessInfo.processInfo.environment["MASER_AGENT_CHECKOUT"] { return URL(filePath: folder) }
        #endif
        let repository = AgentCheckout.Repository(pr)
        let checkout = AgentCheckout(root: Self.checkoutRoot)
        let clone = await checkout.findLocalClone(of: repository, in: ConfigStore.shared.settings.agent.repositories)
        let gh = try await GitHubCLI.executablePath()
        return try await checkout.prepare(
            repository, commit: head, pullNumber: pr.number, localClone: clone, remote: repository.httpsURL,
            credentialHelper: "!\"\(gh)\" auth git-credential")
    }

    /// Writes one message to the running `claude`.
    ///
    /// - Parameter message: The message.
    private func write(_ message: String) {
        input?.write(Data(AgentCommandLine.messageLine(message).utf8))
    }

    /// Records one line of the agent's output.
    ///
    /// - Parameter line: A stream-json line.
    private func handle(_ line: String) {
        for event in AgentEvent.decode(line) {
            transcript.record(event)
            switch event {
            case let .started(session):
                resumedMessage = nil
                sessionModel = session.model
            case .finished: status = .idle
            default: break
            }
        }
        save()
    }

    /// Handles the end of a `claude` process's output.
    ///
    /// If it ended mid-turn, says so with the end of its error output. A session that couldn't be resumed is forgotten,
    /// and the message is sent again on a new one.
    ///
    /// - Parameter generation: Which process ended.
    private func ended(generation: Int) {
        guard generation == self.generation else { return }
        let wasAnswering = status == .answering
        let message = resumedMessage
        let detail = errorTail.text
        stopProcess()
        guard wasAnswering else { return }
        if let message, transcript.sessionID != nil {
            transcript.sessionID = nil
            transcript.entries.append(.notice("The previous session couldn't be resumed, so the agent started a new one."))
            save()
            status = .idle
            Task {
                guard let head = review?.diffCommitID else { return }
                do {
                    try await start(at: head)
                    status = .answering
                    resumedMessage = nil
                    write(message)
                } catch {
                    status = .failed(error.localizedDescription)
                }
            }
            return
        }
        let reason = detail.isEmpty ? "The agent stopped unexpectedly." : "The agent stopped: \(detail)"
        status = .failed(reason)
        transcript.entries.append(.notice(reason))
        save()
    }

    /// Answers a tool call from the agent.
    ///
    /// - Parameter call: The call, whose token the server has checked.
    /// - Returns: The answer the agent sees.
    private func answer(_ call: AgentTools.Call) async -> AgentTools.Reply {
        guard let review else { return AgentTools.Reply(text: "The review is closed.", isError: true) }
        switch call.tool {
        case "pr_context":
            guard let head = review.diffCommitID, head == transcript.commit else {
                return AgentTools.Reply(
                    text: "The PR's diff changed since this message was sent. Ask the user to send a new message.", isError: true)
            }
            let commits: [PullRequestCommit]
            var note = ""
            do {
                commits = try await GitHubCLI().commits(for: pr)
            } catch {
                commits = []
                note = "\n(The commit list couldn't be loaded: \(error.localizedDescription))\n"
            }
            return AgentTools.Reply(
                text: AgentPRContext.render(
                    pr: pr, overview: review.overview, headCommit: head, commits: commits, files: review.diffFiles,
                    threads: review.allThreads) + note)
        case "show_diagram":
            return draw(call.arguments, review: review)
        case "add_review_comment":
            return await comment(call.arguments, review: review)
        default:
            return AgentTools.Reply(text: "\(call.tool) isn't available in this version of Maser yet.", isError: true)
        }
    }

    // MARK: - Comments

    /// Adds the agent's line comment to the user's pending review, with the attribution line.
    ///
    /// It goes through the review's own posting path: on a line in the diff, for the conversation's commit, as the
    /// account shown. The comment stays private until the user submits.
    ///
    /// - Parameters:
    ///   - arguments: The `add_review_comment` arguments.
    ///   - review: The review to post to.
    /// - Returns: The agent's answer.
    private func comment(_ arguments: String, review: ReviewModel) async -> AgentTools.Reply {
        guard let head = transcript.commit, review.diffCommitID == head else {
            return AgentTools.Reply(
                text: "The PR's diff changed since this message was sent. Ask the user to send a new message.", isError: true)
        }
        let request: AgentComment.Request
        do {
            request = try AgentComment.Request.decode(arguments)
        } catch {
            return AgentTools.Reply(text: "Those arguments aren't a comment: \(error.localizedDescription)", isError: true)
        }
        let target: CommentTarget
        switch AgentComment.target(for: request, in: review.diffFiles) {
        case let .success(found): target = found
        case let .failure(refusal): return AgentTools.Reply(text: refusal.message, isError: true)
        }
        let body = AgentComment.body(request.body, model: sessionModel ?? model ?? "claude")
        do {
            try await review.postAgentComment(target: target, body: body, commit: head)
        } catch {
            return AgentTools.Reply(text: "The comment wasn't added: \(error.localizedDescription)", isError: true)
        }
        return AgentTools.Reply(
            text:
                "Added to the user's pending review on \(target.path) \(target.description). It stays private until they submit, and says an agent drafted it."
        )
    }

    /// Records that the user opened some of the agent's comments.
    ///
    /// - Parameter ids: The comments' IDs.
    func markOpened(_ ids: [String]) {
        let new = ids.filter { !transcript.openedAgentComments.contains($0) }
        guard !new.isEmpty else { return }
        transcript.openedAgentComments += new
        save()
    }

    // MARK: - Canvas

    /// Draws a diagram from the agent on the canvas, after checking it.
    ///
    /// The source is refused if it could act or reach out, rendered with Pele, and checked against the checkout and the
    /// diff. Flagged elements are outlined, and the agent's reply lists them, so it can draw again.
    ///
    /// - Parameters:
    ///   - arguments: The `show_diagram` arguments.
    ///   - review: The review, for the diff.
    /// - Returns: The agent's answer.
    private func draw(_ arguments: String, review: ReviewModel) -> AgentTools.Reply {
        guard let head = transcript.commit, review.diffCommitID == head, let checkout = checkoutPath else {
            return AgentTools.Reply(
                text: "The PR's diff changed since this message was sent. Ask the user to send a new message.", isError: true)
        }
        let diagram: Diagram
        do {
            diagram = try Diagram.decode(toolArguments: arguments)
        } catch {
            return AgentTools.Reply(text: "Those arguments aren't a diagram: \(error.localizedDescription)", isError: true)
        }
        do {
            let renderer = try renderer ?? DiagramRenderer(script: Self.peleScript())
            self.renderer = renderer
            let rendering = try renderer.render(diagram)
            let findings = DiagramGrounding.check(
                diagram, checkout: URL(filePath: checkout), files: review.diffFiles, renderedIDs: rendering.ids)
            let changes = Dictionary(
                diagram.elements.compactMap { element in element.change.map { (element.id, $0) } },
                uniquingKeysWith: { first, _ in first })
            let flagged = Set(findings.filter { !$0.problems.isEmpty }.map(\.id))
            let drawn = AgentDiagram(
                diagram: diagram, commit: head,
                svg: DiagramRenderer.annotate(rendering.svg, changes: changes, flagged: flagged), findings: findings)
            transcript.diagrams.append(drawn)
            selectedDiagramID = drawn.id
            selectedElement = nil
            showsCanvas = true
            save()
            return AgentTools.Reply(text: drawn.replyText(renderedIDs: rendering.ids))
        } catch {
            return AgentTools.Reply(text: "The diagram wasn't shown: \(error.localizedDescription)", isError: true)
        }
    }

    /// The text of the bundled Pele.
    ///
    /// The app bundle carries it in its resources. A debug build run from the repository (`swift run`) reads the
    /// vendored copy instead.
    ///
    /// - Returns: The script.
    /// - Throws: An error if it can't be found or read.
    private static func peleScript() throws -> String {
        if let url = Bundle.main.url(forResource: "pele.global", withExtension: "js") {
            return try String(contentsOf: url, encoding: .utf8)
        }
        #if DEBUG
            let vendored = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: "Vendor/pele/pele.global.js")
            if let script = try? String(contentsOf: vendored, encoding: .utf8) { return script }
        #endif
        throw AgentFailure("Maser's diagram renderer (pele.global.js) is missing from the app.")
    }

    /// The diagram on the canvas: the one chosen, or else the newest.
    var shownDiagram: AgentDiagram? {
        transcript.diagrams.first { $0.id == selectedDiagramID } ?? transcript.diagrams.last
    }

    /// Shows an older or newer diagram, stopping at the ends.
    ///
    /// - Parameter offset: How many to move; negative goes to older ones.
    func selectDiagram(offset: Int) {
        let diagrams = transcript.diagrams
        guard !diagrams.isEmpty else { return }
        let current = diagrams.firstIndex { $0.id == shownDiagram?.id } ?? diagrams.count - 1
        selectedDiagramID = diagrams[min(max(current + offset, 0), diagrams.count - 1)].id
        selectedElement = nil
    }

    /// Moves the selection through the shown diagram's elements, stopping at the ends.
    ///
    /// - Parameter offset: How many to move; negative moves up.
    func selectElement(offset: Int) {
        guard let count = shownDiagram?.diagram.elements.count, count > 0 else { return }
        selectedElement = selectedElement.map { min(max($0 + offset, 0), count - 1) } ?? (offset > 0 ? 0 : count - 1)
    }

    /// Opens the lines an element cites: in the Files tab when the diff has them, otherwise read-only from the checkout.
    ///
    /// - Parameter element: The element; the selected one if nil.
    func openCitation(of element: Diagram.Element? = nil) {
        guard let review,
            let element = element ?? selectedElement.flatMap({ shownDiagram?.diagram.elements[safe: $0] }),
            let text = element.citation, let citation = Citation(text)
        else { return }
        let removed = element.change == .removed
        if let file = review.diffFiles.first(where: { (removed ? $0.oldPath ?? $0.path : $0.path) == citation.path }),
            review.revealLine(path: file.path, line: citation.lines.lowerBound, side: removed ? .left : .right)
        {
            return
        }
        guard let checkout = checkoutPath,
            let contents = try? String(contentsOf: URL(filePath: checkout).appending(path: citation.path), encoding: .utf8),
            DiagramGrounding.lineCount(of: citation.path, in: URL(filePath: checkout)) != nil
        else { return }
        openedCitation = OpenedCitation(path: citation.path, lines: citation.lines, text: contents)
    }

    /// Handles a key's command while the Agent tab is showing.
    ///
    /// `]`/`[` move between diagrams, `j`/`k` between elements, Return opens the selected element's lines, and `i` shows
    /// or hides the canvas.
    ///
    /// - Parameter command: The command.
    /// - Returns: Whether the tab handled it; nil to let the review handle it as usual.
    func perform(_ command: CommandID) -> Bool? {
        switch command {
        case .nextFile: selectDiagram(offset: 1)
        case .previousFile: selectDiagram(offset: -1)
        case .cursorDown: selectElement(offset: 1)
        case .cursorUp: selectElement(offset: -1)
        case .openSelected: openCitation()
        case .toggleComments: showsCanvas.toggle()
        default: return nil
        }
        return true
    }

    /// Saves the transcript, logging a failure; the conversation carries on in memory.
    private func save() {
        do {
            try Self.store.save(transcript, for: pr)
        } catch {
            NSLog("Couldn't save the agent conversation for %@: %@", pr.url.absoluteString, error.localizedDescription)
        }
    }
}

/// Lines an element cites, read from the checkout.
struct OpenedCitation: Identifiable {
    let id = UUID()
    /// The file's path in the repository.
    let path: String
    /// The cited lines.
    let lines: ClosedRange<Int>
    /// The whole file's text.
    let text: String
}

extension Array {
    /// The element at an index, or nil if it's out of range.
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// A failure to show in the Agent tab.
private struct AgentFailure: LocalizedError {
    /// The message.
    let errorDescription: String?

    /// Creates a failure with a message.
    ///
    /// - Parameter message: The message.
    init(_ message: String) { errorDescription = message }
}

/// Splits output into lines as chunks arrive.
///
/// `@unchecked Sendable` is safe because every access holds `lock`.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    /// Adds a chunk and returns the lines it completed.
    ///
    /// - Parameter data: The chunk.
    /// - Returns: The complete lines, without newlines.
    func append(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
            return lines
        }
    }
}

/// Keeps the last few hundred bytes of a process's standard error.
///
/// `@unchecked Sendable` is safe because every access holds `lock`.
private final class ErrorTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    /// Adds output, keeping only the end.
    ///
    /// - Parameter chunk: The output.
    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > 600 { data = data.suffix(600) }
        }
    }

    /// The kept output, trimmed.
    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
