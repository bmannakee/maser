// Tests for `FileTree`, the directory tree shown in the file sidebar.

import Testing

@testable import MaserCore

/// Tests for building the sidebar's file tree from changed paths.
@Suite struct FileTreeTests {
    /// Sorts directories before files, collapses single-child directory chains, and finds the first file in display
    /// order.
    @Test("REQ-DIF-004: Builds sorted compacted tree") func buildsSortedCompactedTree() {
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

    /// Lists every row depth-first with its depth, for sizing the sidebar to the widest one.
    @Test("REQ-DIF-004: Rows with depths") func rowsWithDepths() {
        let tree = FileTree.build(paths: ["README.md", "Sources/Maser/App.swift", "Sources/MaserCore/Diff.swift"])
        let rows = FileTree.rows(in: tree).map { "\($0.depth) \($0.name)" }
        #expect(rows == ["0 Sources", "1 Maser", "2 App.swift", "1 MaserCore", "2 Diff.swift", "0 README.md"])
        #expect(FileTree.rows(in: []).isEmpty)
    }

    @Test("REQ-DIF-004: Empty tree") func emptyTree() {
        #expect(FileTree.build(paths: []).isEmpty)
        #expect(FileTree.firstFilePath(in: []) == nil)
    }
}

/// Tests for narrowing the file tree with the filter.
@Suite struct FileFilterTests {
    /// A path matches when it holds every word of the filter, in any order, ignoring case and accents.
    @Test("REQ-DIF-014: Filters paths by every word, ignoring case") func filtersPaths() {
        let paths = [
            "Sources/Maser/FilesView.swift", "Sources/MaserCore/FileTree.swift", "Tests/FileTreeTests.swift", "café/Menu.md",
        ]
        #expect(FileTree.matching(paths, filter: "") == paths)
        #expect(FileTree.matching(paths, filter: "   ") == paths)
        #expect(FileTree.matching(paths, filter: "tree") == ["Sources/MaserCore/FileTree.swift", "Tests/FileTreeTests.swift"])
        #expect(FileTree.matching(paths, filter: "tests tree") == ["Tests/FileTreeTests.swift"])
        #expect(FileTree.matching(paths, filter: "tree tests") == ["Tests/FileTreeTests.swift"])
        #expect(FileTree.matching(paths, filter: "SOURCES/maser/") == ["Sources/Maser/FilesView.swift"])
        #expect(FileTree.matching(paths, filter: "cafe") == ["café/Menu.md"])
        #expect(FileTree.matching(paths, filter: "nothing like this").isEmpty)
        // The order given is kept, so the tree built from the result lists files the way the whole tree does.
        #expect(FileTree.matching(paths, filter: "swift") == Array(paths.prefix(3)))
    }
}
