import Foundation
import AppKit
import Combine
import XnkDiskCore

enum ViewMode: String {
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
    let windowID: UUID
    let store: DiskStore
    var onStateChanged: (() -> Void)?

    @Published var selectedVolumeID: String = "" { didSet { notifyStateChanged() } }
    @Published var viewMode: ViewMode = .overview { didSet { notifyStateChanged() } }
    @Published var layoutMode: LayoutMode = .scroll { didSet { notifyStateChanged() } }
    @Published var maxDepth: Int = 10 { didSet { notifyStateChanged() } }
    @Published var groupSmall: Bool = false { didSet { notifyStateChanged() } }
    @Published var hideFreeSpace: Bool = false { didSet { notifyStateChanged() } }
    @Published var highlightRebuildsOnly: Bool = false { didSet { notifyStateChanged() } }
    @Published var vZoom: CGFloat = 1.0 { didSet { notifyStateChanged() } }

    @Published var focusedRoot: ViewNode?
    @Published var treeGeneration: UInt64 = 0
    @Published var breadcrumbs: [Crumb] = []
    @Published var deepestLevel: Int = 0
    @Published var isAtVolumeRoot: Bool = true
    @Published var currentPath: String = "" { didSet { notifyStateChanged() } }
    @Published var hasVisibleRebuilds: Bool = false
    @Published var rebuildableTargets: [RebuildableTarget] = []
    @Published var showPurgeSheet: Bool = false
    @Published var toast: ToastMessage?

    private var isBootstrapping: Bool = true
    private var pendingRestoreIcicle: Bool = false
    private var pendingRestoreZoom: CGFloat = 1.0
    private var treeRequestID: UInt64 = 0
    private var toastTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    var volumes: [VolumeInfo] { store.volumes }
    var undoStack: [UndoEntry] { store.undoStack }
    var isPurging: Bool { store.isBusyMutating }

    var selectedVolume: VolumeInfo? {
        store.volumes.first(where: { $0.id == selectedVolumeID }) ?? store.volumes.first
    }

    var isScanningSelected: Bool {
        guard let vid = selectedVolume?.id else { return false }
        return store.isScanning(vid)
    }

    var activeScanProgressForSelected: ScanProgress? {
        guard let vid = selectedVolume?.id else { return nil }
        return store.activeScanProgress[vid]
    }

    var canTrashFocused: Bool {
        guard let root = focusedRoot, let vol = selectedVolume else { return false }
        return TrashManager.isTrashable(path: root.path, volumeID: vol.id)
    }

    var windowTitle: String {
        if viewMode == .icicle, let vol = selectedVolume {
            return "XNK Disk — \(vol.name)"
        }
        return "XNK Disk"
    }

    init(savedState: SavedWindowState, store: DiskStore) {
        self.windowID = savedState.id
        self.store = store

        self.selectedVolumeID = savedState.selectedVolumeID
        self.layoutMode = LayoutMode(rawValue: savedState.layoutModeRaw) ?? .scroll
        self.maxDepth = savedState.maxDepth
        self.groupSmall = savedState.groupSmall
        self.hideFreeSpace = savedState.hideFreeSpace
        self.highlightRebuildsOnly = savedState.highlightRebuildsOnly
        self.vZoom = CGFloat(max(1.0, min(25.0, savedState.vZoom)))
        self.currentPath = savedState.currentPath

        if savedState.viewModeRaw == ViewMode.icicle.rawValue && !savedState.selectedVolumeID.isEmpty {
            self.pendingRestoreIcicle = true
            self.pendingRestoreZoom = self.vZoom
        }
        self.isBootstrapping = false

        // Forward shared store changes so SwiftUI re-renders this window.
        store.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        store.$volumes
            .sink { [weak self] vols in
                guard let self else { return }
                if self.selectedVolumeID.isEmpty || !vols.contains(where: { $0.id == self.selectedVolumeID }) {
                    if let first = vols.first {
                        self.selectedVolumeID = first.id
                    }
                }
            }
            .store(in: &cancellables)

        store.dataChanged
            .sink { [weak self] changedVolumeID in
                guard let self else { return }
                if self.pendingRestoreIcicle {
                    if self.store.isScanned(self.selectedVolumeID) {
                        let restoreZoom = self.pendingRestoreZoom
                        self.pendingRestoreIcicle = false
                        self.openTree(volumeID: self.selectedVolumeID, path: self.currentPath, resetZoom: false)
                        self.vZoom = restoreZoom
                        return
                    } else if self.store.cacheLoaded {
                        self.pendingRestoreIcicle = false
                    }
                }
                if self.viewMode == .icicle {
                    if changedVolumeID == nil || changedVolumeID == self.selectedVolumeID {
                        self.reloadCurrentTree(resetZoom: false)
                    }
                }
            }
            .store(in: &cancellables)

        // If cache is already loaded (e.g. File -> New Window or restored after boot), restore immediately.
        if pendingRestoreIcicle && store.isScanned(selectedVolumeID) {
            let restoreZoom = pendingRestoreZoom
            pendingRestoreIcicle = false
            openTree(volumeID: selectedVolumeID, path: currentPath, resetZoom: false)
            vZoom = restoreZoom
        }
    }

