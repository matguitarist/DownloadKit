import CryptoKit
import Foundation
import os

/// The file a download writes to: appended to, and hashed as the bytes arrive.
final class Sink: @unchecked Sendable {
    // Used by one transfer at a time: on the session's serial delegate queue while it runs, by the caller between runs.
    private let handle: FileHandle
    private(set) var hasher: SHA256?
    private(set) var written: Int64

    /// Opens `file` (made when missing) at its end. With `hashing`, the bytes already there are hashed first.
    init(file: URL, hashing: Bool) throws {
        if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            guard FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: file])
            }
        }
        handle = try FileHandle(forUpdating: file)
        if hashing {
            var hasher = SHA256()
            try SHA256Hex.update(&hasher, reading: handle)
            self.hasher = hasher
        }
        written = Int64(try handle.seekToEnd())
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        hasher?.update(data: data)
        written += Int64(data.count)
    }

    /// Empties the file to start over.
    func reset() throws {
        try handle.truncate(atOffset: 0)
        written = 0
        if hasher != nil { hasher = SHA256() }
    }

    func digest() -> String? { hasher.map { SHA256Hex.string($0.finalize()) } }

    func close() { try? handle.close() }
}

/// Sends progress at most ten times a second, and always the first bytes and when told to.
final class Reporter: @unchecked Sendable {
    // Called from one place at a time, like Sink.
    private let send: @Sendable (DownloadProgress) -> Void
    private var last: ContinuousClock.Instant?
    private var lastReceived: Int64 = 0

    init(_ send: @escaping @Sendable (DownloadProgress) -> Void) { self.send = send }

    func report(_ received: Int64, _ total: Int64?, force: Bool = false) {
        let now = ContinuousClock.now
        let firstBytes = lastReceived == 0 && received > 0
        if !force, !firstBytes, let last, now - last < .milliseconds(100) { return }
        last = now
        lastReceived = received
        send(DownloadProgress(received: received, total: total))
    }
}

/// Keeps the headers a ranged request needs across a redirect (archive.org sends to a storage node), and
/// drops Authorization when the redirect leaves the host.
enum Redirects {
    static func carry(from original: URLRequest?, to new: URLRequest) -> URLRequest {
        var request = new
        for name in ["Range", "If-Range"] {
            if let value = original?.value(forHTTPHeaderField: name) { request.setValue(value, forHTTPHeaderField: name) }
        }
        if original?.url?.host?.lowercased() != new.url?.host?.lowercased() {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Redirects.carry(from: task.originalRequest, to: request))
    }
}

/// Cancels a task started after, or before, the Swift task asking for it was cancelled.
final class TaskHandle: Sendable {
    private struct State: @unchecked Sendable {
        var task: URLSessionTask?
        var cancelled = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func start(_ task: URLSessionTask) {
        let cancelled = state.withLock { state in
            state.task = task
            return state.cancelled
        }
        task.resume()
        if cancelled { task.cancel() }
    }

    func cancel() {
        let task = state.withLock { state in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }
}

/// One request streamed into a Sink, on a data task with this object as its delegate.
final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// The server can't continue from where the file stopped; empty it and ask for everything.
    struct Restart: Error {}

    enum Mode {
        /// The whole file; `resumingAt` is the byte asked for with Range, when continuing.
        case whole(resumingAt: Int64?)
        /// A byte range of `length` bytes starting at `start` (the first byte asked for this time).
        case range(start: Int64, length: Int64)
    }

    // Set before the task starts, then only touched on the session's serial delegate queue.
    private let sink: Sink
    private let mode: Mode
    private let reporter: Reporter?
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private(set) var response: HTTPURLResponse?
    private(set) var total: Int64?

    init(sink: Sink, mode: Mode, reporter: Reporter?) {
        self.sink = sink
        self.mode = mode
        self.reporter = reporter
    }

