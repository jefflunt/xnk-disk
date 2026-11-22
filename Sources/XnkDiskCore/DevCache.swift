import Foundation

public enum CacheSafety: String, Codable, Hashable {
    case rebuilds
    case caution

    public var tagLabel: String {
        switch self {
        case .rebuilds: return "Rebuildable"
        case .caution: return "May hold your data"
        }
    }
}

public struct NodeHint: Hashable, Codable {
    public let label: String
    public let tag: String
    public let safety: CacheSafety
    public let description: String
    public let custom: Bool

    public init(label: String, safety: CacheSafety, description: String, custom: Bool = false) {
        self.label = label
        self.tag = safety.tagLabel
        self.safety = safety
        self.description = description
        self.custom = custom
    }
}

public enum DevCacheClassifier {
    private static let userPathIndex: [String: NodeHint] = [
        "Library/Developer/Xcode/DerivedData": NodeHint(
            label: "Xcode Build Cache", safety: .rebuilds,
            description: "Intermediate build artifacts and indexes; Xcode regenerates these on next build."
        ),
        "Library/Developer/Xcode/iOS DeviceSupport": NodeHint(
            label: "Xcode iOS Device Symbols", safety: .rebuilds,
            description: "Debug symbols copied from connected iOS devices; Xcode re-downloads them if needed."
        ),
        "Library/Developer/Xcode/watchOS DeviceSupport": NodeHint(
            label: "Xcode watchOS Device Symbols", safety: .rebuilds,
            description: "Debug symbols for connected Apple Watch devices; re-downloaded if needed."
        ),
        "Library/Developer/Xcode/tvOS DeviceSupport": NodeHint(
            label: "Xcode tvOS Device Symbols", safety: .rebuilds,
            description: "Debug symbols for connected Apple TV devices; re-downloaded if needed."
        ),
        "Library/Developer/Xcode/visionOS DeviceSupport": NodeHint(
            label: "Xcode visionOS Device Symbols", safety: .rebuilds,
            description: "Debug symbols for connected Vision Pro devices; re-downloaded if needed."
        ),
        "Library/Developer/Xcode/Archives": NodeHint(
            label: "Xcode App Archives", safety: .caution,
            description: "Archived app builds and dSYMs used for App Store distribution and crash symbolication."
        ),
        "Library/Developer/CoreSimulator": NodeHint(
            label: "iOS Simulators", safety: .caution,
            description: "Simulator devices and app state; deleting removes simulated data and may require re-downloading runtimes."
        ),
        "Library/Developer/CoreSimulator/Caches": NodeHint(
            label: "Simulator Caches", safety: .rebuilds,
            description: "Cached simulator runtime images and dyld caches; recreated automatically."
        ),
        "Library/Caches/Homebrew": NodeHint(
            label: "Homebrew Download Cache", safety: .rebuilds,
            description: "Downloaded formula bottles and casks; Homebrew re-downloads them when needed."
        ),
        "Library/Caches/CocoaPods": NodeHint(
            label: "CocoaPods Cache", safety: .rebuilds,
            description: "Cached CocoaPods specs and archives; re-downloaded on pod install."
        ),
        "Library/Caches/com.apple.dt.Xcode": NodeHint(
            label: "Xcode Caches", safety: .rebuilds,
            description: "Xcode internal caches; regenerated automatically."
        ),
        "Library/Caches/org.swift.swiftpm": NodeHint(
            label: "SwiftPM Cache", safety: .rebuilds,
            description: "Cached Swift Package Manager repositories; re-fetched on build."
        ),
        "Library/Caches/pip": NodeHint(
            label: "pip Package Cache", safety: .rebuilds,
            description: "Cached Python wheels and packages; re-downloaded on pip install."
        ),
        "Library/Caches/uv": NodeHint(
            label: "uv Package Cache", safety: .rebuilds,
            description: "Cached Python packages and wheels managed by uv; re-downloaded as needed."
        ),
        "Library/Caches/Yarn": NodeHint(
            label: "Yarn Package Cache", safety: .rebuilds,
            description: "Cached JavaScript packages; Yarn re-downloads them on install."
        ),
        "Library/Caches/pnpm": NodeHint(
            label: "pnpm Cache", safety: .rebuilds,
            description: "Cached pnpm metadata and packages; re-downloaded on install."
        ),
        "Library/pnpm/store": NodeHint(
            label: "pnpm Package Store", safety: .rebuilds,
            description: "Content-addressable pnpm package store; re-downloaded on pnpm install."
        ),
        "Library/Caches/go-build": NodeHint(
            label: "Go Build Cache", safety: .rebuilds,
            description: "Compiled Go build cache; regenerated automatically on go build or test."
        ),
        "Library/Caches/JetBrains": NodeHint(
            label: "JetBrains IDE Caches", safety: .rebuilds,
            description: "IDE indexes and caches; JetBrains IDEs rebuild these on next launch."
        ),
        "Library/Caches": NodeHint(
            label: "macOS App Caches", safety: .caution,
            description: "App cache directories; most subfolders rebuild, though active apps may need a restart."
        ),
        "Library/Logs": NodeHint(
            label: "macOS App Logs", safety: .rebuilds,
            description: "Diagnostic and application log files; recreated as apps run."
        ),
        "Library/Containers/com.docker.docker/Data/vms": NodeHint(
            label: "Docker Desktop Disk Image", safety: .caution,
            description: "Stores Docker images, containers, and volumes; deleting removes local container data."
        ),
        "Library/Application Support/MobileSync/Backup": NodeHint(
            label: "iOS Device Backups", safety: .caution,
            description: "Local iPhone and iPad backups; deleting permanently removes those backups."
        ),
        "go/pkg/mod": NodeHint(
            label: "Go Module Cache", safety: .rebuilds,
            description: "Downloaded Go module dependencies; re-fetched on next build."
        ),
        ".npm": NodeHint(
            label: "npm Cache", safety: .rebuilds,
            description: "Cached npm tarballs and metadata; npm re-downloads packages as needed."
        ),
        ".bun/install/cache": NodeHint(
            label: "Bun Package Cache", safety: .rebuilds,
            description: "Cached Bun packages; re-downloaded on bun install."
        ),
        ".cargo/registry": NodeHint(
            label: "Cargo Crate Cache", safety: .rebuilds,
            description: "Downloaded Rust crates; Cargo re-downloads them on next build."
        ),
        ".cargo/git": NodeHint(
            label: "Cargo Git Cache", safety: .rebuilds,
            description: "Checked-out Rust git dependencies; Cargo re-fetches them on next build."
        ),
        ".gradle/caches": NodeHint(
            label: "Gradle Build Cache", safety: .rebuilds,
            description: "Cached Gradle dependencies and build outputs; re-downloaded on next build."
        ),
        ".m2/repository": NodeHint(
            label: "Maven Repository Cache", safety: .rebuilds,
            description: "Local Maven artifact cache; re-downloaded on next build."
        ),
        ".cache/huggingface": NodeHint(
            label: "Hugging Face Model Cache", safety: .rebuilds,
            description: "Downloaded ML models and datasets; re-downloadable when needed."
        ),
        ".ollama/models": NodeHint(
            label: "Ollama Local Models", safety: .caution,
            description: "Local LLM model weights; re-downloadable, though custom Modelfiles may depend on them."
        )
    ]