    func snapshotState(frame: WindowRect?) -> SavedWindowState {
        SavedWindowState(
            id: windowID,
            frame: frame,
            selectedVolumeID: selectedVolumeID,
            viewModeRaw: (viewMode == .icicle || pendingRestoreIcicle) ? ViewMode.icicle.rawValue : ViewMode.overview.rawValue,
            currentPath: currentPath,
            layoutModeRaw: layoutMode.rawValue,
            maxDepth: maxDepth,
            groupSmall: groupSmall,
            hideFreeSpace: hideFreeSpace,
            highlightRebuildsOnly: highlightRebuildsOnly,
            vZoom: Double(vZoom)
        )
    }

    private func notifyStateChanged() {
        guard !isBootstrapping else { return }
        onStateChanged?()
    }

    func isScanned(_ volumeID: String) -> Bool {
        store.isScanned(volumeID)
    }

    func scannedAt(_ volumeID: String) -> Date? {
        store.scannedAt(volumeID)
    }

    func selectVolume(_ id: String) {
        pendingRestoreIcicle = false
        selectedVolumeID = id
        if store.isScanned(id) {
            openTree(volumeID: id, path: "", resetZoom: true)
        } else {
            viewMode = .overview
        }
    }

    func goHome() {
        pendingRestoreIcicle = false
        viewMode = .overview
        vZoom = 1.0
    }

    func openTree(volumeID: String, path: String, resetZoom: Bool = true) {
        guard let res = store.scanResults[volumeID] else {
            viewMode = .overview
            return
        }
        selectedVolumeID = volumeID
        let vol = store.volumes.first(where: { $0.id == volumeID })
        let reqMaxDepth = maxDepth
        let reqGroupSmall = groupSmall
        let reqRules = store.customRules
        treeRequestID &+= 1
        let reqID = treeRequestID

        store.treeQueue.async { [weak self] in
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
        selectedVolumeID = volumeID
        store.startScan(volumeID: volumeID) { [weak self] completed in
            guard let self, completed else { return }
            if self.selectedVolumeID == volumeID {
                self.openTree(volumeID: volumeID, path: "", resetZoom: true)
            }
        }
    }

    func cancelScan() {
        guard let vid = selectedVolume?.id else { return }
        store.cancelScan(volumeID: vid)
    }

    // MARK: - Finder, Trash & Undo
    func revealInFinder(path: String) {
        guard !path.isEmpty, !path.hasSuffix("/*"), !path.hasSuffix("(direct files)") else { return }
        let url = URL(fileURLWithPath: cleanPath(path))
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func moveToTrash(path: String) {
        guard !store.isBusyMutating, let vol = selectedVolume, let res = store.scanResults[vol.id] else { return }
        let volID = vol.id
        store.isBusyMutating = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let trashedPath = try TrashManager.moveToTrash(path: path, volumeID: volID)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.store.isBusyMutating = false
                    if let removed = res.root.removePath(path) {
                        self.store.undoStack.append(UndoEntry(
                            volumeID: volID,
                            name: removed.removed.name,
                            originalPath: cleanPath(path),
                            trashedPath: trashedPath,
                            parentPath: removed.parentPath,
                            removedNode: removed.removed
                        ))
                        if cleanPath(self.currentPath) == cleanPath(path) {
                            self.currentPath = removed.parentPath
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
                        self.store.treeQueue.async {
                            try? ScanCacheStore.save(updatedRes)
                        }
                        self.showToast("Moved \"\(removed.removed.name)\" to Trash", showUndo: true)
                        self.store.updateScanResult(updatedRes)
                    }
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.store.isBusyMutating = false
                    self?.showToast(error.localizedDescription, isError: true)
                }
            }
        }
    }

