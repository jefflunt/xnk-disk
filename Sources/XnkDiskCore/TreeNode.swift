import Foundation

public struct Crumb: Identifiable, Hashable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let size: UInt64
}

public final class DiskNode: Codable, @unchecked Sendable {
    public var name: String
    public var path: String
    public var size: UInt64
    public var apparent: UInt64
    public var files: Int64
    public var dirs: Int64
    public var skipped: Int64
    public var isDir: Bool
    public var children: [DiskNode]

    public init(
        name: String,
        path: String,
        size: UInt64 = 0,
        apparent: UInt64 = 0,
        files: Int64 = 0,
        dirs: Int64 = 0,
        skipped: Int64 = 0,
        isDir: Bool = false,
        children: [DiskNode] = []
    ) {
        self.name = name
        self.path = path
        self.size = size
        self.apparent = apparent
        self.files = files
        self.dirs = dirs
        self.skipped = skipped
        self.isDir = isDir
        self.children = children
    }

    public func sortRecursive() {
        if children.count > 1 {
            children.sort { a, b in
                if a.size != b.size { return a.size > b.size }
                return a.name < b.name
            }
        }
        for c in children {
            c.sortRecursive()
        }
    }

    public func findPath(_ targetPath: String) -> (DiskNode, [Crumb]) {
        let cleanTarget = cleanPath(targetPath)
        let cleanRoot = cleanPath(self.path)
        if cleanTarget.isEmpty || cleanTarget == cleanRoot {
            return (self, [Crumb(name: name, path: path, size: size)])
        }

        var crumbs: [Crumb] = []
        func dfs(_ cur: DiskNode) -> DiskNode? {
            crumbs.append(Crumb(name: cur.name, path: cur.path, size: cur.size))
            if cleanPath(cur.path) == cleanTarget {
                return cur
            }
            for child in cur.children {
                let cp = cleanPath(child.path)
                if cp == cleanTarget || cleanTarget.hasPrefix(cp + "/") || cp == "/" {
                    if let found = dfs(child) {
                        return found
                    }
                }
            }
            crumbs.removeLast()
            return nil
        }

        if let found = dfs(self) {
            return (found, crumbs)
        }
        return (self, [Crumb(name: name, path: path, size: size)])
    }

    public func removePath(_ targetPath: String) -> (removed: DiskNode, parentPath: String)? {
        let cleanTarget = cleanPath(targetPath)
        if cleanTarget.isEmpty || cleanTarget == cleanPath(self.path) {
            return nil
        }

        var removed: DiskNode?
        var parentPath = ""

        func walk(_ cur: DiskNode) -> Bool {
            for (i, child) in cur.children.enumerated() {
                let cp = cleanPath(child.path)
                if cp == cleanTarget {
                    removed = child
                    parentPath = cur.path
                    cur.children.remove(at: i)
                    subStats(ancestor: cur, child: child)
                    return true
                }
                if cleanTarget.hasPrefix(cp + "/") || cp == "/" {
                    if walk(child), let r = removed {
                        subStats(ancestor: cur, child: r)
                        return true
                    }
                }
            }
            return false
        }

        if walk(self), let r = removed {
            return (r, parentPath)
        }
        return nil
    }

    @discardableResult
    public func restoreNode(parentPath: String, restored: DiskNode) -> Bool {
        let cleanParent = cleanPath(parentPath)
        func walk(_ cur: DiskNode) -> Bool {
            if cleanPath(cur.path) == cleanParent {
                cur.children.append(restored)
                addStats(ancestor: cur, child: restored)
                cur.children.sort { a, b in
                    if a.size != b.size { return a.size > b.size }
                    return a.name < b.name
                }
                return true
            }
            for child in cur.children {
                let cp = cleanPath(child.path)
                if cp == cleanParent || cleanParent.hasPrefix(cp + "/") || cp == "/" {
                    if walk(child) {
                        addStats(ancestor: cur, child: restored)
                        return true
                    }
                }
            }
            return false
        }
        return walk(self)
    }

    private func subStats(ancestor: DiskNode, child: DiskNode) {
        ancestor.size = ancestor.size >= child.size ? (ancestor.size - child.size) : 0
        ancestor.apparent = ancestor.apparent >= child.apparent ? (ancestor.apparent - child.apparent) : 0
        ancestor.files = max(0, ancestor.files - child.files)
        let dirsDelta = child.dirs + (child.isDir ? 1 : 0)
        ancestor.dirs = max(0, ancestor.dirs - dirsDelta)
    }

