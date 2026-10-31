import Foundation
import MaserCore
import Observation

/// State for one PR review window.
@MainActor @Observable
final class ReviewModel {
    enum LoadState {
        case loading
        case loaded
        case failed(String)
    }

    /// A request to scroll the diff to a line; the token makes repeat requests for the same line distinct.
    struct ScrollRequest: Equatable {
        let lineID: Int
        let token = UUID()
    }

    let pr: PullRequest
    private(set) var state: LoadState = .loading
    private(set) var tree: [FileNode] = []
    private var filesByPath: [String: FileDiff] = [:]
    private var threadsByPath: [String: [ReviewThread]] = [:]

    var selectedPath: String?
    var collapsedDirectories: Set<String> = []
    var scrollRequest: ScrollRequest?

    init(pr: PullRequest) {
        self.pr = pr
    }

    var selectedFile: FileDiff? { selectedPath.flatMap { filesByPath[$0] } }
    var selectedThreads: [ReviewThread] { selectedPath.flatMap { threadsByPath[$0] } ?? [] }

    func file(at path: String) -> FileDiff? { filesByPath[path] }
    func commentCount(at path: String) -> Int {
        threadsByPath[path]?.reduce(0) { $0 + $1.comments.count } ?? 0
    }

    /// IDs of diff lines in the selected file that have a (current) thread anchored to them.
    var commentedLineIDs: Set<Int> {
        guard let file = selectedFile else { return [] }
        return Set(selectedThreads.compactMap { thread in
            thread.line.flatMap { file.lineID(side: thread.side, line: $0) }
        })
    }

    func load() async {
        state = .loading
        do {
            let cli = try GitHubCLI()
            async let diffs = cli.fileDiffs(for: pr)
            async let comments = cli.reviewComments(for: pr)
            let (files, allComments) = try await (diffs, comments)

            filesByPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            tree = FileTree.build(paths: files.map(\.path))
            threadsByPath = Dictionary(grouping: ReviewThread.group(allComments), by: \.path)
            if selectedPath.map({ filesByPath[$0] == nil }) ?? true {
                selectedPath = FileTree.firstFilePath(in: tree)
            }
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Scrolls the diff to the line a thread is anchored to (no-op for outdated threads).
    func reveal(_ thread: ReviewThread) {
        guard let file = selectedFile, let line = thread.line,
              let id = file.lineID(side: thread.side, line: line)
        else { return }
        scrollRequest = ScrollRequest(lineID: id)
    }
}
