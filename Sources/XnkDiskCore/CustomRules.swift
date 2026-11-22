import Foundation

public struct CustomRule: Codable, Hashable, Sendable {
    public var path: String?
    public var name: String?
    public var sibling: String?
    public var label: String?
    public var safety: String?
    public var description: String?

    public init(
        path: String? = nil,
        name: String? = nil,
        sibling: String? = nil,
        label: String? = nil,
        safety: String? = nil,
        description: String? = nil
    ) {
        self.path = path
        self.name = name
        self.sibling = sibling
        self.label = label
        self.safety = safety
        self.description = description
    }

    public func toHint(folderName: String) -> NodeHint {
        let s = (safety ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resolvedSafety: CacheSafety = (s == "caution") ? .caution : .rebuilds
        let desc = (description?.isEmpty == false)
            ? description!
            : (resolvedSafety == .caution
                ? "Marked as \"May hold your data\" in your custom rules."
                : "Marked as \"Rebuildable\" in your custom rules.")
        let lbl = (label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? label!.trimmingCharacters(in: .whitespacesAndNewlines)
            : folderName
        return NodeHint(label: lbl, safety: resolvedSafety, description: desc, custom: true)
    }
}

public struct CustomRulesConfig: Codable, Hashable, Sendable {
    public var add: [CustomRule]
    public var ignore: [String]

    public init(add: [CustomRule] = [], ignore: [String] = []) {
        self.add = add
        self.ignore = ignore
    }

    public mutating func markPathRebuilds(_ targetPath: String, label: String, home: String) {
        let targetAbs = CustomRulesStore.expandHome(targetPath, home: home)
        let storedPath = CustomRulesStore.collapseHome(targetAbs, home: home)
        let effectiveLabel = label.isEmpty ? (targetAbs as NSString).lastPathComponent : label

        ignore.removeAll { ig in
            ig.contains("/") && CustomRulesStore.expandHome(ig, home: home) == targetAbs
        }

        if let idx = add.firstIndex(where: { r in
            guard let rp = r.path, !rp.isEmpty else { return false }
            return CustomRulesStore.expandHome(rp, home: home) == targetAbs
        }) {
            add[idx].path = storedPath
            add[idx].safety = CacheSafety.rebuilds.rawValue
            if add[idx].label?.isEmpty != false {
                add[idx].label = effectiveLabel
            }
            return
        }

        add.append(CustomRule(
            path: storedPath,
            label: effectiveLabel,
            safety: CacheSafety.rebuilds.rawValue,
            description: "Marked as \"Rebuildable\" in your custom rules."
        ))
    }

    public mutating func unmarkPath(_ targetPath: String, home: String, hasBuiltIn: Bool) {
        let targetAbs = CustomRulesStore.expandHome(targetPath, home: home)
        let storedPath = CustomRulesStore.collapseHome(targetAbs, home: home)

        add.removeAll { r in
            guard let rp = r.path, !rp.isEmpty else { return false }
            return CustomRulesStore.expandHome(rp, home: home) == targetAbs
        }

        guard hasBuiltIn else { return }
        let alreadyIgnored = ignore.contains { ig in
            ig.contains("/") && CustomRulesStore.expandHome(ig, home: home) == targetAbs
        }
        if !alreadyIgnored {
            ignore.append(storedPath)
        }
    }
}

public enum CustomRulesStore {
    public static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString)
            .appendingPathComponent("Library/Application Support/com.jefflunt.xnk-disk/rules.json")
    }

    public static func expandHome(_ p: String, home: String) -> String {
        guard !p.isEmpty else { return "" }
        if !home.isEmpty {
            if p == "~" { return cleanPath(home) }
            if p.hasPrefix("~/") {
                return cleanPath((home as NSString).appendingPathComponent(String(p.dropFirst(2))))
            }
        }
        return cleanPath(p)
    }

    public static func collapseHome(_ p: String, home: String) -> String {
        let clean = cleanPath(p)
        guard !home.isEmpty else { return clean }
        let cleanHome = cleanPath(home)
        if clean == cleanHome { return "~" }
        if clean.hasPrefix(cleanHome + "/") {
            return "~/" + String(clean.dropFirst(cleanHome.count + 1))
        }
        return clean
    }

    public static func load(from path: String = defaultPath) -> CustomRulesConfig {
        guard !path.isEmpty, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return CustomRulesConfig()
        }
        return (try? JSONDecoder().decode(CustomRulesConfig.self, from: data)) ?? CustomRulesConfig()
    }

    public static func save(_ config: CustomRulesConfig, to path: String = defaultPath) throws {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(config)
        data.append(0x0A)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