    func run(_ request: URLRequest, session: URLSession) async throws {
        let handle = TaskHandle()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.continuation = continuation
                    let task = session.dataTask(with: request)
                    task.delegate = self
                    handle.start(task)
                }
            } onCancel: {
                handle.cancel()
            }
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let url = dataTask.originalRequest?.url ?? response.url ?? URL(filePath: "/")
        do {
            guard let http = response as? HTTPURLResponse else { throw DownloadError.badResponse(url) }
            self.response = http
            let length: Int64? = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
            switch mode {
            case .whole(let resumingAt?) where http.statusCode == 206:
                guard let range = ContentRange(http), range.first == resumingAt, resumingAt == sink.written else { throw Restart() }
                total = range.total ?? length.map { sink.written + $0 }
            case .whole(.some) where http.statusCode == 416:
                throw Restart()
            case .whole where (200..<300).contains(http.statusCode) && http.statusCode != 206:
                if sink.written > 0 { try sink.reset() }
                total = length
            case .whole:
                throw HTTPStatus.error(http, url: url)
            case .range(let start, let length):
                guard http.statusCode == 206 else {
                    throw (200..<300).contains(http.statusCode) ? DownloadError.rangesNotSupported(url) : HTTPStatus.error(http, url: url)
                }
                if let range = ContentRange(http), range.first != start { throw DownloadError.badResponse(url) }
                total = length
            }
            reporter?.report(sink.written, total, force: true)
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            try sink.write(data)
            reporter?.report(sink.written, total)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Redirects.carry(from: task.originalRequest, to: request))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = self.continuation
        self.continuation = nil
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            continuation?.resume(throwing: error)
        } else if let total, sink.written < total {
            // The connection closed early without saying so: try again from here.
            continuation?.resume(throwing: URLError(.networkConnectionLost))
        } else {
            reporter?.report(sink.written, total ?? sink.written, force: true)
            continuation?.resume()
        }
    }
}

/// "Content-Range: bytes 100-199/1000".
struct ContentRange {
    let first: Int64
    let total: Int64?

    init?(_ response: HTTPURLResponse) {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              let match = value.wholeMatch(of: /\s*bytes\s+(\d+)-(\d+)\/(\d+|\*)\s*/),
              let first = Int64(match.1) else { return nil }
        self.first = first
        total = Int64(match.3)
    }
}

enum HTTPStatus {
    /// The error for a status that isn't a success: a rate limit when the server says so, else `.http`.
    static func error(_ response: HTTPURLResponse, url: URL) -> DownloadError {
        let status = response.statusCode
        if status == 403 || status == 429 {
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
                return .rateLimited(until: reset.map { Date(timeIntervalSince1970: $0) }, status: status)
            }
            if let until = response.value(forHTTPHeaderField: "Retry-After").flatMap({ retryAfter($0) }) {
                return .rateLimited(until: until, status: status)
            }
        }
        return .http(status: status, url: url)
    }

    /// Retry-After as seconds ("120") or as an HTTP date ("Wed, 21 Oct 2026 07:28:00 GMT").
    static func retryAfter(_ value: String, now: Date = .now) -> Date? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(text) { return now.addingTimeInterval(max(0, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    static func check(_ response: URLResponse, url: URL) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw DownloadError.badResponse(url) }
        guard (200..<300).contains(http.statusCode) else { throw error(http, url: url) }
        return http
    }
}

enum Retrying {
    /// Failures a moment later can fix: the network going away (a Wi-Fi drop says notConnectedToInternet, then
    /// cannotFindHost or secureConnectionFailed while it comes back), a dropped or slow connection, a busy server.
    static let transientCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        .secureConnectionFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive, .badServerResponse, .resourceUnavailable,
    ]

    static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case let error as URLError:
            transientCodes.contains(error.code)
        case DownloadError.http(let status, _):
            status == 408 || status == 429 || (500...599).contains(status)
        default:
            false
        }
    }

    /// How long to wait before the next try, or nil when `error` isn't worth another. A rate limit is waited out
    /// when it ends within `maxRetryAfter`.
    static func wait(before next: Int, after error: Error, policy: RetryPolicy, now: Date = .now) -> Duration? {
        if case DownloadError.rateLimited(let until, _) = error {
            guard let until else { return nil }
            let seconds = max(0, until.timeIntervalSince(now))
            let wait = Duration.milliseconds(Int64((seconds * 1000).rounded(.up)))
            return wait <= policy.maxRetryAfter ? wait : nil
        }
        return isRetryable(error) ? policy.wait(after: next - 1) : nil
    }

    /// Runs `body` until it works, fails in a way a retry won't fix, or runs out of tries.
    static func run<T>(_ policy: RetryPolicy, _ body: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await body()
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                guard attempt < policy.attempts, let wait = wait(before: attempt + 1, after: error, policy: policy) else { throw error }
                try await Task.sleep(for: wait)
                attempt += 1
            }
        }
    }
}
