import Foundation

public struct WindowRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct SavedWindowState: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var frame: WindowRect?
    public var selectedVolumeID: String
    public var viewModeRaw: String // "overview" | "icicle"
    public var currentPath: String
    public var layoutModeRaw: String // "Scrollable" | "Fit"
    public var maxDepth: Int
    public var groupSmall: Bool
    public var hideFreeSpace: Bool
    public var highlightRebuildsOnly: Bool
    public var vZoom: Double

    public init(
        id: UUID = UUID(),
        frame: WindowRect? = nil,
        selectedVolumeID: String = "",
        viewModeRaw: String = "overview",
        currentPath: String = "",
        layoutModeRaw: String = "Scrollable",
        maxDepth: Int = 10,
        groupSmall: Bool = false,
        hideFreeSpace: Bool = false,
        highlightRebuildsOnly: Bool = false,
        vZoom: Double = 1.0
    ) {
        self.id = id
        self.frame = frame
        self.selectedVolumeID = selectedVolumeID
        self.viewModeRaw = viewModeRaw
        self.currentPath = currentPath
        self.layoutModeRaw = layoutModeRaw
        self.maxDepth = maxDepth
        self.groupSmall = groupSmall
        self.hideFreeSpace = hideFreeSpace
        self.highlightRebuildsOnly = highlightRebuildsOnly
        self.vZoom = vZoom
    }
}

public enum WindowSessionStore {
    private static let key = "xnk.savedWindows.v1"

    public static func load(from defaults: UserDefaults = .standard) -> [SavedWindowState] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedWindowState].self, from: data) else {
            return []
        }
        return decoded
    }

    public static func save(_ windows: [SavedWindowState], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(windows) else { return }
        defaults.set(data, forKey: key)
    }
}
