import Foundation
import Darwin
import os

public struct ScanProgress: Sendable {
    public let volumeID: String
    public let active: Bool
    public let files: Int64
    public let dirs: Int64
    public let bytes: UInt64
    public let skippedPerm: Int64
    public let currentPath: String
    public let elapsedMs: Int64
    public let workers: Int
}

public struct ScanResult: Codable, Sendable {
    public let volumeID: String
    public let volumeName: String
    public let root: DiskNode
    public let totalFiles: Int64
    public let totalDirs: Int64
    public let skippedPerm: Int64
    public let scannedAt: Date
    public let durationMs: Int64

    public init(
        volumeID: String,
        volumeName: String,
        root: DiskNode,
        totalFiles: Int64,
        totalDirs: Int64,
        skippedPerm: Int64,
        scannedAt: Date,
        durationMs: Int64
    ) {
        self.volumeID = volumeID
        self.volumeName = volumeName
        self.root = root
        self.totalFiles = totalFiles
        self.totalDirs = totalDirs
        self.skippedPerm = skippedPerm
        self.scannedAt = scannedAt
        self.durationMs = durationMs
    }
}

public struct ScanOptions {
    public let volumeID: String
    public let volumeName: String
    public let rootPath: String
    public let allowedDevs: [Int32]
    public let workers: Int

    public init(
        volumeID: String,
        volumeName: String,
        rootPath: String,
        allowedDevs: [Int32] = [],
        workers: Int = 0
    ) {
        self.volumeID = volumeID
        self.volumeName = volumeName
        self.rootPath = rootPath
        self.allowedDevs = allowedDevs
        self.workers = workers
    }
}

private struct InodeKey: Hashable {
    let dev: Int32
    let ino: UInt64
}

private final class ShardedInodeSet {
    private static let shardCount = 64
    private final class Shard {
        var lock = os_unfair_lock_s()
        var set = Set<InodeKey>(minimumCapacity: 256)
    }
    private let shards: [Shard]

    init() {
        self.shards = (0..<Self.shardCount).map { _ in Shard() }
    }

    /// Returns true if (dev, ino) was NOT seen before.
    func insert(dev: Int32, ino: UInt64) -> Bool {
        let idx = Int(ino & UInt64(Self.shardCount - 1))
        let sh = shards[idx]
        os_unfair_lock_lock(&sh.lock)
        let inserted = sh.set.insert(InodeKey(dev: dev, ino: ino)).inserted
        os_unfair_lock_unlock(&sh.lock)
        return inserted
    }
}

private final class ScanCounters {
    private var lock = os_unfair_lock_s()
    private var _files: Int64 = 0
    private var _dirs: Int64 = 0
    private var _bytes: UInt64 = 0
    private var _skippedPerm: Int64 = 0
    private var _currentPath: String
    private var _canceled: Bool = false

    init(initialPath: String) {
        self._currentPath = initialPath
    }

    var isCanceled: Bool {
        os_unfair_lock_lock(&lock)
        let c = _canceled
        os_unfair_lock_unlock(&lock)
        return c
    }

    func cancel() {
        os_unfair_lock_lock(&lock)
        _canceled = true
        os_unfair_lock_unlock(&lock)
    }

    func addDir(path: String) {
        os_unfair_lock_lock(&lock)
        _dirs += 1
        if (_dirs & 63) == 0 {
            _currentPath = path
        }
        os_unfair_lock_unlock(&lock)
    }

    func addBatch(files: Int64, bytes: UInt64, skipped: Int64) {
        guard files != 0 || bytes != 0 || skipped != 0 else { return }
        os_unfair_lock_lock(&lock)
        _files += files
        _bytes += bytes
        _skippedPerm += skipped
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> (files: Int64, dirs: Int64, bytes: UInt64, skipped: Int64, path: String) {
        os_unfair_lock_lock(&lock)
        let snap = (_files, _dirs, _bytes, _skippedPerm, _currentPath)
        os_unfair_lock_unlock(&lock)
        return snap
    }
}

public final class DiskScanner: @unchecked Sendable {
    public static let notableFileThreshold: UInt64 = 10 * 1024 * 1024 // 10 MB

