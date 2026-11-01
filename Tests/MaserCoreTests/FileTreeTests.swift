// Tests for `FileTree`, the directory tree shown in the file sidebar.

import Testing

@testable import MaserCore

/// Tests for building the sidebar's file tree from changed paths.
@Suite struct FileTreeTests {
    /// Sorts directories before files, collapses single-child directory chains, and finds the first file in display
    /// order.
    @Test func buildsSortedCompactedTree() {
        let tree = FileTree.build(paths: [
            "README.md",
            "Sources/MaserCore/Diff.swift",
            "Sources/MaserCore/FileTree.swift",
            "Sources/Maser/App.swift",
            "a/b/c/deep.txt",
        ])

        #expect(tree.map(\.name) == ["a/b/c", "Sources", "README.md"])
        #expect(tree[0].id == "a/b/c")
        #expect(tree[0].children?.map(\.id) == ["a/b/c/deep.txt"])

        let sources = tree[1].children ?? []
        #expect(sources.map(\.name) == ["Maser", "MaserCore"])
        #expect(sources[1].children?.map(\.id) == ["Sources/MaserCore/Diff.swift", "Sources/MaserCore/FileTree.swift"])
        #expect(tree[2].isDirectory == false)

        #expect(FileTree.firstFilePath(in: tree) == "a/b/c/deep.txt")
    }

    @Test func emptyTree() {
        #expect(FileTree.build(paths: []).isEmpty)
        #expect(FileTree.firstFilePath(in: []) == nil)
    }
}
