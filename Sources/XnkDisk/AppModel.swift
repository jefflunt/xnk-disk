import Foundation
import AppKit
import Combine
import XnkDiskCore

enum ViewMode {
    case overview
    case icicle
}

enum LayoutMode: String, CaseIterable, Identifiable {
    case scroll = "Scrollable"
    case fit = "Fit"
    var id: String { rawValue }
}

struct ToastMessage: Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
    let showUndo: Bool
}

@MainActor
final class AppModel: ObservableObject {
    @Published var volumes: [VolumeInfo] = []
    @Published var selectedVolumeID: String = ""
    @Published var viewMode: ViewMode = .overview
    @Published var layoutMode: LayoutMode = .scroll { didSet { persistPreferences() } }
    @Published var maxDepth: Int = 10 { didSet { persistPreferences() } }
    @Published var groupSmall: Bool = false { didSet { persistPreferences() } }
    @Published var hideFreeSpace: Bool = false { didSet { persistPreferences() } }
    @Published var highlightRebuildsOnly: Bool = false { didSet { persistPreferences() } }
    @Published var vZoom: CGFloat = 1.0

    @Published var isScanning: Bool = false
    @Published var scanProgress: ScanProgress?

    @Published var focusedRoot: ViewNode?
    @Published var treeGeneration: UInt64 = 0
    @Published var breadcrumbs: [Crumb] = []
    @Published var deepestLevel: Int = 0
    @Published var isAtVolumeRoot: Bool = true
    @Published var currentPath: String = ""
    @Published var hasVisibleRebuilds: Bool = false
    @Published var rebuildableTargets: [RebuildableTarget] = []
    @Published var showPurgeSheet: Bool = false
    @Published var isPurging: Bool = false

    @Published var undoStack: [UndoEntry] = []
    @Published var toast: ToastMessage?

    private(set) var scanResults: [String: ScanResult] = [:]
    private var customRules: CustomRulesConfig = CustomRulesConfig()
    private var activeScanner: DiskScanner?
    private var progressTimer: Timer?
    private var toastTask: Task<Void, Never>?
    private let treeQueue = DispatchQueue(label: "com.jefflunt.xnk-disk.tree", qos: .userInitiated)
    private var treeRequestID: UInt64 = 0

    var selectedVolume: VolumeInfo? {
        volumes.first(where: { $0.id == selectedVolumeID }) ?? volumes.first
    }

    var canTrashFocused: Bool {
        guard let root = focusedRoot, let vol = selectedVolume else { return false }
        return TrashManager.isTrashable(path: root.path, volumeID: vol.id)
    }

    private var isBootstrapping: Bool = true