    private let options: ScanOptions
    private var allowedDevs: Set<Int32>
    private let isBootRoot: Bool
    public let workers: Int
    private let inodes = ShardedInodeSet()
    private let counters: ScanCounters
    private let startTime = DispatchTime.now()
    // Use .utility QoS so up to 24 parallel I/O workers saturate NVMe without starving the main UI thread.
    private let workQueue = DispatchQueue(label: "com.jefflunt.xnk-disk.scanner", qos: .utility, attributes: .concurrent)

    public init(options: ScanOptions) {
        self.options = options
        let cpuCount = ProcessInfo.processInfo.activeProcessorCount
        let computedWorkers: Int
        if options.workers > 0 {
            computedWorkers = options.workers
        } else {
            computedWorkers = min(24, max(4, cpuCount * 2))
        }
        self.workers = computedWorkers
        self.allowedDevs = Set(options.allowedDevs)
        let rootClean = cleanPath(options.rootPath)
        self.isBootRoot = (rootClean == "/")
        self.counters = ScanCounters(initialPath: rootClean)
    }

    public func cancel() {
        counters.cancel()
    }

    public func progress(active: Bool) -> ScanProgress {
        let snap = counters.snapshot()
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        return ScanProgress(
            volumeID: options.volumeID,
            active: active,
            files: snap.files,
            dirs: snap.dirs,
            bytes: snap.bytes,
            skippedPerm: snap.skipped,
            currentPath: snap.path,
            elapsedMs: Int64(elapsedNs / 1_000_000),
            workers: workers
        )
    }

    public func run() -> ScanResult? {
        let rootClean = cleanPath(options.rootPath)
        if allowedDevs.isEmpty {
            var st = stat()
            if lstat(rootClean, &st) == 0 {
                allowedDevs.insert(st.st_dev)
            }
        }

        let rootName = options.volumeName.isEmpty
            ? URL(fileURLWithPath: rootClean).lastPathComponent
            : options.volumeName

        let sem = DispatchSemaphore(value: workers)
        let root = walkDir(dirPath: rootClean, name: rootName, sem: sem)
        if counters.isCanceled {
            return nil
        }

        root.sortRecursive()
        let snap = counters.snapshot()
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds

        return ScanResult(
            volumeID: options.volumeID,
            volumeName: rootName,
            root: root,
            totalFiles: snap.files,
            totalDirs: snap.dirs,
            skippedPerm: snap.skipped,
            scannedAt: Date(),
            durationMs: Int64(elapsedNs / 1_000_000)
        )
    }

    private func shouldSkipPath(_ fullPath: String) -> Bool {
        guard isBootRoot else { return false }
        switch fullPath {
        case "/System/Volumes", "/Volumes", "/dev", "/net", "/home":
            return true
        default:
            return false
        }
    }

