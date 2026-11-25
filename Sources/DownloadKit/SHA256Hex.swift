import CryptoKit
import Foundation

/// SHA-256 as lowercase hex: of bytes, of a file read in chunks, and found in a checksums file.
public enum SHA256Hex {
    static let chunk = 1 << 20

    /// The hash of `data`.
    public static func of(_ data: Data) -> String {
        string(SHA256.hash(data: data))
    }

    /// A digest as 64 lowercase hex characters.
    public static func string(_ digest: SHA256.Digest) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The hash of a file, read 1 MB at a time so a big file never sits in memory. `progress` gets the
    /// bytes read so far. Stops with `CancellationError` when the task is cancelled. Call it off the main thread.
    public static func ofFile(_ url: URL, progress: ((Int64) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        try update(&hasher, reading: handle, progress: progress)
        return string(hasher.finalize())
    }

    /// Feeds the rest of `handle` to `hasher`.
    static func update(_ hasher: inout SHA256, reading handle: FileHandle, progress: ((Int64) -> Void)? = nil) throws {
        var read: Int64 = 0
        while let data = try handle.read(upToCount: chunk), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
            read += Int64(data.count)
            progress?(read)
        }
    }

    /// A hash as this package writes it, or nil when `text` isn't one. Takes "ABC…", " abc… ", and GitHub's
    /// "sha256:abc…".
    public static func normalized(_ text: String) -> String? {
        var hash = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if hash.hasPrefix("sha256:") { hash.removeFirst(7) }
        guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return hash
    }

    /// Whether two hashes are the same, whatever their case or prefix.
    public static func matches(_ a: String, _ b: String) -> Bool {
        guard let a = normalized(a) else { return false }
        return a == normalized(b)
    }

    /// The SHA-256 for `fileName` in a checksums file. Reads "<hash>  <name>" and "<hash> *<name>" (sha256sum),
    /// "SHA256 (<name>) = <hash>" (BSD), files that mix MD5, SHA-1 and SHA-256 lines (only 64-digit hashes count),
    /// names with a folder in front ("dist/<name>"), and a file that holds only one bare hash (a "<name>.sha256" file).
    public static func find(for fileName: String, in checksums: String) -> String? {
        func names(_ candidate: String) -> Bool {
            var name = candidate.trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            return name == fileName || (name as NSString).lastPathComponent == fileName
        }
        let lines = checksums.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        for line in lines {
            if let bsd = line.wholeMatch(of: /SHA256 ?\((.+)\) ?= ?([0-9A-Fa-f]{64})/) {
                if names(String(bsd.1)) { return normalized(String(bsd.2)) }
                continue
            }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, let hash = normalized(String(parts[0])) else { continue }
            let rest = line.dropFirst(parts[0].count)
            if names(String(rest)) || names(String(parts[parts.count - 1])) { return hash }
        }
        if lines.count == 1, !lines[0].contains(where: \.isWhitespace) { return normalized(lines[0]) }
        return nil
    }
}
