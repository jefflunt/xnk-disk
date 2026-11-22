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
    @Published var layoutMode: LayoutMode = .scroll
    @Published var maxDepth: Int = 10
    @Published var groupSmall: Bool = false
    @Published var hideFreeSpace: Bool = false
    @Published var highlightRebuildsOnly: Bool = false
    @Published var vZoom: CGFloat = 1.0

    @Published var isScanning: Bool = false
    @Published var scanProgress: ScanProgress?

    @Published var focusedRoot: ViewNode?
    @Published var breadcrumbs: [Crumb] = []
    @Published var deepestLevel: Int = 0
    @Published var isAtVolumeRoot: Bool = true
    @Published var currentPath: String = ""
    @Published var hasVisibleRebuilds: Bool = false

    @Published var undoStack: [UndoEntry] = []
    @Published var toast: ToastMessage?

    private(set) var scanResults: [String: ScanResult] = [:]
    private var customRules: CustomRulesConfig = CustomRulesConfig()
    private var activeScanner: DiskScanner?
    private var progressTimer: Timer?
    private var toastTask: Task<Void, Never>?

    var selectedVolume: VolumeInfo? {
        volumes.first(where: { $0.id == selectedVolumeID }) ?? volumes.first
    }

    var canTrashFocused: Bool {
        guard let root = focusedRoot, let vol = selectedVolume else { return false }
        return TrashManager.isTrashable(path: root.path, volumeID: vol.id)
    }

    init() {
        customRules = CustomRulesStore.load()
        scanResults = ScanCacheStore.loadAll()
        refreshVolumes()
    }

    func refreshVolumes() {
        volumes = VolumeDiscovery.list()
        if selectedVolumeID.isEmpty || !volumes.contains(where: { $0.id == selectedVolumeID }) {
            selectedVolumeID = volumes.first?.id ?? ""
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
        let (focusNode, crumbs) = res.root.findPath(path)
        let isRoot = (focusNode === res.root)
        let vol = volumes.first(where: { $0.id == volumeID })

        let scaleBytes: UInt64
        if isRoot, let v = vol, v.totalBytes > 0 {
            scaleBytes = v.totalBytes
        } else {
            scaleBytes = focusNode.size
        }

        let (projected, deepest) = projectView(
            root: focusNode,
            maxDepth: maxDepth,
            groupSmall: groupSmall,
            scaleBytes: scaleBytes,
            rules: customRules
        )

        focusedRoot = projected
        breadcrumbs = crumbs
        deepestLevel = deepest
        isAtVolumeRoot = isRoot
        currentPath = projected.path
        hasVisibleRebuilds = containsRebuildsHint(projected)
        if !hasVisibleRebuilds {
            highlightRebuildsOnly = false
        }
        if resetZoom {
            vZoom = 1.0
        }
        viewMode = .icicle
    }

    func reloadCurrentTree(resetZoom: Bool = false) {
        guard viewMode == .icicle, !selectedVolumeID.isEmpty else { return }
        openTree(volumeID: selectedVolumeID, path: currentPath, resetZoom: resetZoom)
    }

    private func containsRebuildsHint(_ node: ViewNode) -> Bool {
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
        guard let vol = selectedVolume, let res = scanResults[vol.id] else { return }
        do {
            let trashedPath = try TrashManager.moveToTrash(path: path, volumeID: vol.id)
            if let removed = res.root.removePath(path) {
                undoStack.append(UndoEntry(
                    volumeID: vol.id,
                    name: removed.removed.name,
                    originalPath: cleanPath(path),
                    trashedPath: trashedPath,
                    parentPath: removed.parentPath,
                    removedNode: removed.removed
                ))
                let nextPath = (cleanPath(currentPath) == cleanPath(path)) ? removed.parentPath : currentPath
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
                scanResults[vol.id] = updatedRes
                DispatchQueue.global(qos: .utility).async {
                    try? ScanCacheStore.save(updatedRes)
                }
                showToast("Moved \"\(removed.removed.name)\" to Trash", showUndo: true)
                openTree(volumeID: vol.id, path: nextPath, resetZoom: false)
            }
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    func undoLastTrash() {
        guard let entry = undoStack.popLast() else { return }
        do {
            try TrashManager.restore(trashedPath: entry.trashedPath, to: entry.originalPath)
            if let res = scanResults[entry.volumeID] {
                res.root.restoreNode(parentPath: entry.parentPath, restored: entry.removedNode)
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
                scanResults[entry.volumeID] = updatedRes
                DispatchQueue.global(qos: .utility).async {
                    try? ScanCacheStore.save(updatedRes)
                }
            }
            showToast("Restored \"\(entry.name)\" from Trash")
            if viewMode == .icicle && selectedVolumeID == entry.volumeID {
                reloadCurrentTree(resetZoom: false)
            }
        } catch {
            undoStack.append(entry)
            showToast("Could not restore: \(error.localizedDescription)", isError: true)
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
