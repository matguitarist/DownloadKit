import Foundation

/// How far a download is. `total` is nil when the server didn't say.
public struct DownloadProgress: Sendable, Equatable {
    public var received: Int64
    public var total: Int64?

    public init(received: Int64, total: Int64?) {
        self.received = received
        self.total = total
    }

    /// From 0 to 1, or nil when the total isn't known.
    public var fraction: Double? {
        guard let total else { return nil }
        guard total > 0 else { return 1 }
        return min(1, Double(received) / Double(total))
    }
}

/// Why a download or a lookup failed. Network failures come through as `URLError` and a stopped task as
/// `CancellationError`. An app words each case itself; `errorDescription` is a plain English fallback.
public enum DownloadError: Error, Equatable, Sendable {
    /// The server answered with a status that isn't a success (404, 500…).
    case http(status: Int, url: URL)
    /// The server said to wait (GitHub's rate limit, a 429 or 403), until `until` when it said. `status` is the
    /// status it answered with. A wait up to `RetryPolicy.maxRetryAfter` is waited out before this is thrown.
    case rateLimited(until: Date?, status: Int = 429)
    /// The file isn't the one expected. Nothing was kept.
    case checksumMismatch(expected: String, actual: String)
    /// The expected hash given isn't 64 hex digits.
    case invalidChecksum(String)
    /// A byte range was asked for and the server sent the whole file.
    case rangesNotSupported(URL)
    /// The answer wasn't HTTP, or wasn't what the API sends.
    case badResponse(URL)
}

extension DownloadError: LocalizedError {
    /// A plain English sentence, for a log or an app that doesn't word the case itself.
    public var errorDescription: String? {
        switch self {
        case .http(let status, _):
            switch status {
            case 404, 410: "The file isn't on the server (HTTP \(status))."
            case 401, 403: "The server refused the request (HTTP \(status))."
            case 500...599: "The server had a problem (HTTP \(status)). Try again later."
            default: "The server answered with an error (HTTP \(status))."
            }
        case .rateLimited(let until, let status):
            if let until, until > .now {
                "The server asks to wait until \(until.formatted(date: .omitted, time: .shortened)) (HTTP \(status))."
            } else {
                "The server asks to wait before trying again (HTTP \(status))."
            }
        case .checksumMismatch: "The download doesn't match its checksum, so it was deleted."
        case .invalidChecksum: "The expected checksum isn't a SHA-256."
        case .rangesNotSupported(let url): "\(url.host() ?? "The server") doesn't support resumable downloads."
        case .badResponse: "The server's answer couldn't be read."
        }
    }

    /// The HTTP status the server answered with, for `.http` and `.rateLimited`.
    public var status: Int? {
        switch self {
        case .http(let status, _), .rateLimited(_, let status): status
        default: nil
        }
    }
}

/// When a failed request is tried again: no connection (Wi-Fi dropped, offline, DNS or TLS failing for a moment),
/// a dropped or timed-out connection, a 408, 429 or 5xx, and a rate limit or Retry-After up to `maxRetryAfter`.
/// A download picks up where the bytes stopped. Waits double from `delay` up to `maxDelay`; a server's
/// Retry-After is waited out instead.
public struct RetryPolicy: Sendable, Equatable {
    /// Tries in all, the first one included.
    public var attempts: Int
    public var delay: Duration
    public var maxDelay: Duration
    /// The longest wait a server may ask for (Retry-After, a rate limit's reset) that is waited out before trying
    /// again. A longer one throws `DownloadError.rateLimited` at once.
    public var maxRetryAfter: Duration

    public init(attempts: Int, delay: Duration = .seconds(1), maxDelay: Duration = .seconds(30), maxRetryAfter: Duration = .seconds(60)) {
        self.attempts = max(1, attempts)
        self.delay = delay
        self.maxDelay = maxDelay
        self.maxRetryAfter = maxRetryAfter
    }

    /// 4 tries, waiting 1, 2 and 4 seconds.
    public static let standard = RetryPolicy(attempts: 4)
    /// 9 tries, waiting up to 30 seconds: big files over a weak connection.
    public static let patient = RetryPolicy(attempts: 9, delay: .seconds(2))
    /// One try.
    public static let none = RetryPolicy(attempts: 1)

    func wait(after attempt: Int) -> Duration {
        let factor = 1 << min(attempt - 1, 20)
        return min(delay * factor, maxDelay)
    }
}

/// What every request of a download or lookup carries, and how it is retried.
public struct DownloadOptions: Sendable {
    public var session: URLSession
    /// Extra request headers. Authorization is dropped when a redirect leaves the host.
    public var headers: [String: String]
    /// Names the app, never a person. Defaults to "<App>/<version> DownloadKit".
    public var userAgent: String
    /// Sends the system's own User-Agent ("<App>/<build> CFNetwork/… Darwin/…") instead of `userAgent`, for a
    /// server that turns away unknown clients or an app that sent it before. A "User-Agent" in `headers` still wins.
    public var usesSystemUserAgent: Bool
    /// `Download.file(_:into:)` names the file by URLSession's suggested name first: Content-Disposition, else
    /// the last part of the URL the download came from after redirects. Off, the original URL's last part comes
    /// before the redirected one.
    public var prefersSuggestedFilename: Bool
    public var retry: RetryPolicy
    /// Keeps the partial file when a download fails or is cancelled, so the next download of the same
    /// destination picks up from it. The SHA-256 check (when given) still guards the whole file.
    public var keepsPartialFile: Bool
    /// Seconds a request may wait for bytes before it counts as timed out; nil keeps the session's.
    public var timeout: TimeInterval?

    public init(session: URLSession = .shared, headers: [String: String] = [:], userAgent: String = DownloadOptions.defaultUserAgent,
                retry: RetryPolicy = .standard, keepsPartialFile: Bool = false, timeout: TimeInterval? = nil,
                usesSystemUserAgent: Bool = false, prefersSuggestedFilename: Bool = false) {
        self.session = session
        self.headers = headers
        self.userAgent = userAgent
        self.usesSystemUserAgent = usesSystemUserAgent
        self.prefersSuggestedFilename = prefersSuggestedFilename
        self.retry = retry
        self.keepsPartialFile = keepsPartialFile
        self.timeout = timeout
    }

    /// "<App>/<version> DownloadKit", from the main bundle's name and short version.
    public static let defaultUserAgent: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let bundleName = (info["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ProcessInfo.processInfo.processName
        let name = bundleName.filter { !$0.isWhitespace && $0 != "/" }
        let version = (info["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let product = name.isEmpty ? "App" : name
        return version.map { "\(product)/\($0) DownloadKit" } ?? "\(product) DownloadKit"
    }()

    func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let timeout { request.timeoutInterval = timeout }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if !usesSystemUserAgent, request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        return request
    }
}
