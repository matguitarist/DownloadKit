import Foundation
import Testing
@testable import DownloadKit

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
private func parts(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).filter { $0.hasSuffix(".part") }
}

@Test func downloadsAFileWithProgressAndLeavesNoPartFile() async throws {
    let body = Samples.bytes(300_000)
    let (_, options) = Stub.server(Stub.serving(body))
    let destination = Samples.folder().appending(path: "new/folder/game.zip")
    let reports = Samples.Reports()
    let file = try await Download.file(Samples.url, to: destination, sha256: SHA256Hex.of(body), options: options) { reports.add($0) }
    #expect(file == destination)
    #expect(try Data(contentsOf: file) == body)
    #expect(parts(in: destination.deletingLastPathComponent()).isEmpty)
    let all = reports.all
    #expect(all.last == DownloadProgress(received: 300_000, total: 300_000))
    #expect(all.last?.fraction == 1)
    #expect(zip(all, all.dropFirst()).allSatisfy { $0.received <= $1.received })
}

@Test func takesTheHashInAnyCaseOrWithGitHubsPrefix() async throws {
    let body = Samples.bytes(5000)
    let (_, options) = Stub.server(Stub.serving(body))
    let folder = Samples.folder()
    try await Download.file(Samples.url, to: folder.appending(path: "a"), sha256: SHA256Hex.of(body).uppercased(), options: options)
    try await Download.file(Samples.url, to: folder.appending(path: "b"), sha256: "sha256:" + SHA256Hex.of(body), options: options)
    await #expect(throws: DownloadError.invalidChecksum("abc")) {
        try await Download.file(Samples.url, to: folder.appending(path: "c"), sha256: "abc", options: options)
    }
    #expect(!exists(folder.appending(path: "c")))
}

@Test func aMismatchKeepsNothingAndLeavesTheOldFileAlone() async throws {
    let (_, options) = Stub.server(Stub.serving(Samples.bytes(10_000)))
    let folder = Samples.folder()
    let destination = folder.appending(path: "runtime.tar.bz2")
    try Data("older".utf8).write(to: destination)
    let wrong = String(repeating: "0", count: 64)
    await #expect(throws: DownloadError.checksumMismatch(expected: wrong, actual: SHA256Hex.of(Samples.bytes(10_000)))) {
        try await Download.file(Samples.url, to: destination, sha256: wrong, options: options)
    }
    #expect(try Data(contentsOf: destination) == Data("older".utf8))
    #expect(parts(in: folder).isEmpty)
}

@Test func aFileAlreadyThereWithTheRightHashIsNotDownloadedAgain() async throws {
    let body = Samples.bytes(2000)
    let (id, options) = Stub.server(Stub.serving(body))
    let destination = Samples.folder().appending(path: "game.zip")
    try body.write(to: destination)
    let reports = Samples.Reports()
    try await Download.file(Samples.url, to: destination, sha256: SHA256Hex.of(body), options: options) { reports.add($0) }
    #expect(Stub.requests(id).isEmpty)
    #expect(reports.all == [DownloadProgress(received: 2000, total: 2000)])
}

@Test func withoutAHashAFileAlreadyThereIsReplaced() async throws {
    let body = Samples.bytes(2000)
    let (id, options) = Stub.server(Stub.serving(body))
    let destination = Samples.folder().appending(path: "game.zip")
    try Data("stale".utf8).write(to: destination)
    try await Download.file(Samples.url, to: destination, options: options)
    #expect(Stub.requests(id).count == 1)
    #expect(try Data(contentsOf: destination) == body)
}

@Test func aMissingFileFailsAtOnce() async throws {
    let (id, options) = Stub.server { _, _ in Stub.Reply(status: 404) }
    let folder = Samples.folder()
    await #expect(throws: DownloadError.http(status: 404, url: Samples.url)) {
        try await Download.file(Samples.url, to: folder.appending(path: "x.zip"), options: options)
    }
    #expect(Stub.requests(id).count == 1)
    #expect(parts(in: folder).isEmpty)
}