    private func walkDir(dirPath: String, name: String, sem: DispatchSemaphore) -> DiskNode {
        let node = DiskNode(name: name, path: dirPath, isDir: true)
        if counters.isCanceled { return node }

        counters.addDir(path: dirPath)

        guard let dir = opendir(dirPath) else {
            if errno == EACCES || errno == EPERM {
                counters.addBatch(files: 0, bytes: 0, skipped: 1)
                node.skipped = 1
            }
            return node
        }

        var subDirs: [(path: String, name: String)] = []
        var notableFiles: [DiskNode] = []
        var otherDirectBytes: UInt64 = 0
        var otherDirectApparent: UInt64 = 0
        var otherDirectCount: Int64 = 0

        var batchFiles: Int64 = 0
        var batchBytes: UInt64 = 0
        var batchSkipped: Int64 = 0

        let prefix = dirPath == "/" ? "/" : (dirPath + "/")

        while let entryPtr = readdir(dir) {
            if counters.isCanceled { break }
            let entry = entryPtr.pointee
            let dType = entry.d_type

            // Never follow symlinks early if d_type already tells us.
            if dType == DT_LNK { continue }

            let nameLen = Int(entry.d_namlen)
            if nameLen == 0 { continue }

            let eName: String = withUnsafePointer(to: entry.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: nameLen + 1) { cstr in
                    String(cString: cstr)
                }
            }
            if eName == "." || eName == ".." { continue }

            let fullPath = prefix + eName
            if shouldSkipPath(fullPath) { continue }

            var st = stat()
            if lstat(fullPath, &st) != 0 {
                if errno == EACCES || errno == EPERM {
                    batchSkipped += 1
                    node.skipped += 1
                }
                continue
            }

            let modeType = st.st_mode & S_IFMT
            if modeType == S_IFLNK { continue }

            if !allowedDevs.isEmpty && !allowedDevs.contains(st.st_dev) {
                continue
            }

            if modeType == S_IFDIR {
                subDirs.append((path: fullPath, name: eName))
                continue
            }

            if st.st_nlink > 1 {
                if !inodes.insert(dev: st.st_dev, ino: st.st_ino) {
                    continue
                }
            }

            let alloc = UInt64(max(0, st.st_blocks)) * 512
            let apparent = UInt64(max(0, st.st_size))

            batchFiles += 1
            batchBytes += alloc

            node.size += alloc
            node.apparent += apparent
            node.files += 1

            if alloc >= Self.notableFileThreshold {
                notableFiles.append(DiskNode(
                    name: eName,
                    path: fullPath,
                    size: alloc,
                    apparent: apparent,
                    files: 1,
                    isDir: false
                ))
            } else {
                otherDirectBytes += alloc
                otherDirectApparent += apparent
                otherDirectCount += 1
            }
        }
        closedir(dir)

        counters.addBatch(files: batchFiles, bytes: batchBytes, skipped: batchSkipped)

        if !subDirs.isEmpty && !counters.isCanceled {
            let count = subDirs.count
            var childResults = Array<DiskNode?>(repeating: nil, count: count)
            let group = DispatchGroup()
            var resultLock = os_unfair_lock_s()

            for i in 0..<count {
                if counters.isCanceled { break }
                let sub = subDirs[i]
                // Non-blocking worker pool dispatch: saturates all cores without recursive deadlock.
                if sem.wait(timeout: .now()) == .success {
                    group.enter()
                    workQueue.async {
                        let cn = self.walkDir(dirPath: sub.path, name: sub.name, sem: sem)
                        os_unfair_lock_lock(&resultLock)
                        childResults[i] = cn
                        os_unfair_lock_unlock(&resultLock)
                        sem.signal()
                        group.leave()
                    }
                } else {
                    let cn = walkDir(dirPath: sub.path, name: sub.name, sem: sem)
                    os_unfair_lock_lock(&resultLock)
                    childResults[i] = cn
                    os_unfair_lock_unlock(&resultLock)
                }
            }
            group.wait()

            for case let cn? in childResults {
                node.size += cn.size
                node.apparent += cn.apparent
                node.files += cn.files
                node.dirs += cn.dirs + 1
                node.skipped += cn.skipped
                if cn.size > 0 {
                    node.children.append(cn)
                }
            }
        }

        if !notableFiles.isEmpty {
            node.children.append(contentsOf: notableFiles)
        }

        if !node.children.isEmpty && otherDirectBytes > 0 && otherDirectBytes >= node.size / 50 {
            node.children.append(DiskNode(
                name: "(direct files)",
                path: prefix + "(direct files)",
                size: otherDirectBytes,
                apparent: otherDirectApparent,
                files: otherDirectCount,
                isDir: false
            ))
        }

        return node
    }
}
