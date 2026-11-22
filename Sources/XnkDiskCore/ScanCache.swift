import Foundation
import CryptoKit

public enum ScanCacheStore {
    public static var defaultDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString)
            .appendingPathComponent("Library/Caches/com.jefflunt.xnk-disk/scans-native")
    }

    private static func fileURL(dir: String, volumeID: String) -> URL {
        let digest = SHA256.hash(data: Data(volumeID.utf8))
        let hex = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: dir).appendingPathComponent("\(hex).plist.lzfse")
    }

    public static func save(_ result: ScanResult, dir: String = defaultDir) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let raw = try encoder.encode(result)
        let compressed = try (raw as NSData).compressed(using: .lzfse) as Data

        let dst = fileURL(dir: dir, volumeID: result.volumeID)
        let tmp = dst.appendingPathExtension("tmp")
        try compressed.write(to: tmp, options: .atomic)
        _ = try? fm.replaceItemAt(dst, withItemAt: tmp)
    }

    public static func loadAll(dir: String = defaultDir) -> [String: ScanResult] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [:] }
        var out: [String: ScanResult] = [:]
        let decoder = PropertyListDecoder()
        for f in files where f.hasSuffix(".plist.lzfse") {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(f)
            guard let compressed = try? Data(contentsOf: url),
                  let raw = try? (compressed as NSData).decompressed(using: .lzfse) as Data,
                  let res = try? decoder.decode(ScanResult.self, from: raw) else {
                continue
            }
            out[res.volumeID] = res
        }
        return out
    }
}
