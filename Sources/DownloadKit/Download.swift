import CryptoKit
import Foundation

/// Downloads to files and into memory, with progress, retries, resume and a SHA-256 check.
///
/// Files stream to disk as they arrive, hashed on the way, into a hidden ".<name>.part" beside the destination;
/// the destination only appears once every byte is in and the hash matches. Nothing is held in memory but a chunk.
/// Every function here is safe to call from any thread, the main actor included: the work runs off it.
public enum Download {
    /// Downloads `url` to `destination` and returns it.
    ///
    /// - With `sha256`, a file already at `destination` with that hash is kept and nothing is downloaded, and a
    ///   download that doesn't match throws `DownloadError.checksumMismatch` and leaves `destination` as it was.
    /// - A dropped connection is tried again from the byte it stopped at (`options.retry`).
    /// - `progress` is called at most ten times a second from a background queue, and once at the end.
    @discardableResult
    public static func file(_ url: URL, to destination: URL, sha256: String? = nil, options: DownloadOptions = DownloadOptions(),
                            progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws -> URL {
        let expected = try sha256.map(expectedHash)
        let fileManager = FileManager.default
        if let expected, fileManager.fileExists(atPath: destination.path(percentEncoded: false)),
           (try? SHA256Hex.ofFile(destination)) == expected {
            let size = fileSize(destination)
            progress?(DownloadProgress(received: size, total: size))
            return destination
        }
        let folder = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let part = folder.appending(path: ".\(destination.lastPathComponent).part")
        _ = try await fetch(url, into: part, expected: expected, options: options, progress: progress)
        try moveIntoPlace(part, at: destination)
        return destination
    }

    /// Downloads `url` into `folder` under the server's file name (Content-Disposition, else the URL's last
    /// part), so an archive keeps its extension. Replaces a file of that name. Returns the file.
    @discardableResult
    public static func file(_ url: URL, into folder: URL, sha256: String? = nil, options: DownloadOptions = DownloadOptions(),
                            progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws -> URL {
        let expected = try sha256.map(expectedHash)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = SHA256Hex.of(Data(url.absoluteString.utf8)).prefix(16)
        let part = folder.appending(path: ".download-\(key).part")
        let response = try await fetch(url, into: part, expected: expected, options: options, progress: progress)
        let destination = folder.appending(path: fileName(response, url: url))
        try moveIntoPlace(part, at: destination)
        return destination
    }

    /// A new empty folder in the temporary folder ("<prefix>-<UUID>"), for a download the app unpacks then deletes.
    public static func temporaryFolder(prefix: String = "download") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Downloads `length` bytes of `url` from `offset` and appends them to `file` (made when missing). Bytes
    /// already in `file` count: a stopped download picks up after them, and a complete one asks for nothing.
    /// The server must send ranges (206); one that sends the whole file throws `DownloadError.rangesNotSupported`.
    /// `progress` gets the range's bytes on disk. Nothing is hashed: check what the bytes make, after.
    public static func range(_ url: URL, offset: Int64, length: Int64, appendingTo file: URL, options: DownloadOptions = DownloadOptions(),
                             progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws {
        let reporter = progress.map(Reporter.init)
        let sink = try Sink(file: file, hashing: false)
        defer { sink.close() }
        reporter?.report(sink.written, length, force: true)
        guard sink.written < length else { return }
        try await Retrying.run(options.retry) {
            guard sink.written < length else { return }
            var request = options.request(url)
            let start = offset + sink.written
            request.setValue("bytes=\(start)-\(offset + length - 1)", forHTTPHeaderField: "Range")
            try await Transfer(sink: sink, mode: .range(start: start, length: length), reporter: reporter).run(request, session: options.session)
        }
    }

    /// The body of `url`, for small things: an API answer, a checksums file. Retried like a download.
    public static func data(from url: URL, options: DownloadOptions = DownloadOptions()) async throws -> Data {
        try await data(for: options.request(url), options: options)
    }

    static func data(for request: URLRequest, options: DownloadOptions) async throws -> Data {
        let url = request.url ?? URL(filePath: "/")
        return try await Retrying.run(options.retry) {
            let (data, response) = try await options.session.data(for: request, delegate: RedirectGuard())
            _ = try HTTPStatus.check(response, url: url)
            return data
        }
    }

    /// What identifies the file now at `url`, from a HEAD request: its ETag and Last-Modified, joined by a
    /// space. Tells a new build behind a fixed link. Nil when the server says neither or can't be reached.
    public static func stamp(of url: URL, options: DownloadOptions = DownloadOptions()) async -> String? {
        var request = options.request(url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await options.session.data(for: request, delegate: RedirectGuard()),
              let http = try? HTTPStatus.check(response, url: url) else { return nil }
        let parts = [http.value(forHTTPHeaderField: "ETag"), http.value(forHTTPHeaderField: "Last-Modified")].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Inside

    /// Streams `url` into `part` with retries and resume, then checks the hash. Returns the last response.
    static func fetch(_ url: URL, into part: URL, expected: String?, options: DownloadOptions,
                      progress: (@Sendable (DownloadProgress) -> Void)?) async throws -> HTTPURLResponse {
        let fileManager = FileManager.default
        if !options.keepsPartialFile { try? fileManager.removeItem(at: part) }
        let reporter = progress.map(Reporter.init)
        let sink = try Sink(file: part, hashing: true)
        var validator: String?
        let response: HTTPURLResponse
        do {
            response = try await Retrying.run(options.retry) {
                do {
                    return try await attempt(url, sink: sink, validator: &validator, options: options, reporter: reporter)
                } catch is Transfer.Restart {
                    try sink.reset()
                    return try await attempt(url, sink: sink, validator: &validator, options: options, reporter: reporter)
                }
            }
        } catch {
            sink.close()
            if !options.keepsPartialFile { try? fileManager.removeItem(at: part) }
            throw error
        }
        let actual = sink.digest() ?? ""
        sink.close()
        if let expected, actual != expected {
            try? fileManager.removeItem(at: part)
            throw DownloadError.checksumMismatch(expected: expected, actual: actual)
        }
        return response
    }

    private static func attempt(_ url: URL, sink: Sink, validator: inout String?, options: DownloadOptions,
                                reporter: Reporter?) async throws -> HTTPURLResponse {
        var request = options.request(url)
        let resumingAt: Int64? = sink.written > 0 ? sink.written : nil
        if let resumingAt {
            request.setValue("bytes=\(resumingAt)-", forHTTPHeaderField: "Range")
            // Only the same file continues; a changed one comes back whole.
            if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        }
        let transfer = Transfer(sink: sink, mode: .whole(resumingAt: resumingAt), reporter: reporter)
        do {
            try await transfer.run(request, session: options.session)
        } catch {
            if validator == nil, let response = transfer.response { validator = strongValidator(response) }
            throw error
        }
        guard let response = transfer.response else { throw DownloadError.badResponse(url) }
        return response
    }

    /// A strong ETag, else Last-Modified: what If-Range accepts.
    static func strongValidator(_ response: HTTPURLResponse) -> String? {
        if let etag = response.value(forHTTPHeaderField: "ETag"), !etag.hasPrefix("W/") { return etag }
        return response.value(forHTTPHeaderField: "Last-Modified")
    }

    static func expectedHash(_ text: String) throws -> String {
        guard let hash = SHA256Hex.normalized(text) else { throw DownloadError.invalidChecksum(text) }
        return hash
    }

    static func fileName(_ response: HTTPURLResponse, url: URL) -> String {
        let candidates = [contentDispositionName(response), url.lastPathComponent.removingPercentEncoding, response.suggestedFilename]
        for case let name? in candidates {
            let clean = (name as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, clean != "/", clean != ".", clean != ".." { return clean }
        }
        return "download"
    }

    private static func contentDispositionName(_ response: HTTPURLResponse) -> String? {
        guard response.value(forHTTPHeaderField: "Content-Disposition") != nil else { return nil }
        return response.suggestedFilename
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func moveIntoPlace(_ part: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: part)
        } else {
            try fileManager.moveItem(at: part, to: destination)
        }
    }
}