    func undoLastTrash() {
        guard !store.isBusyMutating, let entry = store.undoStack.popLast() else { return }

        if !entry.purgedFolders.isEmpty {
            store.isBusyMutating = true
            let items = entry.items
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let outcome = TrashManager.restoreItems(items)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.store.isBusyMutating = false
                    if outcome.restored == 0 && outcome.failed > 0 {
                        self.store.undoStack.append(entry)
                        self.showToast("Could not restore purged items from Trash", isError: true)
                        return
                    }
                    if let res = self.store.scanResults[entry.volumeID] {
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
                        self.store.treeQueue.async {
                            res.root.sortRecursive()
                            try? ScanCacheStore.save(updatedRes)
                        }
                        self.store.updateScanResult(updatedRes)
                    }
                    let msg = outcome.failed > 0
                        ? "Restored \"\(entry.name)\" (\(outcome.failed) items could not be restored)"
                        : "Restored \"\(entry.name)\" from Trash"
                    self.showToast(msg)
                }
            }
            return
        }

        guard let item = entry.items.first,
              let parentPath = entry.singleRemovedParentPath,
              let removedNode = entry.singleRemovedNode else { return }

        store.isBusyMutating = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try TrashManager.restore(trashedPath: item.trashedPath, to: item.originalPath)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.store.isBusyMutating = false
                    if let res = self.store.scanResults[entry.volumeID] {
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
                        self.store.treeQueue.async {
                            try? ScanCacheStore.save(updatedRes)
                        }
                        self.store.updateScanResult(updatedRes)
                    }
                    self.showToast("Restored \"\(entry.name)\" from Trash")
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.store.isBusyMutating = false
                    self.store.undoStack.append(entry)
                    self.showToast("Could not restore: \(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    /// Purges ONLY the rebuildable folders within THIS window's selected disk / focused view.
    func purgeRebuildable() {
        guard !store.isBusyMutating,
              let vol = selectedVolume,
              let res = store.scanResults[vol.id],
              !rebuildableTargets.isEmpty else { return }

        let targets = rebuildableTargets
        let targetPaths = targets.map { $0.node.path }
        let volID = vol.id
        showPurgeSheet = false
        store.isBusyMutating = true

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
                self.store.isBusyMutating = false

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

                self.store.undoStack.append(UndoEntry(
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
                self.store.treeQueue.async {
                    res.root.sortRecursive()
                    try? ScanCacheStore.save(updatedRes)
                }

                let totalFreed = snapshots.reduce(UInt64(0)) { $0 + $1.oldSize }
                let summary = totalFailed > 0
                    ? "Moved \(Formatters.bytes(totalFreed)) from \(folderCount) folders to Trash (\(totalFailed) skipped)"
                    : "Moved \(Formatters.bytes(totalFreed)) from \(folderCount) rebuildable folders to Trash"
                self.showToast(summary, showUndo: true)
                self.store.updateScanResult(updatedRes)
            }
        }
    }

    // MARK: - Custom Rules (Right-Click Mark / Unmark)
    func markRebuilds(path: String, label: String) {
        store.markRebuilds(path: path, label: label)
        showToast("Marked \"\(label)\" as \"Rebuildable\"")
    }

    func unmarkRebuilds(path: String, label: String) {
        store.unmarkRebuilds(path: path)
        showToast("Removed \"Rebuildable\" tag from \"\(label)\"")
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