@Test func aServerErrorIsTriedAgain() async throws {
    let body = Samples.bytes(1000)
    let serve = Stub.serving(body)
    let (id, options) = Stub.server { request, index in index == 0 ? Stub.Reply(status: 503) : serve(request, index) }
    let file = try await Download.file(Samples.url, to: Samples.folder().appending(path: "x"), options: options)
    #expect(try Data(contentsOf: file) == body)
    #expect(Stub.requests(id).count == 2)
}

@Test func retriesStopAtTheirLimit() async throws {
    let (id, options) = Stub.server(retry: RetryPolicy(attempts: 2, delay: .zero)) { _, _ in Stub.Reply(status: 500) }
    await #expect(throws: DownloadError.http(status: 500, url: Samples.url)) {
        try await Download.file(Samples.url, to: Samples.folder().appending(path: "x"), options: options)
    }
    #expect(Stub.requests(id).count == 2)
}

@Test func aDroppedConnectionResumesWhereItStopped() async throws {
    let body = Samples.bytes(100_000)
    let (id, options) = Stub.server(Stub.serving(body, dropFirstAfter: 40_960))
    let file = try await Download.file(Samples.url, to: Samples.folder().appending(path: "big.zip"), sha256: SHA256Hex.of(body), options: options)
    #expect(try Data(contentsOf: file) == body)
    let requests = Stub.requests(id)
    #expect(requests.count == 2)
    #expect(requests[1].value(forHTTPHeaderField: "Range") == "bytes=40960-")
    #expect(requests[1].value(forHTTPHeaderField: "If-Range") == "\"v1\"")
}

@Test func aServerWithoutRangesStartsOver() async throws {
    let body = Samples.bytes(50_000)
    let (id, options) = Stub.server(Stub.serving(body, dropFirstAfter: 8192, ranges: false))
    let file = try await Download.file(Samples.url, to: Samples.folder().appending(path: "x"), sha256: SHA256Hex.of(body), options: options)
    #expect(try Data(contentsOf: file) == body)
    #expect(Stub.requests(id).count == 2)
}

@Test func aRangeFromTheWrongByteStartsOver() async throws {
    let body = Samples.bytes(30_000)
    let serve = Stub.serving(body, dropFirstAfter: 8192)
    let (id, options) = Stub.server { request, index in
        guard index == 1 else { return serve(request, index) }
        // Answers a resume with the wrong bytes: the download must start again from zero.
        return Stub.Reply(status: 206, headers: ["Content-Range": "bytes 0-29999/30000"], body: body)
    }
    let file = try await Download.file(Samples.url, to: Samples.folder().appending(path: "x"), sha256: SHA256Hex.of(body), options: options)
    #expect(try Data(contentsOf: file) == body)
    let requests = Stub.requests(id)
    #expect(requests.count == 3)
    #expect(requests[2].value(forHTTPHeaderField: "Range") == nil)
}

@Test func aConnectionClosedEarlyCountsAsDropped() async throws {
    let body = Samples.bytes(20_000)
    let serve = Stub.serving(body)
    let (id, options) = Stub.server { request, index in
        guard index == 0 else { return serve(request, index) }
        // Says 20 000 bytes, sends 5000, then ends as if all was well.
        return Stub.Reply(status: 200, headers: ["Content-Length": "20000", "ETag": "\"v1\""], body: body.prefix(5000), noLength: true)
    }
    let file = try await Download.file(Samples.url, to: Samples.folder().appending(path: "x"), sha256: SHA256Hex.of(body), options: options)
    #expect(try Data(contentsOf: file) == body)
    #expect(Stub.requests(id).count == 2)
}

@Test func cancellingStopsAndRemovesThePartFile() async throws {
    let (_, options) = Stub.server { _, _ in Stub.Reply(body: Samples.bytes(50_000), hangs: true) }
    let folder = Samples.folder()
    let started = AsyncStream.makeStream(of: Void.self)
    let task = Task {
        try await Download.file(Samples.url, to: folder.appending(path: "x.zip"), options: options) { progress in
            if progress.received > 0 { started.continuation.yield() }
        }
    }
    for await _ in started.stream { break }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(parts(in: folder).isEmpty)
    #expect(!exists(folder.appending(path: "x.zip")))
}

