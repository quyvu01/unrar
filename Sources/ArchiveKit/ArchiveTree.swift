import Foundation

/// A folder hierarchy built from the flat entry list of an archive.
/// Folders that are only implied by file paths are synthesised.
public final class ArchiveNode: Identifiable, Hashable, @unchecked Sendable {
    public let name: String
    /// Full path inside the archive ("" for the root).
    public let path: String
    public let isDirectory: Bool
    /// Underlying entry, nil for the root and for implied folders.
    public private(set) var entry: ArchiveEntry?
    public private(set) var children: [ArchiveNode] = []
    public private(set) weak var parent: ArchiveNode?

    private var childIndex: [String: ArchiveNode] = [:]

    public var id: String { path }

    init(name: String, path: String, isDirectory: Bool, entry: ArchiveEntry?, parent: ArchiveNode?) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.entry = entry
        self.parent = parent
    }

    public static func == (lhs: ArchiveNode, rhs: ArchiveNode) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    /// Sub folders only, sorted by name. Handy for a sidebar outline (nil when empty).
    public var folderChildren: [ArchiveNode]? {
        let folders = children.filter(\.isDirectory)
        return folders.isEmpty ? nil : folders
    }

    /// Size of the file, or of everything below a folder.
    public private(set) var uncompressedSize: UInt64 = 0
    public private(set) var compressedSize: UInt64 = 0
    /// Number of files (not folders) below this node, or 1 for a file.
    public private(set) var fileCount: Int = 0

    public var modificationDate: Date? { entry?.modificationDate }
    public var isEncrypted: Bool {
        if let entry { return entry.isEncrypted }
        return children.contains { $0.isEncrypted }
    }

    /// Path components from the root to this node (excluding the root).
    public var ancestry: [ArchiveNode] {
        var nodes: [ArchiveNode] = []
        var current: ArchiveNode? = self
        while let node = current, node.parent != nil {
            nodes.insert(node, at: 0)
            current = node.parent
        }
        return nodes
    }

    /// Finds the node at `path` ("" returns the root).
    public func node(at path: String) -> ArchiveNode? {
        if path.isEmpty { return self }
        var current = self
        for component in path.split(separator: "/") {
            guard let next = current.childIndex[String(component)] else { return nil }
            current = next
        }
        return current
    }

    /// All file entries below (and including) this node.
    public var allEntries: [ArchiveEntry] {
        var result: [ArchiveEntry] = []
        if let entry { result.append(entry) }
        for child in children { result.append(contentsOf: child.allEntries) }
        return result
    }

    // MARK: Building

    public static func build(from entries: [ArchiveEntry]) -> ArchiveNode {
        let root = ArchiveNode(name: "", path: "", isDirectory: true, entry: nil, parent: nil)
        for entry in entries {
            let components = PathSanitizer.safeComponents(of: entry.path)
            guard !components.isEmpty else { continue }
            var current = root
            for (i, component) in components.enumerated() {
                let isLast = i == components.count - 1
                let path = components[0...i].joined(separator: "/")
                if let existing = current.childIndex[component] {
                    if isLast, existing.entry == nil, existing.isDirectory == entry.isDirectory {
                        existing.entry = entry
                    }
                    current = existing
                } else {
                    let node = ArchiveNode(
                        name: component,
                        path: path,
                        isDirectory: isLast ? entry.isDirectory : true,
                        entry: isLast ? entry : nil,
                        parent: current
                    )
                    current.childIndex[component] = node
                    current.children.append(node)
                    current = node
                }
            }
        }
        root.finalize()
        return root
    }

    private func finalize() {
        children.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        if isDirectory {
            var size: UInt64 = 0, packed: UInt64 = 0, count = 0
            for child in children {
                child.finalize()
                size += child.uncompressedSize
                packed += child.compressedSize
                count += child.fileCount
            }
            uncompressedSize = size
            compressedSize = packed
            fileCount = count
        } else {
            uncompressedSize = entry?.uncompressedSize ?? 0
            compressedSize = entry?.compressedSize ?? 0
            fileCount = 1
        }
    }
}
