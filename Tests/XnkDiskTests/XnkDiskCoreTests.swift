import XCTest
@testable import XnkDiskCore

final class XnkDiskCoreTests: XCTestCase {

    // MARK: - Volumes
    func testVolumeDiscoveryFindsBootVolume() {
        let vols = VolumeDiscovery.list()
        XCTAssertFalse(vols.isEmpty, "Expected at least one mounted volume")
        guard let boot = vols.first(where: { $0.isBoot }) else {
            XCTFail("Expected boot volume '/'")
            return
        }
        XCTAssertEqual(boot.mountPoint, "/")
        XCTAssertGreaterThan(boot.totalBytes, 0)
        XCTAssertFalse(boot.allowedDevs.isEmpty)
    }

    // MARK: - Parallel Multi-Core Scanner & Hard-Link Dedup
    func testParallelScanHardLinksAndSymlinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("xnk-scan-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Create multiple subdirectories to exercise multi-core worker dispatch.
        let payload = Data(repeating: 0xAB, count: 64 * 1024) // 64 KB
        for i in 0..<8 {
            let sub = root.appendingPathComponent("dir-\(i)")
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            try payload.write(to: sub.appendingPathComponent("file-\(i).bin"))
        }

        // Create a hard link to dir-0/file-0.bin inside dir-1; must NOT double-count.
        let orig = root.appendingPathComponent("dir-0/file-0.bin")
        let link = root.appendingPathComponent("dir-1/hardlink.bin")
        try fm.linkItem(at: orig, to: link)

        // Create a symlink to dir-0; must NOT follow or double-count.
        let sym = root.appendingPathComponent("sym-to-dir0")
        try fm.createSymbolicLink(at: sym, withDestinationURL: root.appendingPathComponent("dir-0"))

        let scanner = DiskScanner(options: ScanOptions(
            volumeID: root.path,
            volumeName: "TestRoot",
            rootPath: root.path,
            workers: 8
        ))
        XCTAssertEqual(scanner.workers, 8)

        guard let res = scanner.run() else {
            XCTFail("Expected non-nil scan result")
            return
        }

        // 8 unique files (hard link deduplicated, symlink ignored)
        XCTAssertEqual(res.totalFiles, 8)
        XCTAssertGreaterThanOrEqual(res.root.size, 8 * 64 * 1024)
        XCTAssertLessThan(res.root.size, 9 * 64 * 1024 + 65536) // definitely not 9+ copies
        XCTAssertEqual(res.root.children.count, 8)
    }

    func testScannerCancellation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("xnk-cancel-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let scanner = DiskScanner(options: ScanOptions(volumeID: root.path, volumeName: "Cancel", rootPath: root.path))
        scanner.cancel()
        XCTAssertNil(scanner.run(), "Canceled scanner should return nil")
    }

    // MARK: - Tree Operations (FindPath, RemovePath, RestoreNode, ProjectView)
    func testTreeMutationAndProjection() {
        let derived = DiskNode(
            name: "DerivedData",
            path: "/Users/alice/Library/Developer/Xcode/DerivedData",
            size: 5_000, apparent: 5_000, files: 100, dirs: 5, isDir: true
        )
        let small1 = DiskNode(name: "a", path: "/Users/alice/Library/Developer/Xcode/a", size: 10, files: 1, isDir: true)
        let small2 = DiskNode(name: "b", path: "/Users/alice/Library/Developer/Xcode/b", size: 10, files: 1, isDir: true)
        let small3 = DiskNode(name: "c", path: "/Users/alice/Library/Developer/Xcode/c", size: 10, files: 1, isDir: true)
        let xcode = DiskNode(
            name: "Xcode",
            path: "/Users/alice/Library/Developer/Xcode",
            size: 5_030, apparent: 5_030, files: 103, dirs: 9, isDir: true,
            children: [derived, small1, small2, small3]
        )

        // FindPath
        let (found, crumbs) = xcode.findPath(derived.path)
        XCTAssertEqual(found.path, derived.path)
        XCTAssertEqual(crumbs.map(\.name), ["Xcode", "DerivedData"])

        // ProjectView with groupSmall = true collapses tiny siblings (<1.2%)
        let (view, depth) = projectView(root: xcode, maxDepth: 5, groupSmall: true, scaleBytes: 5_030)
        XCTAssertEqual(depth, 1)
        XCTAssertEqual(view.children.count, 2) // DerivedData + Other (3 items)
        XCTAssertEqual(view.children[0].hint?.label, "Xcode Build Cache")
        XCTAssertEqual(view.children[0].hint?.safety, .rebuilds)
        XCTAssertTrue(view.children[1].isGrouped)

        // RemovePath & RestoreNode
        guard let removed = xcode.removePath(derived.path) else {
            XCTFail("Expected removePath to succeed")
            return
        }
        XCTAssertEqual(xcode.size, 30)
        XCTAssertEqual(xcode.files, 3)

        XCTAssertTrue(xcode.restoreNode(parentPath: removed.parentPath, restored: removed.removed))
        XCTAssertEqual(xcode.size, 5_030)
        XCTAssertEqual(xcode.files, 103)
        XCTAssertEqual(xcode.children.first?.name, "DerivedData")
    }