@Test func aKeptPartialFileIsPickedUpNextTime() async throws {
    let body = Samples.bytes(60_000)
    let serve = Stub.serving(body)
    var (id, options) = Stub.server { request, index in
        index == 0 ? Stub.Reply(body: body, hangs: true) : serve(request, index)
    }
    options.keepsPartialFile = true
    let folder = Samples.folder()
    let destination = folder.appending(path: "x.zip")
    let started = AsyncStream.makeStream(of: Void.self)
    let task = Task {
        try await Download.file(Samples.url, to: destination, options: options) { progress in
            if progress.received > 0 { started.continuation.yield() }
        }
    }
    for await _ in started.stream { break }
    task.cancel()
    _ = try? await task.value
    #expect(parts(in: folder) == [".x.zip.part"])

    try await Download.file(Samples.url, to: destination, sha256: SHA256Hex.of(body), options: options)
    #expect(try Data(contentsOf: destination) == body)
    #expect(Stub.requests(id)[1].value(forHTTPHeaderField: "Range") == "bytes=4096-")
    #expect(parts(in: folder).isEmpty)
}

@Test func aCancelledTaskNeverStarts() async throws {
    let (id, options) = Stub.server(Stub.serving(Samples.bytes(100)))
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await Download.file(Samples.url, to: Samples.folder().appending(path: "x"), options: options)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(Stub.requests(id).count <= 1)
}

@Test func intoAFolderKeepsTheServersName() async throws {
    let body = Samples.bytes(3000)
    let (_, options) = Stub.server { _, _ in
        Stub.Reply(headers: ["Content-Disposition": "attachment; filename=\"SMAPI-4.1.0-installer.zip\""], body: body)
    }
    let folder = try Download.temporaryFolder(prefix: "DownloadKitTests")
    let file = try await Download.file(URL(string: "https://cdn.example.com/dl?id=7")!, into: folder, options: options)
    #expect(file == folder.appending(path: "SMAPI-4.1.0-installer.zip"))
    #expect(try Data(contentsOf: file) == body)

    let (_, plain) = Stub.server(Stub.serving(body))
    let named = try await Download.file(URL(string: "https://example.com/files/My%20Mod.7z")!, into: folder, options: plain)
    #expect(named.lastPathComponent == "My Mod.7z")
    #expect(parts(in: folder).isEmpty)
}

@Test func theUserAgentNamesTheAppAndNoPerson() async throws {
    let (id, options) = Stub.server(Stub.serving(Data("ok".utf8)))
    _ = try await Download.data(from: Samples.url, options: options)
    let agent = try #require(Stub.requests(id).first?.value(forHTTPHeaderField: "User-Agent"))
    #expect(agent == DownloadOptions.defaultUserAgent)
    #expect(agent.hasSuffix("DownloadKit"))
    #expect(!agent.contains(NSUserName()))

    var custom = options
    custom.userAgent = "Tadpole-macOS/1.0"
    _ = try await Download.data(from: Samples.url, options: custom)
    #expect(Stub.requests(id).last?.value(forHTTPHeaderField: "User-Agent") == "Tadpole-macOS/1.0")
}

@Test func dataReturnsTheBodyAndReadsRateLimits() async throws {
    let (_, options) = Stub.server(Stub.serving(Data("hello".utf8)))
    #expect(try await Download.data(from: Samples.url, options: options) == Data("hello".utf8))

    let (_, limited) = Stub.server { _, _ in
        Stub.Reply(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000000"])
    }
    await #expect(throws: DownloadError.rateLimited(until: Date(timeIntervalSince1970: 1_800_000_000))) {
        try await Download.data(from: Samples.url, options: limited)
    }
}