    private func addStats(ancestor: DiskNode, child: DiskNode) {
        ancestor.size += child.size
        ancestor.apparent += child.apparent
        ancestor.files += child.files
        ancestor.dirs += child.dirs + (child.isDir ? 1 : 0)
    }
}

public struct ViewNode: Identifiable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let size: UInt64
    public let apparent: UInt64
    public let files: Int64
    public let dirs: Int64
    public let skipped: Int64
    public let isDir: Bool
    public let isGrouped: Bool
    public let isSystemGap: Bool
    public let isFree: Bool
    public let hint: NodeHint?
    public var children: [ViewNode]

    public init(
        name: String,
        path: String,
        size: UInt64,
        apparent: UInt64 = 0,
        files: Int64 = 0,
        dirs: Int64 = 0,
        skipped: Int64 = 0,
        isDir: Bool = false,
        isGrouped: Bool = false,
        isSystemGap: Bool = false,
        isFree: Bool = false,
        hint: NodeHint? = nil,
        children: [ViewNode] = []
    ) {
        self.name = name
        self.path = path
        self.size = size
        self.apparent = apparent
        self.files = files
        self.dirs = dirs
        self.skipped = skipped
        self.isDir = isDir
        self.isGrouped = isGrouped
        self.isSystemGap = isSystemGap
        self.isFree = isFree
        self.hint = hint
        self.children = children
    }
}

public func projectView(
    root: DiskNode,
    maxDepth: Int,
    groupSmall: Bool,
    scaleBytes: UInt64,
    rules: CustomRulesConfig? = nil
) -> (ViewNode, Int) {
    let effectiveScale = max(1, scaleBytes > 0 ? scaleBytes : root.size)
    let minFraction = groupSmall ? 0.012 : 0.0012
    let minBytes = UInt64(Double(effectiveScale) * minFraction)

    var deepest = 0
    func build(_ cur: DiskNode, _ parent: DiskNode?, _ depth: Int) -> ViewNode {
        if depth > deepest { deepest = depth }
        let hint = DevCacheClassifier.classify(node: cur, parent: parent, customRules: rules)

        if (maxDepth > 0 && depth >= maxDepth) || cur.children.isEmpty {
            return ViewNode(
                name: cur.name, path: cur.path, size: cur.size, apparent: cur.apparent,
                files: cur.files, dirs: cur.dirs, skipped: cur.skipped,
                isDir: cur.isDir, hint: hint
            )
        }

        var kept: [ViewNode] = []
        var otherSize: UInt64 = 0
        var otherApp: UInt64 = 0
        var otherFiles: Int64 = 0
        var otherDirs: Int64 = 0
        var otherCount = 0

        for child in cur.children {
            if child.size == 0 { continue }
            if child.size < minBytes && cur.children.count > 3 {
                otherSize += child.size
                otherApp += child.apparent
                otherFiles += child.files
                otherDirs += child.dirs
                otherCount += 1
                continue
            }
            kept.append(build(child, cur, depth + 1))
        }

        if otherCount > 0 {
            if otherCount == 1 {
                if let single = cur.children.first(where: { $0.size > 0 && $0.size < minBytes }) {
                    kept.append(build(single, cur, depth + 1))
                }
            } else {
                kept.append(ViewNode(
                    name: "Other (\(otherCount) items)",
                    path: cur.path + "/*",
                    size: otherSize,
                    apparent: otherApp,
                    files: otherFiles,
                    dirs: otherDirs,
                    isDir: false,
                    isGrouped: true
                ))
                if depth + 1 > deepest { deepest = depth + 1 }
            }
        }

        return ViewNode(
            name: cur.name, path: cur.path, size: cur.size, apparent: cur.apparent,
            files: cur.files, dirs: cur.dirs, skipped: cur.skipped,
            isDir: cur.isDir, hint: hint, children: kept
        )
    }

    return (build(root, nil, 0), deepest)
}

public func cleanPath(_ p: String) -> String {
    guard !p.isEmpty else { return "" }
    return (p as NSString).standardizingPath
}
