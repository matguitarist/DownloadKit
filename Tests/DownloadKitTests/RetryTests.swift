import Foundation
import Testing
@testable import DownloadKit

// MARK: The network going away

@Test(arguments: [URLError.Code.notConnectedToInternet, .cannotFindHost, .secureConnectionFailed, .networkConnectionLost, .timedOut])
func aNetworkThatComesBackIsTriedAgain(_ code: URLError.Code) async throws {
    let (id, options) = Stub.server { _, index in index == 0 ? Stub.Reply(fails: code) : Stub.Reply(body: Data("ok".utf8)) }
    #expect(try await Download.data(from: Samples.url, options: options) == Data("ok".utf8))
    #expect(Stub.requests(id).count == 2)
}

@Test func aWiFiDropDuringARangeResumesOnceTheNetworkIsBack() async throws {
    // Hearthside's case: bytes arrive, the Wi-Fi drops, the next tries find no network or no DNS, then it's back.
    let body = Samples.bytes(60_000)
    let serve = Stub.serving(body)
    let (id, options) = Stub.server(retry: RetryPolicy(attempts: 5, delay: .zero)) { request, index in
        switch index {
        case 0: var reply = serve(request, index); reply.dropAfter = 8192; return reply
        case 1: return Stub.Reply(fails: .notConnectedToInternet)
        case 2: return Stub.Reply(fails: .cannotFindHost)
        default: return serve(request, index)
        }
    }
    let file = Samples.folder().appending(path: "patch.packed")
    try await Download.range(Samples.url, offset: 0, length: 60_000, appendingTo: file, options: options)
    #expect(try Data(contentsOf: file) == body)
    #expect(Stub.requests(id).last?.value(forHTTPHeaderField: "Range") == "bytes=8192-59999")
}

@Test func aWiFiDropDuringAFileResumesFromItsBytes() async throws {
    let body = Samples.bytes(50_000)
    let serve = Stub.serving(body, dropFirstAfter: 12_288)
    let (id, options) = Stub.server { request, index in index == 1 ? Stub.Reply(fails: .notConnectedToInternet) : serve(request, index) }
    let file = try await Download.file(Samples.url, to: Samples.folder().appending(path: "x.zip"), sha256: SHA256Hex.of(body), options: options)
    #expect(try Data(contentsOf: file) == body)
    #expect(Stub.requests(id).last?.value(forHTTPHeaderField: "Range") == "bytes=12288-")
}

@Test func failuresARetryWontFixAreNotRetried() async throws {
    for code in [URLError.Code.badURL, .unsupportedURL, .userAuthenticationRequired, .serverCertificateUntrusted, .cannotDecodeContentData] {
        #expect(!Retrying.isRetryable(URLError(code)), "\(code)")
    }
    let (id, options) = Stub.server { _, _ in Stub.Reply(fails: .badURL) }
    await #expect(throws: URLError.self) { try await Download.data(from: Samples.url, options: options) }
    #expect(Stub.requests(id).count == 1)
}

@Test func noRetriesMeansOfflineIsToldAtOnce() async throws {
    let (id, options) = Stub.server(retry: .none) { _, _ in Stub.Reply(fails: .notConnectedToInternet) }
    let error = await #expect(throws: URLError.self) { try await Download.data(from: Samples.url, options: options) }
    #expect(error?.code == .notConnectedToInternet)
    #expect(Stub.requests(id).count == 1)
}

// MARK: Retry-After

@Test func aShortRetryAfterIsWaitedOut() async throws {
    let (id, options) = Stub.server { _, index in
        index == 0 ? Stub.Reply(status: 429, headers: ["Retry-After": "1"]) : Stub.Reply(body: Data("ok".utf8))
    }
    let start = ContinuousClock.now
    #expect(try await Download.data(from: Samples.url, options: options) == Data("ok".utf8))
    #expect(ContinuousClock.now - start >= .milliseconds(900))
    #expect(Stub.requests(id).count == 2)
}

@Test func aLongWaitIsThrownAtOnceWithItsStatusAndTime() async throws {
    let (id, options) = Stub.server { _, _ in Stub.Reply(status: 429, headers: ["Retry-After": "3600"]) }
    do {
        _ = try await Download.data(from: Samples.url, options: options)
        Issue.record("no error")
    } catch let error as DownloadError {
        guard case .rateLimited(let until?, let status) = error else { Issue.record("\(error)"); return }
        #expect(status == 429 && error.status == 429)
        #expect(abs(until.timeIntervalSinceNow - 3600) < 30)
    }
    #expect(Stub.requests(id).count == 1)
}

