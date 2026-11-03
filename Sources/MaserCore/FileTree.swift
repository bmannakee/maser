// The changed-files tree shown beside the diff.
//
// `FileTree` turns the flat list of paths a PR changes into nested `FileNode`s, collapsing single-child directory
// chains the way GitHub does, and gives the file order the Files view uses for next/previous file navigation.

import Foundation

/// A node in the changed-files tree.
///
/// Directories have `children`; files don't.
public struct FileNode: Identifiable, Hashable, Sendable {
    /// Full path from the repo root (no trailing slash for directories).
    public let id: String
    /// Display name; directory chains with a single child are collapsed, e.g. `Sources/MaserCore`.
    public let name: String
    /// The directory's contents, directories first; `nil` for files.
    public let children: [FileNode]?

    /// Whether the node is a directory.
    public var isDirectory: Bool { children != nil }
}

/// Builds and walks the changed-files tree.
public enum FileTree {
    /// Builds a tree from file paths: directories first, then files, each sorted Finder-style.
    ///
    /// - Parameter paths: Repo-relative file paths, separated by `/`.
    /// - Returns: The top-level nodes.
    public static func build(paths: [String]) -> [FileNode] {
        /// A mutable directory used while grouping paths.
        final class Dir {
            var dirs: [String: Dir] = [:]
            var files: [String] = []
        }

        let root = Dir()
        for path in paths {
            var components = path.split(separator: "/").map(String.init)
            guard let fileName = components.popLast() else { continue }
            var dir = root
            for component in components {
                if let existing = dir.dirs[component] {
                    dir = existing
                } else {
                    let created = Dir()
                    dir.dirs[component] = created
                    dir = created
                }
            }
            dir.files.append(fileName)
        }

        /// Sorts names the way Finder does, so `file2` comes before `file10`.
        func ordered(_ names: some Sequence<String>) -> [String] {
            names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }

        /// Converts a directory's contents to nodes, collapsing chains of directories that hold only one directory.
        func nodes(in dir: Dir, prefix: String) -> [FileNode] {
            let dirNodes = ordered(dir.dirs.keys).map { key -> FileNode in
                var name = key
                var path = prefix + key
                // `key` comes from `dir.dirs.keys`, so the lookup always succeeds.
                var sub = dir.dirs[key]!
                while sub.files.isEmpty, sub.dirs.count == 1, let only = sub.dirs.first {
                    name += "/" + only.key
                    path += "/" + only.key
                    sub = only.value
                }
                return FileNode(id: path, name: name, children: nodes(in: sub, prefix: path + "/"))
            }
            let fileNodes = ordered(dir.files).map { FileNode(id: prefix + $0, name: $0, children: nil) }
            return dirNodes + fileNodes
        }

        return nodes(in: root, prefix: "")
    }

    /// Path of the first file in display order.
    ///
    /// - Parameter nodes: The tree's top-level nodes.
    /// - Returns: The path, or `nil` if the tree has no files.
    public static func firstFilePath(in nodes: [FileNode]) -> String? {
        filePaths(in: nodes).first
    }

    /// All file paths in display order.
    ///
    /// - Parameter nodes: The tree's top-level nodes.
    /// - Returns: The paths of every file, depth-first, skipping directories.
    public static func filePaths(in nodes: [FileNode]) -> [String] {
        nodes.flatMap { node in node.children.map(filePaths(in:)) ?? [node.id] }
    }
}
