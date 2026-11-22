import Foundation

public struct UndoEntry {
    public let volumeID: String
    public let name: String
    public let originalPath: String
    public let trashedPath: String
    public let parentPath: String
    public let removedNode: DiskNode

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
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.parentPath = parentPath
        self.removedNode = removedNode
    }
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

    public static func restore(trashedPath: String, to originalPath: String) throws {
        let src = URL(fileURLWithPath: trashedPath)
        let dst = URL(fileURLWithPath: originalPath)
        do {
            try FileManager.default.moveItem(at: src, to: dst)
        } catch {
            throw TrashError.systemError(error.localizedDescription)
        }
    }
}