    private static let cachedHome: String = FileManager.default.homeDirectoryForCurrentUser.path

    public static func classifyBuiltIn(node: DiskNode, parent: DiskNode?) -> NodeHint? {
        guard node.isDir else { return nil }
        let p = node.path

        if let rel = userRelativePath(p), let hint = userPathIndex[rel] {
            return hint
        }

        switch node.name {
        case "node_modules":
            let parentDir = (p as NSString).deletingLastPathComponent
            if parentDir.contains("/node_modules/") || parentDir.hasSuffix("/node_modules") {
                return nil
            }
            return NodeHint(
                label: "Node.js Dependencies", safety: .rebuilds,
                description: "Installed npm, Yarn, or pnpm packages; re-run package install to restore."
            )

        case "DerivedData":
            return NodeHint(
                label: "Xcode Build Cache", safety: .rebuilds,
                description: "Intermediate Xcode build artifacts; regenerated on next build."
            )

        case "Pods":
            if hasSibling(node, parent: parent, names: ["Podfile", "Podfile.lock"]) {
                return NodeHint(
                    label: "CocoaPods Dependencies", safety: .rebuilds,
                    description: "Installed CocoaPods libraries; re-run pod install to restore."
                )
            }

        case ".next":
            if hasSibling(node, parent: parent, names: ["package.json"]) {
                return NodeHint(
                    label: "Next.js Build Cache", safety: .rebuilds,
                    description: "Next.js compiled build output and cache; regenerated on next dev or build."
                )
            }

        case "target":
            if hasSibling(node, parent: parent, names: ["Cargo.toml"]) {
                return NodeHint(
                    label: "Rust Build Artifacts", safety: .rebuilds,
                    description: "Cargo compiled targets and incremental cache; regenerated on next cargo build."
                )
            }
            if hasSibling(node, parent: parent, names: ["pom.xml"]) {
                return NodeHint(
                    label: "Maven Build Output", safety: .rebuilds,
                    description: "Compiled Maven build directory; regenerated on next mvn build."
                )
            }

        case ".venv", "venv":
            if node.name == ".venv" || hasSibling(node, parent: parent, names: ["pyproject.toml", "requirements.txt", "setup.py"]) {
                return NodeHint(
                    label: "Python Virtual Environment", safety: .rebuilds,
                    description: "Local Python virtualenv packages; recreate from pyproject.toml or requirements.txt."
                )
            }

        case ".gradle":
            if hasSibling(node, parent: parent, names: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]) {
                return NodeHint(
                    label: "Project Gradle Cache", safety: .rebuilds,
                    description: "Local project Gradle cache; regenerated on next Gradle build."
                )
            }

        default:
            break
        }
        return nil
    }

    public static func classify(
        node: DiskNode,
        parent: DiskNode?,
        customRules: CustomRulesConfig?,
        homeOverride: String? = nil
    ) -> NodeHint? {
        guard node.isDir else { return nil }
        if let cfg = customRules, (!cfg.ignore.isEmpty || !cfg.add.isEmpty) {
            let home = homeOverride ?? Self.cachedHome
            let p = node.path

            for rawIg in cfg.ignore {
                let ig = rawIg.trimmingCharacters(in: .whitespacesAndNewlines)
                if ig.isEmpty { continue }
                if ig.contains("/") || ig == "~" {
                    if CustomRulesStore.expandHome(ig, home: home) == p {
                        return nil
                    }
                } else if node.name == ig {
                    return nil
                }
            }

            for r in cfg.add {
                if let rp = r.path, !rp.isEmpty, CustomRulesStore.expandHome(rp, home: home) == p {
                    return r.toHint(folderName: node.name)
                }
            }

            for r in cfg.add {
                if let rn = r.name, !rn.isEmpty, node.name == rn {
                    if let sib = r.sibling, !sib.isEmpty {
                        if hasSibling(node, parent: parent, names: [sib]) {
                            return r.toHint(folderName: node.name)
                        }
                    } else {
                        return r.toHint(folderName: node.name)
                    }
                }
            }
        }
        return classifyBuiltIn(node: node, parent: parent)
    }

    private static func userRelativePath(_ p: String) -> String? {
        guard p.hasPrefix("/Users/") else { return nil }
        let rest = p.dropFirst("/Users/".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let after = rest.index(after: slash)
        guard after < rest.endIndex else { return nil }
        return String(rest[after...])
    }

    static func hasSibling(_ cur: DiskNode, parent: DiskNode?, names: [String]) -> Bool {
        if let parent = parent {
            for c in parent.children {
                if names.contains(c.name) { return true }
            }
            return false
        }
        let dir = (cur.path as NSString).deletingLastPathComponent
        guard !dir.isEmpty && dir != cur.path else { return false }
        let fm = FileManager.default
        for want in names {
            if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(want)) {
                return true
            }
        }
        return false
    }
}
