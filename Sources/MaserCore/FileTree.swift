import Foundation

/// A node in the changed-files tree. Directories have `children`; files don't.
public struct FileNode: Identifiable, Hashable, Sendable {
    /// Full path from the repo root (no trailing slash for directories).
    public let id: String
    /// Display name; directory chains with a single child are collapsed, e.g. `Sources/MaserCore`.
    public let name: String
    public let children: [FileNode]?

    public var isDirectory: Bool { children != nil }
}

public enum FileTree {
    /// Builds a tree from file paths: directories first, then files, each sorted Finder-style.
    public static func build(paths: [String]) -> [FileNode] {
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

        func ordered(_ names: some Sequence<String>) -> [String] {
            names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }

        func nodes(in dir: Dir, prefix: String) -> [FileNode] {
            let dirNodes = ordered(dir.dirs.keys).map { key -> FileNode in
                var name = key
                var path = prefix + key
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
    public static func firstFilePath(in nodes: [FileNode]) -> String? {
        for node in nodes {
            guard let children = node.children else { return node.id }
            if let path = firstFilePath(in: children) { return path }
        }
        return nil
    }
}
