import Testing

@testable import MaserCore

@Suite struct FileTreeTests {
    @Test func buildsSortedCompactedTree() {
        let tree = FileTree.build(paths: [
            "README.md",
            "Sources/MaserCore/Diff.swift",
            "Sources/MaserCore/FileTree.swift",
            "Sources/Maser/App.swift",
            "a/b/c/deep.txt",
        ])

        // Directories first, then files; `a/b/c` collapses into one node.
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