    // MARK: - DevCache Classification
    func testDevCacheUserPathsAndSiblingChecks() {
        let derived = DiskNode(name: "DerivedData", path: "/Users/jeff/Library/Developer/Xcode/DerivedData", isDir: true)
        let h1 = DevCacheClassifier.classifyBuiltIn(node: derived, parent: nil)
        XCTAssertEqual(h1?.label, "Xcode Build Cache")
        XCTAssertEqual(h1?.safety, .rebuilds)

        let sim = DiskNode(name: "CoreSimulator", path: "/Users/jeff/Library/Developer/CoreSimulator", isDir: true)
        let h2 = DevCacheClassifier.classifyBuiltIn(node: sim, parent: nil)
        XCTAssertEqual(h2?.label, "iOS Simulators")
        XCTAssertEqual(h2?.safety, .caution)

        // Nested node_modules should NOT be double-tagged
        let topNM = DiskNode(name: "node_modules", path: "/Users/jeff/code/app/node_modules", isDir: true)
        XCTAssertEqual(DevCacheClassifier.classifyBuiltIn(node: topNM, parent: nil)?.safety, .rebuilds)
        let nestedNM = DiskNode(name: "node_modules", path: "/Users/jeff/code/app/node_modules/pkg/node_modules", isDir: true)
        XCTAssertNil(DevCacheClassifier.classifyBuiltIn(node: nestedNM, parent: nil))

        // Rust target/ only matches with Cargo.toml sibling
        let rustTarget = DiskNode(name: "target", path: "/Users/jeff/code/rust/target", isDir: true)
        let rustParent = DiskNode(name: "rust", path: "/Users/jeff/code/rust", isDir: true, children: [
            rustTarget, DiskNode(name: "Cargo.toml", path: "/Users/jeff/code/rust/Cargo.toml", isDir: false)
        ])
        XCTAssertEqual(DevCacheClassifier.classifyBuiltIn(node: rustTarget, parent: rustParent)?.label, "Rust Build Artifacts")

        let plainTarget = DiskNode(name: "target", path: "/Users/jeff/Documents/target", isDir: true)
        let plainParent = DiskNode(name: "Documents", path: "/Users/jeff/Documents", isDir: true, children: [plainTarget])
        XCTAssertNil(DevCacheClassifier.classifyBuiltIn(node: plainTarget, parent: plainParent))
    }

    // MARK: - Custom Rules Persistence & Precedence
    func testCustomRulesRoundTripAndPrecedence() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xnk-rules-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let home = "/Users/alice"

        var cfg = CustomRulesConfig()
        cfg.markPathRebuilds("/Users/alice/Movies/RenderCache", label: "Render Cache", home: home)
        cfg.unmarkPath("/Users/alice/Library/Logs", home: home, hasBuiltIn: true)
        try CustomRulesStore.save(cfg, to: tmp.path)

        let loaded = CustomRulesStore.load(from: tmp.path)
        XCTAssertEqual(loaded.add.first?.path, "~/Movies/RenderCache")

        let renderNode = DiskNode(name: "RenderCache", path: "/Users/alice/Movies/RenderCache", isDir: true)
        let h1 = DevCacheClassifier.classify(node: renderNode, parent: nil, customRules: loaded, homeOverride: home)
        XCTAssertEqual(h1?.label, "Render Cache")
        XCTAssertEqual(h1?.safety, .rebuilds)
        XCTAssertEqual(h1?.custom, true)

        let logsNode = DiskNode(name: "Logs", path: "/Users/alice/Library/Logs", isDir: true)
        XCTAssertNil(DevCacheClassifier.classify(node: logsNode, parent: nil, customRules: loaded, homeOverride: home))
    }

    // MARK: - Scan Cache Persistence (Binary Plist + LZFSE)
    func testScanCacheRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xnk-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let root = DiskNode(name: "Macintosh HD", path: "/", size: 123456, files: 42, dirs: 3, isDir: true)
        let res = ScanResult(
            volumeID: "/", volumeName: "Macintosh HD", root: root,
            totalFiles: 42, totalDirs: 3, skippedPerm: 0, scannedAt: Date(), durationMs: 250
        )
        try ScanCacheStore.save(res, dir: dir.path)

        let loaded = ScanCacheStore.loadAll(dir: dir.path)
        XCTAssertEqual(loaded["/"]?.root.size, 123456)
        XCTAssertEqual(loaded["/"]?.totalFiles, 42)
    }

    // MARK: - Trash Safety Guards
    func testTrashProtectedPaths() {
        XCTAssertFalse(TrashManager.isTrashable(path: "/", volumeID: "/"))
        XCTAssertFalse(TrashManager.isTrashable(path: "/System", volumeID: "/"))
        XCTAssertFalse(TrashManager.isTrashable(path: "/Users", volumeID: "/"))
        XCTAssertFalse(TrashManager.isTrashable(path: "/Users/alice/foo/*", volumeID: "/"))
        XCTAssertFalse(TrashManager.isTrashable(path: "/Users/alice/(direct files)", volumeID: "/"))
        XCTAssertTrue(TrashManager.isTrashable(path: "/Users/alice/Library/Developer/Xcode/DerivedData", volumeID: "/"))
    }
}