@Test func aStampIsTheETagAndDate() async throws {
    let (id, options) = Stub.server { _, _ in
        Stub.Reply(headers: ["ETag": "\"abc\"", "Last-Modified": "Wed, 21 Oct 2026 07:28:00 GMT"])
    }
    #expect(await Download.stamp(of: Samples.url, options: options) == "\"abc\" Wed, 21 Oct 2026 07:28:00 GMT")
    #expect(Stub.requests(id).first?.httpMethod == "HEAD")
    let (_, none) = Stub.server { _, _ in Stub.Reply() }
    #expect(await Download.stamp(of: Samples.url, options: none) == nil)
    let (_, missing) = Stub.server { _, _ in Stub.Reply(status: 404, headers: ["ETag": "x"]) }
    #expect(await Download.stamp(of: Samples.url, options: missing) == nil)
}

// MARK: Ranges

@Test func aRangeIsAppendedAndResumed() async throws {
    let body = Samples.bytes(80_000)
    let (id, options) = Stub.server(Stub.serving(body))
    let file = Samples.folder().appending(path: "entry.packed")
    try body.subdata(in: 1000..<6000).write(to: file)     // 5000 of the range's 20 000 bytes are already there
    let reports = Samples.Reports()
    try await Download.range(Samples.url, offset: 1000, length: 20_000, appendingTo: file, options: options) { reports.add($0) }
    #expect(try Data(contentsOf: file) == body.subdata(in: 1000..<21_000))
    #expect(Stub.requests(id).first?.value(forHTTPHeaderField: "Range") == "bytes=6000-20999")
    #expect(reports.all.first == DownloadProgress(received: 5000, total: 20_000))
    #expect(reports.all.last == DownloadProgress(received: 20_000, total: 20_000))

    try await Download.range(Samples.url, offset: 1000, length: 20_000, appendingTo: file, options: options)
    #expect(Stub.requests(id).count == 1)
}

@Test func aRangeNeedsAServerThatSendsRanges() async throws {
    let url = Samples.url
    let (_, options) = Stub.server(Stub.serving(Samples.bytes(1000), ranges: false))
    await #expect(throws: DownloadError.rangesNotSupported(url)) {
        try await Download.range(url, offset: 0, length: 100, appendingTo: Samples.folder().appending(path: "x"), options: options)
    }
}

@Test func aRangeSurvivesADropAndARedirect() async throws {
    let body = Samples.bytes(50_000)
    let node = URL(string: "https://node7.storage.example.org/items/game.zip")!
    let (id, options) = Stub.server { request, index in
        if request.url?.host == Samples.url.host { return Stub.Reply(redirect: node) }
        guard let range = request.value(forHTTPHeaderField: "Range"), let match = range.wholeMatch(of: /bytes=(\d+)-(\d+)/),
              let first = Int(match.1), let last = Int(match.2) else { return Stub.Reply(status: 200, body: body) }
        let slice = body.subdata(in: first..<(last + 1))
        return Stub.Reply(status: 206, headers: ["Content-Range": "bytes \(first)-\(last)/50000"], body: slice,
                          dropAfter: index == 1 ? 4096 : nil)
    }
    let file = Samples.folder().appending(path: "x")
    try await Download.range(Samples.url, offset: 10_000, length: 30_000, appendingTo: file, options: options)
    #expect(try Data(contentsOf: file) == body.subdata(in: 10_000..<40_000))
    let ranges = Stub.requests(id).map { $0.value(forHTTPHeaderField: "Range") }
    #expect(ranges == ["bytes=10000-39999", "bytes=10000-39999", "bytes=14096-39999", "bytes=14096-39999"])
}

@Test func retryWaitsDoubleUpToTheLimit() {
    let policy = RetryPolicy(attempts: 9, delay: .seconds(2), maxDelay: .seconds(30))
    #expect((1...6).map { policy.wait(after: $0) } == [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
    #expect(RetryPolicy(attempts: 0).attempts == 1)
}

@Test func progressKnowsWhenItCantTell() {
    #expect(DownloadProgress(received: 5, total: nil).fraction == nil)
    #expect(DownloadProgress(received: 0, total: 0).fraction == 1)
    #expect(DownloadProgress(received: 25, total: 100).fraction == 0.25)
}
