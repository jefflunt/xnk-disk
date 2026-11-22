import Foundation
import Darwin

public struct VolumeInfo: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let mountPoint: String
    public let device: String
    public let fsType: String
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let availBytes: UInt64
    public let isBoot: Bool
    public let isReadOnly: Bool
    public let allowedDevs: [Int32]

    public var usedPercent: Int {
        guard totalBytes > 0 else { return 0 }
        return Int((Double(usedBytes) / Double(totalBytes) * 100.0).rounded())
    }
}

public enum VolumeDiscovery {
    private static let ignoredFSTypes: Set<String> = [
        "devfs", "autofs", "volfs", "nullfs", "lifs", "fdesc"
    ]

    public static func list() -> [VolumeInfo] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }

        var buf = Array(repeating: statfs(), count: Int(count) + 8)
        let bufSize = Int32(buf.count * MemoryLayout<statfs>.stride)
        let actual = buf.withUnsafeMutableBufferPointer { ptr in
            getfsstat(ptr.baseAddress, bufSize, MNT_NOWAIT)
        }
        guard actual > 0 else { return [] }

        let dataDev: Int32? = lstatDev("/System/Volumes/Data") ?? lstatDev("/Users")
        let bootName = detectBootVolumeName()

        var results: [VolumeInfo] = []
        for i in 0..<Int(actual) {
            let fs = buf[i]
            let fsType = tupleToString(fs.f_fstypename)
            if ignoredFSTypes.contains(fsType) { continue }

            let mount = tupleToString(fs.f_mntonname)
            let device = tupleToString(fs.f_mntfromname)

            if mount != "/" {
                if (fs.f_flags & UInt32(MNT_DONTBROWSE)) != 0 { continue }
                guard mount.hasPrefix("/Volumes/") else { continue }
                let rel = String(mount.dropFirst("/Volumes/".count))
                if rel.hasPrefix(".") || rel.contains("/") { continue }
            }

            var total = UInt64(fs.f_blocks) * UInt64(fs.f_bsize)
            if total == 0 { continue }
            var avail = UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
            var used = total >= avail ? (total - avail) : 0

            let isBoot = mount == "/"
            let name = isBoot ? bootName : URL(fileURLWithPath: mount).lastPathComponent

            var allowedDevs: [Int32] = []
            if let rootDev = lstatDev(mount) {
                allowedDevs.append(rootDev)
            }
            if isBoot, let dDev = dataDev, !allowedDevs.contains(dDev) {
                allowedDevs.append(dDev)
            }

            if isBoot {
                var dataFS = statfs()
                if statfs("/System/Volumes/Data", &dataFS) == 0 {
                    let dTotal = UInt64(dataFS.f_blocks) * UInt64(dataFS.f_bsize)
                    let dAvail = UInt64(dataFS.f_bavail) * UInt64(dataFS.f_bsize)
                    if dTotal > 0 {
                        total = dTotal
                        avail = dAvail
                        used = total >= avail ? (total - avail) : 0
                    }
                }
            }

            results.append(VolumeInfo(
                id: mount,
                name: name,
                mountPoint: mount,
                device: device,
                fsType: fsType.uppercased(),
                totalBytes: total,
                usedBytes: used,
                availBytes: avail,
                isBoot: isBoot,
                isReadOnly: (fs.f_flags & UInt32(MNT_RDONLY)) != 0,
                allowedDevs: allowedDevs
            ))
        }

        results.sort { a, b in
            if a.isBoot != b.isBoot { return a.isBoot }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return results
    }

    private static func lstatDev(_ path: String) -> Int32? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return st.st_dev
    }

    private static func detectBootVolumeName() -> String {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(atPath: "/Volumes") {
            for item in items {
                let full = "/Volumes/" + item
                if let target = try? fm.destinationOfSymbolicLink(atPath: full), target == "/" {
                    return item
                }
            }
        }
        return "Macintosh HD"
    }

    private static func tupleToString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
