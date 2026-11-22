import Foundation

public struct ViewPreferences: Equatable {
    public var layoutModeRaw: String
    public var maxDepth: Int
    public var groupSmall: Bool
    public var hideFreeSpace: Bool
    public var highlightRebuildsOnly: Bool

    public init(
        layoutModeRaw: String = "Scrollable",
        maxDepth: Int = 10,
        groupSmall: Bool = false,
        hideFreeSpace: Bool = false,
        highlightRebuildsOnly: Bool = false
    ) {
        self.layoutModeRaw = layoutModeRaw
        self.maxDepth = maxDepth
        self.groupSmall = groupSmall
        self.hideFreeSpace = hideFreeSpace
        self.highlightRebuildsOnly = highlightRebuildsOnly
    }
}

public enum PreferencesStore {
    private enum Keys {
        static let layoutMode = "xnk.pref.layoutMode"
        static let maxDepth = "xnk.pref.maxDepth"
        static let groupSmall = "xnk.pref.groupSmall"
        static let hideFreeSpace = "xnk.pref.hideFreeSpace"
        static let highlightRebuildsOnly = "xnk.pref.highlightRebuildsOnly"
    }

    public static func load(from defaults: UserDefaults = .standard) -> ViewPreferences {
        let layout = defaults.string(forKey: Keys.layoutMode) ?? "Scrollable"
        let depth = defaults.object(forKey: Keys.maxDepth) != nil ? defaults.integer(forKey: Keys.maxDepth) : 10
        let group = defaults.bool(forKey: Keys.groupSmall)
        let hideFree = defaults.bool(forKey: Keys.hideFreeSpace)
        let rebuildsOnly = defaults.bool(forKey: Keys.highlightRebuildsOnly)
        return ViewPreferences(
            layoutModeRaw: layout,
            maxDepth: depth,
            groupSmall: group,
            hideFreeSpace: hideFree,
            highlightRebuildsOnly: rebuildsOnly
        )
    }

    public static func save(_ prefs: ViewPreferences, to defaults: UserDefaults = .standard) {
        defaults.set(prefs.layoutModeRaw, forKey: Keys.layoutMode)
        defaults.set(prefs.maxDepth, forKey: Keys.maxDepth)
        defaults.set(prefs.groupSmall, forKey: Keys.groupSmall)
        defaults.set(prefs.hideFreeSpace, forKey: Keys.hideFreeSpace)
        defaults.set(prefs.highlightRebuildsOnly, forKey: Keys.highlightRebuildsOnly)
    }
}
