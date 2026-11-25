import Foundation
import os
@testable import DownloadKit

/// A pretend server for tests: a URLProtocol that answers from a handler, keyed by the "X-Stub" header each test
/// sends, so tests running side by side never see each other's requests. No network.
final class Stub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// Sends this many bytes, then drops the connection.
        var dropAfter: Int?
        /// Sends the first chunk, then waits until the request is cancelled.
        var hangs = false
        /// Answers 302 to this URL.
        var redirect: URL?
        /// Leaves out Content-Length.
        var noLength = false
        /// Fails like the network would, before any answer.
        var fails: URLError.Code?
    }

    typealias Handler = @Sendable (_ request: URLRequest, _ index: Int) -> Reply

    private struct Server {
        var handler: Handler
        var requests: [URLRequest] = []
    }

    private static let servers = OSAllocatedUnfairLock<[String: Server]>(uncheckedState: [:])

    /// A server, and options that reach it with no waits between retries.
    static func server(retry: RetryPolicy = RetryPolicy(attempts: 3, delay: .zero), _ handler: @escaping Handler) -> (id: String, options: DownloadOptions) {
        let id = UUID().uuidString
        servers.withLockUnchecked { $0[id] = Server(handler: handler) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        let session = URLSession(configuration: configuration)
        return (id, DownloadOptions(session: session, headers: ["X-Stub": id], retry: retry))
    }

    static func requests(_ id: String) -> [URLRequest] {
        servers.withLockUnchecked { $0[id]?.requests ?? [] }
    }

    /// A server that sends `body`, honoring Range ("bytes=N-" and "bytes=N-M") with a 206.
    static func serving(_ body: Data, etag: String? = "\"v1\"", dropFirstAfter: Int? = nil, ranges: Bool = true) -> Handler {
        { request, index in
            var headers: [String: String] = [:]
            if let etag { headers["ETag"] = etag }
            if ranges, let range = request.value(forHTTPHeaderField: "Range"),
               let match = range.wholeMatch(of: /bytes=(\d+)-(\d*)/), let first = Int(match.1) {
                let last = Int(match.2) ?? body.count - 1
                guard first < body.count else { return Reply(status: 416, headers: headers) }
                headers["Content-Range"] = "bytes \(first)-\(last)/\(body.count)"
                return Reply(status: 206, headers: headers, body: body.subdata(in: first..<(last + 1)))
            }
            return Reply(status: 200, headers: headers, body: body, dropAfter: index == 0 ? dropFirstAfter : nil)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Stub") ?? ""
        let index = Self.servers.withLockUnchecked { servers -> Int? in
            guard servers[id] != nil else { return nil }
            servers[id]!.requests.append(request)
            return servers[id]!.requests.count - 1
        }
        guard let index, let handler = Self.servers.withLockUnchecked({ $0[id]?.handler }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let reply = handler(request, index)
        if let code = reply.fails {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        if let target = reply.redirect {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            var next = URLRequest(url: target)
            next.setValue(id, forHTTPHeaderField: "X-Stub")
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            return
        }
        var headers = reply.headers
        if !reply.noLength { headers["Content-Length"] = String(reply.body.count) }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let limit = min(reply.dropAfter ?? reply.body.count, reply.body.count)
        var sent = 0
        while sent < limit {
            let end = min(sent + 4096, limit)
            client?.urlProtocol(self, didLoad: reply.body.subdata(in: sent..<end))
            sent = end
            if reply.hangs { return }
        }
        if reply.dropAfter != nil {
            // Like a real connection, the bytes reach the delegate before the drop does.
            Thread.sleep(forTimeInterval: 0.05)
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

enum Samples {
    /// A new folder under the temporary folder.
    static func folder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "DownloadKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Bytes that aren't all the same, so a misplaced chunk shows.
    static func bytes(_ count: Int) -> Data {
        var state: UInt32 = 2_463_534_242
        return Data((0..<count).map { _ in
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            return UInt8(truncatingIfNeeded: state)
        })
    }

    static let url = URL(string: "https://downloads.example.com/files/game-1.0.zip")!

    /// Collects progress reports from any thread.
    final class Reports: Sendable {
        private let list = OSAllocatedUnfairLock<[DownloadProgress]>(initialState: [])
        func add(_ progress: DownloadProgress) { list.withLock { $0.append(progress) } }
        var all: [DownloadProgress] { list.withLock { $0 } }
    }
}
