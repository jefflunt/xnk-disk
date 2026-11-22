import Foundation
import Combine
import XnkDiskCore

/// Shared singleton store for disk volumes, cached/completed scans, active per-volume scans,
/// custom rules, and the Undo stack. Individual windows own their own independent `AppModel`
/// view state and observe `DiskStore`.
@MainActor
final class DiskStore: ObservableObject {
    static let shared = DiskStore()

    @Published var volumes: [VolumeInfo] = []
    @Published var scanResults: [String: ScanResult] = [:]
    @Published var activeScanProgress: [String: ScanProgress] = [:]
    @Published var undoStack: [UndoEntry] = []
    @Published var isBusyMutating: Bool = false
    @Published var cacheLoaded: Bool = false

    private(set) var customRules: CustomRulesConfig = CustomRulesConfig()
    private var activeScanners: [String: DiskScanner] = [:]
    private var progressTimer: Timer?

    /// Serial queue for heavy tree mutations (sortRecursive, cache save) and projections.
    let treeQueue = DispatchQueue(label: "com.jefflunt.xnk-disk.tree", qos: .userInitiated)

    /// Emits volumeID (or nil for global rule change) whenever a volume's tree or rules change.
    let dataChanged = PassthroughSubject<String?, Never>()

    private init() {
        customRules = CustomRulesStore.load()
        refreshVolumes()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cached = ScanCacheStore.loadAll()
            Task { @MainActor [weak self] in
                guard let self else { return }
                for (k, v) in cached where self.scanResults[k] == nil {
                    self.scanResults[k] = v
                }
                self.cacheLoaded = true
                self.dataChanged.send(nil)
            }
        }
    }

    func refreshVolumes() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let vols = VolumeDiscovery.list()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.volumes = vols
            }
        }
    }

    func isScanning(_ volumeID: String) -> Bool {
        activeScanners[volumeID] != nil
    }

    func isScanned(_ volumeID: String) -> Bool {
        scanResults[volumeID] != nil
    }

    func scannedAt(_ volumeID: String) -> Date? {
        scanResults[volumeID]?.scannedAt
    }

    // MARK: - Parallel Per-Volume Scanning
    func startScan(volumeID: String, onComplete: @escaping @MainActor (Bool) -> Void) {
        guard activeScanners[volumeID] == nil,
              let vol = volumes.first(where: { $0.id == volumeID }) else { return }

        let scanner = DiskScanner(options: ScanOptions(
            volumeID: vol.id,
            volumeName: vol.name,
            rootPath: vol.mountPoint,
            allowedDevs: vol.allowedDevs
        ))
        activeScanners[vol.id] = scanner
        activeScanProgress[vol.id] = scanner.progress(active: true)
        ensureProgressTimer()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = scanner.run()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeScanners.removeValue(forKey: vol.id)
                self.activeScanProgress.removeValue(forKey: vol.id)
                if self.activeScanners.isEmpty {
                    self.progressTimer?.invalidate()
                    self.progressTimer = nil
                }

                self.refreshVolumes()
                if let result {
                    self.scanResults[vol.id] = result
                    self.treeQueue.async {
                        try? ScanCacheStore.save(result)
                    }
                    self.dataChanged.send(vol.id)
                    onComplete(true)
                } else {
                    onComplete(false)
                }
            }
        }
    }

    func cancelScan(volumeID: String) {
        activeScanners[volumeID]?.cancel()
        activeScanners.removeValue(forKey: volumeID)
        activeScanProgress.removeValue(forKey: volumeID)
        if activeScanners.isEmpty {
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    private func ensureProgressTimer() {
        guard progressTimer == nil else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var next: [String: ScanProgress] = [:]
                for (vid, sc) in self.activeScanners {
                    next[vid] = sc.progress(active: true)
                }
                self.activeScanProgress = next
            }
        }
    }

    // MARK: - Custom Rules
    func markRebuilds(path: String, label: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        customRules.markPathRebuilds(path, label: label, home: home)
        try? CustomRulesStore.save(customRules)
        dataChanged.send(nil)
    }

    func unmarkRebuilds(path: String) {
        unmarkRebuildsBatch(paths: [path])
    }

    func unmarkRebuildsBatch(paths: [String]) {
        guard !paths.isEmpty else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in paths {
            let clean = cleanPath(path)
            let dummy = DiskNode(name: (clean as NSString).lastPathComponent, path: clean, isDir: true)
            let hasBuiltIn = DevCacheClassifier.classifyBuiltIn(node: dummy, parent: nil) != nil
            customRules.unmarkPath(clean, home: home, hasBuiltIn: hasBuiltIn)
        }
        try? CustomRulesStore.save(customRules)
        dataChanged.send(nil)
    }

    // MARK: - Trash, Purge & Undo
    func updateScanResult(_ updated: ScanResult) {
        scanResults[updated.volumeID] = updated
        dataChanged.send(updated.volumeID)
    }
}
