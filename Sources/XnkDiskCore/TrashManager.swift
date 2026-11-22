import Foundation

public struct TrashedItem: Sendable {
    public let originalPath: String
    public let trashedPath: String

    public init(originalPath: String, trashedPath: String) {
        self.originalPath = originalPath
        self.trashedPath = trashedPath
    }
}

public struct UndoEntry: Sendable {
    public let volumeID: String
    public let name: String
    public let items: [TrashedItem]
    // Either a single removed node (normal Move to Trash) or purged folder snapshots (Purge Rebuildable).
    public let singleRemovedParentPath: String?
    public let singleRemovedNode: DiskNode?
    public let purgedFolders: [PurgedFolderSnapshot]

    public init(
        volumeID: String,
        name: String,
        originalPath: String,
        trashedPath: String,
        parentPath: String,
        removedNode: DiskNode
    ) {
        self.volumeID = volumeID
        self.name = name
        self.items = [TrashedItem(originalPath: originalPath, trashedPath: trashedPath)]
        self.singleRemovedParentPath = parentPath
        self.singleRemovedNode = removedNode
        self.purgedFolders = []
    }

    public init(
        volumeID: String,
        name: String,
        items: [TrashedItem],
        purgedFolders: [PurgedFolderSnapshot]
    ) {
        self.volumeID = volumeID
        self.name = name
        self.items = items
        self.singleRemovedParentPath = nil
        self.singleRemovedNode = nil
        self.purgedFolders = purgedFolders
    }
}

public struct PurgeDirectoryResult: Sendable {
    public let movedItems: [TrashedItem]
    public let failedCount: Int
}

public enum TrashError: LocalizedError {
    case protectedPath(String)
    case missingResult
    case systemError(String)

    public var errorDescription: String? {
        switch self {
        case .protectedPath(let p): return "Refusing to trash protected path: \(p)"
        case .missingResult: return "No active scan for volume"
        case .systemError(let msg): return msg
        }
    }
}

public enum TrashManager {
    public static let protectedPaths: Set<String> = [
        "/", "/System", "/Library", "/Users", "/Applications",
        "/Volumes", "/private", "/usr", "/bin", "/sbin", "/etc", "/var", "/dev", "/opt"
    ]

    public static func isTrashable(path: String, volumeID: String) -> Bool {
        let clean = cleanPath(path)
        if clean.isEmpty || clean == cleanPath(volumeID) || protectedPaths.contains(clean) {
            return false
        }
        if clean.hasSuffix("/*") || clean.hasSuffix("(direct files)") || clean == "(system-unscanned)" {
            return false
        }
        return true
    }

    public static func moveToTrash(path: String, volumeID: String) throws -> String {
        let clean = cleanPath(path)
        guard isTrashable(path: clean, volumeID: volumeID) else {
            throw TrashError.protectedPath(clean)
        }
        let srcURL = URL(fileURLWithPath: clean)
        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(at: srcURL, resultingItemURL: &resultingURL)
        } catch {
            throw TrashError.systemError(error.localizedDescription)
        }
        return resultingURL?.path ?? ""
    }

    /// Moves every immediate child inside `dirPath` to the macOS Trash while keeping `dirPath` itself intact.
    /// Tracks only the top-level items moved so a single Undo restores the entire directory contents.
    public static func purgeDirectoryContents(
        at dirPath: String,
        volumeID: String,
        trashMover: ((URL) throws -> String?)? = nil
    ) throws -> PurgeDirectoryResult {
        let clean = cleanPath(dirPath)
        guard isTrashable(path: clean, volumeID: volumeID) else {
            throw TrashError.protectedPath(clean)
        }
        let fm = FileManager.default
        let children: [String]
        do {
            children = try fm.contentsOfDirectory(atPath: clean)
        } catch {
            throw TrashError.systemError(error.localizedDescription)
        }

        let mover: (URL) throws -> String? = trashMover ?? { srcURL in
            var resultingURL: NSURL?
            try fm.trashItem(at: srcURL, resultingItemURL: &resultingURL)
            return resultingURL?.path
        }

        var moved: [TrashedItem] = []
        var failed = 0
        for childName in children {
            let childPath = (clean as NSString).appendingPathComponent(childName)
            let srcURL = URL(fileURLWithPath: childPath)
            do {
                if let trashed = try mover(srcURL), !trashed.isEmpty {
                    moved.append(TrashedItem(originalPath: childPath, trashedPath: trashed))
                }
            } catch {
                failed += 1
            }
        }
        return PurgeDirectoryResult(movedItems: moved, failedCount: failed)
    }

    public static func restore(trashedPath: String, to originalPath: String) throws {
        let src = URL(fileURLWithPath: trashedPath)
        let dst = URL(fileURLWithPath: originalPath)
        do {
            try FileManager.default.moveItem(at: src, to: dst)
        } catch {
            throw TrashError.systemError(error.localizedDescription)
        }
    }

    /// Restores a batch of previously trashed top-level items back to their original paths.
    public static func restoreItems(_ items: [TrashedItem]) -> (restored: Int, failed: Int) {
        let fm = FileManager.default
        var restored = 0
        var failed = 0
        for item in items.reversed() {
            let src = URL(fileURLWithPath: item.trashedPath)
            let dst = URL(fileURLWithPath: item.originalPath)
            do {
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: src, to: dst)
                restored += 1
            } catch {
                failed += 1
            }
        }
        return (restored, failed)
    }
}