    init() {
        let prefs = PreferencesStore.load()
        layoutMode = LayoutMode(rawValue: prefs.layoutModeRaw) ?? .scroll
        maxDepth = prefs.maxDepth
        groupSmall = prefs.groupSmall
        hideFreeSpace = prefs.hideFreeSpace
        highlightRebuildsOnly = prefs.highlightRebuildsOnly
        isBootstrapping = false

        customRules = CustomRulesStore.load()
        refreshVolumes()

        // Load LZFSE scan cache off the main thread so the window opens instantaneously.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cached = ScanCacheStore.loadAll()
            Task { @MainActor [weak self] in
                guard let self else { return }
                for (k, v) in cached where self.scanResults[k] == nil {
                    self.scanResults[k] = v
                }
                self.objectWillChange.send()
            }
        }
    }

    private func persistPreferences() {
        guard !isBootstrapping else { return }
        PreferencesStore.save(ViewPreferences(
            layoutModeRaw: layoutMode.rawValue,
            maxDepth: maxDepth,
            groupSmall: groupSmall,
            hideFreeSpace: hideFreeSpace,
            highlightRebuildsOnly: highlightRebuildsOnly
        ))
    }

    func refreshVolumes() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let vols = VolumeDiscovery.list()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.volumes = vols
                if self.selectedVolumeID.isEmpty || !vols.contains(where: { $0.id == self.selectedVolumeID }) {
                    self.selectedVolumeID = vols.first?.id ?? ""
                }
            }
        }
    }

    func isScanned(_ volumeID: String) -> Bool {
        scanResults[volumeID] != nil
    }

    func scannedAt(_ volumeID: String) -> Date? {
        scanResults[volumeID]?.scannedAt
    }

    func selectVolume(_ id: String) {
        selectedVolumeID = id
        if scanResults[id] != nil {
            openTree(volumeID: id, path: "", resetZoom: true)
        } else {
            viewMode = .overview
        }
    }

    func goHome() {
        viewMode = .overview
        vZoom = 1.0
    }

    func openTree(volumeID: String, path: String, resetZoom: Bool = true) {
        guard let res = scanResults[volumeID] else {
            viewMode = .overview
            return
        }
        selectedVolumeID = volumeID
        let vol = volumes.first(where: { $0.id == volumeID })
        let reqMaxDepth = maxDepth
        let reqGroupSmall = groupSmall
        let reqRules = customRules
        treeRequestID &+= 1
        let reqID = treeRequestID

        // Project the view tree & collect rebuildable folders off the main thread.
        treeQueue.async { [weak self] in
            let (focusNode, crumbs) = res.root.findPath(path)
            let isRoot = (focusNode === res.root)
            let scaleBytes: UInt64
            if isRoot, let v = vol, v.totalBytes > 0 {
                scaleBytes = v.totalBytes
            } else {
                scaleBytes = focusNode.size
            }

            let (projected, deepest) = projectView(
                root: focusNode,
                maxDepth: reqMaxDepth,
                groupSmall: reqGroupSmall,
                scaleBytes: scaleBytes,
                rules: reqRules
            )
            let targets = focusNode.collectRebuildableFolders(customRules: reqRules)
            let hasRebuilds = !targets.isEmpty || Self.containsRebuildsHint(projected)

            Task { @MainActor [weak self] in
                guard let self, self.treeRequestID == reqID else { return }
                self.focusedRoot = projected
                self.breadcrumbs = crumbs
                self.deepestLevel = deepest
                self.isAtVolumeRoot = isRoot
                self.currentPath = projected.path
                self.rebuildableTargets = targets
                self.hasVisibleRebuilds = hasRebuilds
                if resetZoom {
                    self.vZoom = 1.0
                }
                self.treeGeneration &+= 1
                self.viewMode = .icicle
            }
        }
    }

    func reloadCurrentTree(resetZoom: Bool = false) {
        guard viewMode == .icicle, !selectedVolumeID.isEmpty else { return }
        openTree(volumeID: selectedVolumeID, path: currentPath, resetZoom: resetZoom)
    }

    private nonisolated static func containsRebuildsHint(_ node: ViewNode) -> Bool {
        if node.hint?.safety == .rebuilds { return true }
        for c in node.children {
            if containsRebuildsHint(c) { return true }
        }
        return false
    }

    // MARK: - Parallel Scanning
    func startScan(volumeID: String) {
        guard !isScanning, let vol = volumes.first(where: { $0.id == volumeID }) else { return }
        selectedVolumeID = volumeID
        isScanning = true

        let scanner = DiskScanner(options: ScanOptions(
            volumeID: vol.id,
            volumeName: vol.name,
            rootPath: vol.mountPoint,
            allowedDevs: vol.allowedDevs
        ))
        activeScanner = scanner
        scanProgress = scanner.progress(active: true)

        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let sc = self.activeScanner else { return }
                self.scanProgress = sc.progress(active: true)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = scanner.run()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.progressTimer?.invalidate()
                self.progressTimer = nil
                self.activeScanner = nil
                self.isScanning = false
                self.scanProgress = nil

                self.refreshVolumes()
                if let result {
                    self.scanResults[vol.id] = result
                    DispatchQueue.global(qos: .utility).async {
                        try? ScanCacheStore.save(result)
                    }
                    self.openTree(volumeID: vol.id, path: "", resetZoom: true)
                }
            }
        }
    }

    func cancelScan() {
        activeScanner?.cancel()
        progressTimer?.invalidate()
        progressTimer = nil
        isScanning = false
        scanProgress = nil
    }

    // MARK: - Finder, Trash & Undo
    func revealInFinder(path: String) {
        guard !path.isEmpty, !path.hasSuffix("/*"), !path.hasSuffix("(direct files)") else { return }
        let url = URL(fileURLWithPath: cleanPath(path))
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func moveToTrash(path: String) {
        guard !isPurging, let vol = selectedVolume, let res = scanResults[vol.id] else { return }
        let volID = vol.id
        isPurging = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let trashedPath = try TrashManager.moveToTrash(path: path, volumeID: volID)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isPurging = false
                    if let removed = res.root.removePath(path) {
                        self.undoStack.append(UndoEntry(
                            volumeID: volID,
                            name: removed.removed.name,
                            originalPath: cleanPath(path),
                            trashedPath: trashedPath,
                            parentPath: removed.parentPath,
                            removedNode: removed.removed
                        ))
                        let nextPath = (cleanPath(self.currentPath) == cleanPath(path)) ? removed.parentPath : self.currentPath
                        let updatedRes = ScanResult(
                            volumeID: res.volumeID,
                            volumeName: res.volumeName,
                            root: res.root,
                            totalFiles: res.root.files,
                            totalDirs: res.root.dirs,
                            skippedPerm: res.skippedPerm,
                            scannedAt: res.scannedAt,
                            durationMs: res.durationMs
                        )
                        self.scanResults[volID] = updatedRes
                        DispatchQueue.global(qos: .utility).async {
                            try? ScanCacheStore.save(updatedRes)
                        }
                        self.showToast("Moved \"\(removed.removed.name)\" to Trash", showUndo: true)
                        self.openTree(volumeID: volID, path: nextPath, resetZoom: false)
                    }
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.isPurging = false
                    self?.showToast(error.localizedDescription, isError: true)
                }
            }
        }
    }

    func undoLastTrash() {
        guard !isPurging, let entry = undoStack.popLast() else { return }

        if !entry.purgedFolders.isEmpty {
            isPurging = true
            let items = entry.items
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let outcome = TrashManager.restoreItems(items)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isPurging = false
                    if outcome.restored == 0 && outcome.failed > 0 {
                        self.undoStack.append(entry)
                        self.showToast("Could not restore purged items from Trash", isError: true)
                        return
                    }
                    if let res = self.scanResults[entry.volumeID] {
                        for snap in entry.purgedFolders {
                            res.root.restoreDirectoryContents(snap)
                        }
                        let updatedRes = ScanResult(
                            volumeID: res.volumeID,
                            volumeName: res.volumeName,
                            root: res.root,
                            totalFiles: res.root.files,
                            totalDirs: res.root.dirs,
                            skippedPerm: res.skippedPerm,
                            scannedAt: res.scannedAt,
                            durationMs: res.durationMs
                        )
                        self.scanResults[entry.volumeID] = updatedRes
                        self.treeQueue.async {
                            res.root.sortRecursive()
                            try? ScanCacheStore.save(updatedRes)
                        }
                    }
                    let msg = outcome.failed > 0
                        ? "Restored \"\(entry.name)\" (\(outcome.failed) items could not be restored)"
                        : "Restored \"\(entry.name)\" from Trash"
                    self.showToast(msg)
                    if self.viewMode == .icicle && self.selectedVolumeID == entry.volumeID {
                        self.reloadCurrentTree(resetZoom: false)
                    }
                }
            }
            return
        }

        guard let item = entry.items.first,
              let parentPath = entry.singleRemovedParentPath,
              let removedNode = entry.singleRemovedNode else { return }

        isPurging = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try TrashManager.restore(trashedPath: item.trashedPath, to: item.originalPath)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isPurging = false
                    if let res = self.scanResults[entry.volumeID] {
                        res.root.restoreNode(parentPath: parentPath, restored: removedNode)
                        let updatedRes = ScanResult(
                            volumeID: res.volumeID,
                            volumeName: res.volumeName,
                            root: res.root,
                            totalFiles: res.root.files,
                            totalDirs: res.root.dirs,
                            skippedPerm: res.skippedPerm,
                            scannedAt: res.scannedAt,
                            durationMs: res.durationMs
                        )
                        self.scanResults[entry.volumeID] = updatedRes
                        DispatchQueue.global(qos: .utility).async {
                            try? ScanCacheStore.save(updatedRes)
                        }
                    }
                    self.showToast("Restored \"\(entry.name)\" from Trash")
                    if self.viewMode == .icicle && self.selectedVolumeID == entry.volumeID {
                        self.reloadCurrentTree(resetZoom: false)
                    }
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isPurging = false
                    self.undoStack.append(entry)
                    self.showToast("Could not restore: \(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    func purgeRebuildable() {
        guard !isPurging,
              let vol = selectedVolume,
              let res = scanResults[vol.id],
              !rebuildableTargets.isEmpty else { return }

        let targets = rebuildableTargets
        let targetPaths = targets.map { $0.node.path }
        let volID = vol.id
        showPurgeSheet = false
        isPurging = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var allMoved: [TrashedItem] = []
            var purgedPaths: [String] = []
            var totalFailed = 0

            for path in targetPaths {
                do {
                    let r = try TrashManager.purgeDirectoryContents(at: path, volumeID: volID)
                    if !r.movedItems.isEmpty {
                        allMoved.append(contentsOf: r.movedItems)
                        purgedPaths.append(path)
                    }
                    totalFailed += r.failedCount
                } catch {
                    totalFailed += 1
                }
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPurging = false

                guard !allMoved.isEmpty else {
                    self.showToast("No rebuildable items could be moved to Trash", isError: true)
                    return
                }

                var snapshots: [PurgedFolderSnapshot] = []
                for p in purgedPaths {
                    if let snap = res.root.clearDirectoryContents(at: p) {
                        snapshots.append(snap)
                    }
                }

                let folderCount = snapshots.count
                let label = folderCount == 1
                    ? "Purge (\(URL(fileURLWithPath: snapshots[0].folderPath).lastPathComponent))"
                    : "Purge (\(folderCount) folders)"

                self.undoStack.append(UndoEntry(
                    volumeID: volID,
                    name: label,
                    items: allMoved,
                    purgedFolders: snapshots
                ))

                let updatedRes = ScanResult(
                    volumeID: res.volumeID,
                    volumeName: res.volumeName,
                    root: res.root,
                    totalFiles: res.root.files,
                    totalDirs: res.root.dirs,
                    skippedPerm: res.skippedPerm,
                    scannedAt: res.scannedAt,
                    durationMs: res.durationMs
                )
                self.scanResults[volID] = updatedRes
                self.treeQueue.async {
                    res.root.sortRecursive()
                    try? ScanCacheStore.save(updatedRes)
                }

                let totalFreed = snapshots.reduce(UInt64(0)) { $0 + $1.oldSize }
                let summary = totalFailed > 0
                    ? "Moved \(Formatters.bytes(totalFreed)) from \(folderCount) folders to Trash (\(totalFailed) skipped)"
                    : "Moved \(Formatters.bytes(totalFreed)) from \(folderCount) rebuildable folders to Trash"
                self.showToast(summary, showUndo: true)
                self.reloadCurrentTree(resetZoom: false)
            }
        }
    }

    // MARK: - Custom Rules (Right-Click Mark / Unmark)
    func markRebuilds(path: String, label: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        customRules.markPathRebuilds(path, label: label, home: home)
        try? CustomRulesStore.save(customRules)
        showToast("Marked \"\(label)\" as \"Rebuildable\"")
        reloadCurrentTree(resetZoom: false)
    }

    func unmarkRebuilds(path: String, label: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let clean = cleanPath(path)
        let dummy = DiskNode(name: (clean as NSString).lastPathComponent, path: clean, isDir: true)
        let hasBuiltIn = DevCacheClassifier.classifyBuiltIn(node: dummy, parent: nil) != nil
        customRules.unmarkPath(clean, home: home, hasBuiltIn: hasBuiltIn)
        try? CustomRulesStore.save(customRules)
        showToast("Removed \"Rebuildable\" tag from \"\(label)\"")
        reloadCurrentTree(resetZoom: false)
    }

    // MARK: - Zoom
    func adjustZoom(multiplier: CGFloat) {
        vZoom = min(25.0, max(1.0, vZoom * multiplier))
    }

    func resetZoom() {
        vZoom = 1.0
    }

    // MARK: - Toast
    func showToast(_ text: String, isError: Bool = false, showUndo: Bool = false) {
        toastTask?.cancel()
        toast = ToastMessage(text: text, isError: isError, showUndo: showUndo)
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