@Test func theLongestWaitIsTheAppsChoice() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let limited = DownloadError.rateLimited(until: now.addingTimeInterval(90), status: 403)
    #expect(Retrying.wait(before: 2, after: limited, policy: .standard, now: now) == nil)
    let patient = RetryPolicy(attempts: 4, maxRetryAfter: .seconds(120))
    #expect(Retrying.wait(before: 2, after: limited, policy: patient, now: now) == .seconds(90))
    #expect(Retrying.wait(before: 2, after: DownloadError.rateLimited(until: nil), policy: patient, now: now) == nil)
    #expect(Retrying.wait(before: 2, after: DownloadError.rateLimited(until: now.addingTimeInterval(-5)), policy: patient, now: now) == .zero)
    #expect(Retrying.wait(before: 3, after: URLError(.notConnectedToInternet), policy: .standard, now: now) == .seconds(2))
}

@Test func retryAfterReadsSecondsAndDates() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(HTTPStatus.retryAfter("30", now: now) == now.addingTimeInterval(30))
    #expect(HTTPStatus.retryAfter("Wed, 21 Oct 2026 07:28:00 GMT") == Date(timeIntervalSince1970: 1_792_567_680))
    #expect(HTTPStatus.retryAfter("soon") == nil)
}

// MARK: Words

@Test func everyErrorHasASentence() {
    let url = Samples.url
    let errors: [DownloadError] = [.http(status: 404, url: url), .http(status: 403, url: url), .http(status: 502, url: url),
                                   .http(status: 418, url: url), .rateLimited(until: nil), .rateLimited(until: .now + 600, status: 403),
                                   .checksumMismatch(expected: "a", actual: "b"), .invalidChecksum("x"), .rangesNotSupported(url),
                                   .badResponse(url)]
    for error in errors {
        let text = (error as Error).localizedDescription
        #expect(!text.isEmpty && !text.contains("DownloadKit.DownloadError"), "\(error)")
    }
    #expect(DownloadError.http(status: 404, url: url).localizedDescription.contains("404"))
    #expect(DownloadError.rangesNotSupported(url).localizedDescription.hasPrefix("downloads.example.com"))
    #expect(DownloadError.http(status: 500, url: url).status == 500)
    #expect(DownloadError.badResponse(url).status == nil)
}

// MARK: User-Agent and file names

@Test func theSystemUserAgentCanBeKept() async throws {
    var (id, options) = Stub.server(Stub.serving(Data("ok".utf8)))
    options.usesSystemUserAgent = true
    _ = try await Download.data(from: Samples.url, options: options)
    #expect(Stub.requests(id).first?.value(forHTTPHeaderField: "User-Agent") != DownloadOptions.defaultUserAgent)
    options.headers["User-Agent"] = "Attic/2.0"
    _ = try await Download.data(from: Samples.url, options: options)
    #expect(Stub.requests(id).last?.value(forHTTPHeaderField: "User-Agent") == "Attic/2.0")
}

@Test func theSuggestedNameCanComeFirst() async throws {
    let body = Samples.bytes(2000)
    let cdn = URL(string: "https://files.example.net/real/SomeMod-1.2.zip")!
    let handler: Stub.Handler = { request, _ in
        request.url?.host == "cdn.example.com" ? Stub.Reply(redirect: cdn) : Stub.Reply(body: body)
    }
    let link = URL(string: "https://cdn.example.com/download/12345")!
    let folder = Samples.folder()

    let (_, plain) = Stub.server(handler)
    #expect(try await Download.file(link, into: folder, options: plain).lastPathComponent == "12345")

    var (_, suggested) = Stub.server(handler)
    suggested.prefersSuggestedFilename = true
    let file = try await Download.file(link, into: folder, options: suggested)
    #expect(file.lastPathComponent == "SomeMod-1.2.zip")
    #expect(try Data(contentsOf: file) == body)

    let (_, named) = Stub.server { _, _ in Stub.Reply(headers: ["Content-Disposition": "attachment; filename=\"Mod.7z\""], body: body) }
    var options = named
    options.prefersSuggestedFilename = true
    #expect(try await Download.file(link, into: folder, options: options).lastPathComponent == "Mod.7z")
}
