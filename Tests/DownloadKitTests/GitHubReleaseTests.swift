import Foundation
import Testing
@testable import DownloadKit

private let hash = String(repeating: "d", count: 64)

private func releaseJSON(id: Int = 1, tag: String = "v0.4.6", name: String? = "SuperMetroidRecomp 0.4.6", prerelease: Bool = false,
                         draft: Bool = false, published: String = "2026-03-01T12:00:00Z") -> String {
    let title = name.map { "\"\($0)\"" } ?? "null"
    return """
    {"id": \(id), "tag_name": "\(tag)", "name": \(title), "body": "## Fixed\\n- Saves", "html_url": "https://github.com/mstan/SuperMetroidRecomp/releases/tag/\(tag)",
     "draft": \(draft), "prerelease": \(prerelease), "published_at": "\(published)",
     "assets": [
      {"id": 11, "name": "supermetroid-0.4.6-macos-arm64.zip", "size": 1234567, "content_type": "application/zip",
       "digest": "sha256:\(hash.uppercased())", "updated_at": "2026-03-01T12:05:00Z",
       "browser_download_url": "https://github.com/mstan/SuperMetroidRecomp/releases/download/\(tag)/supermetroid-0.4.6-macos-arm64.zip"},
      {"id": 12, "name": "SHA256SUMS", "size": 90, "digest": null, "updated_at": "2026-03-01T12:05:00Z",
       "browser_download_url": "https://github.com/mstan/SuperMetroidRecomp/releases/download/\(tag)/SHA256SUMS"}
     ]}
    """
}

@Test func readsAReleaseFromGitHubsJSON() throws {
    let release = try GitHubRelease.decode(Data(releaseJSON().utf8))
    #expect(release.tag == "v0.4.6" && release.version == "0.4.6" && release.name == "SuperMetroidRecomp 0.4.6")
    #expect(release.notes == "## Fixed\n- Saves")
    #expect(release.page?.absoluteString == "https://github.com/mstan/SuperMetroidRecomp/releases/tag/v0.4.6")
    #expect(release.published == Date(timeIntervalSince1970: 1_772_366_400))
    #expect(!release.isPrerelease && !release.isDraft)
    let zip = try #require(release.asset(named: "supermetroid-0.4.6-macos-arm64.zip"))
    #expect(zip.id == 11 && zip.size == 1_234_567 && zip.sha256 == hash && zip.contentType == "application/zip")
    #expect(zip.updated == Date(timeIntervalSince1970: 1_772_366_700))
    #expect(release.asset(named: "SHA256SUMS")?.sha256 == nil)
}

@Test func aReleaseWithoutATitleIsNamedByItsTag() throws {
    #expect(try GitHubRelease.decode(Data(releaseJSON(name: nil).utf8)).name == "v0.4.6")
    #expect(try GitHubRelease.decode(Data(releaseJSON(name: " ").utf8)).name == "v0.4.6")
}

@Test func readsGiteaReleasesAndOtherDates() throws {
    // Gitea and Forgejo leave out digest, content_type and updated_at, and write dates with an offset.
    let json = """
    {"id": 5, "tag_name": "1.3.2", "name": "", "body": "", "draft": false, "prerelease": true,
     "published_at": "2026-01-10T09:30:00+01:00", "html_url": "https://git.example.org/projects/Ryubing/releases/tag/1.3.2",
     "assets": [{"id": 9, "name": "ryujinx-1.3.2-macos_universal.app.tar.gz", "size": 100, "created_at": "2026-01-10T08:00:00.123Z",
                 "browser_download_url": "https://git.example.org/attachments/9"}]}
    """
    let release = try GitHubRelease.decode(Data(json.utf8))
    #expect(release.isPrerelease && release.version == "1.3.2" && release.name == "1.3.2")
    #expect(release.published == Date(timeIntervalSince1970: 1_768_033_800))
    #expect(release.assets.first?.updated != nil)
}

@Test func keepsAReleaseAsJSON() throws {
    let release = try GitHubRelease.decode(Data(releaseJSON().utf8))
    let copy = try JSONDecoder().decode(GitHubRelease.self, from: JSONEncoder().encode(release))
    #expect(copy == release)
}

@Test func asksGitHubsAPIForTheLatestRelease() async throws {
    let (id, options) = Stub.server { _, _ in Stub.Reply(body: Data(releaseJSON().utf8)) }
    let release = try await GitHubRelease.latest(owner: "mstan", repo: "SuperMetroidRecomp", token: nil, options: options)
    #expect(release.version == "0.4.6")
    let request = try #require(Stub.requests(id).first)
    #expect(request.url?.absoluteString == "https://api.github.com/repos/mstan/SuperMetroidRecomp/releases/latest")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.value(forHTTPHeaderField: "User-Agent") == DownloadOptions.defaultUserAgent)
}

@Test func aTokenGoesOnlyToGitHub() async throws {
    let (id, options) = Stub.server { _, _ in Stub.Reply(body: Data(releaseJSON().utf8)) }
    _ = try await GitHubRelease.release(tag: "v0.4.6", owner: "o", repo: "r", token: "secret", options: options)
    let gitea = URL(string: "https://git.example.org/api/v1/repos/projects/Ryubing/releases/latest")!
    _ = try await GitHubRelease.latest(at: gitea, token: "secret", options: options)
    let requests = Stub.requests(id)
    #expect(requests[0].url?.path() == "/repos/o/r/releases/tags/v0.4.6")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    #expect(requests[1].url == gitea)
    #expect(requests[1].value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func aRepositoryWithoutReleasesSays404AndBadJSONSaysSo() async throws {
    let (_, missing) = Stub.server { _, _ in Stub.Reply(status: 404) }
    let url = URL(string: "https://api.github.com/repos/o/r/releases/latest")!
    await #expect(throws: DownloadError.http(status: 404, url: url)) {
        try await GitHubRelease.latest(owner: "o", repo: "r", token: nil, options: missing)
    }
    let (_, garbled) = Stub.server { _, _ in Stub.Reply(body: Data("<html>".utf8)) }
    await #expect(throws: DownloadError.badResponse(url)) {
        try await GitHubRelease.latest(owner: "o", repo: "r", token: nil, options: garbled)
    }
}

@Test func listsReleasesPageByPage() async throws {
    // 150 releases, served the way GitHub pages them.
    let (id, options) = Stub.server { request, _ in
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let page = Int(items.first { $0.name == "page" }?.value ?? "1")!
        let perPage = Int(items.first { $0.name == "per_page" }?.value ?? "30")!
        let ids = Array(1...150).dropFirst((page - 1) * perPage).prefix(perPage)
        let list = ids.map { releaseJSON(id: $0, tag: "v0.\($0)", prerelease: $0 == 2, draft: $0 == 3) }
        return Stub.Reply(body: Data("[\(list.joined(separator: ","))]".utf8))
    }
    let first = try await GitHubRelease.all(owner: "o", repo: "r", limit: 3, token: nil, options: options)
    #expect(first.map(\.id) == [1, 2, 3])
    #expect(first[1].isPrerelease && first[2].isDraft)
    #expect(Stub.requests(id).map { $0.url?.query() } == ["per_page=3&page=1"])
    let many = try await GitHubRelease.all(owner: "o", repo: "r", limit: 120, token: nil, options: options)
    #expect(many.map(\.id) == Array(1...120))
    #expect(Stub.requests(id).dropFirst().map { $0.url?.query() } == ["per_page=100&page=1", "per_page=100&page=2"])
    let every = try await GitHubRelease.all(owner: "o", repo: "r", limit: 1000, token: nil, options: options)
    #expect(every.count == 150)
}

@Test func findsAnAssetsChecksumWhereverTheReleasePutsIt() async throws {
    let base = "https://github.com/o/r/releases/download/v1/"
    func asset(_ id: Int, _ name: String, sha256: String? = nil) -> GitHubRelease.Asset {
        GitHubRelease.Asset(id: id, name: name, url: URL(string: base + name)!, size: 10, sha256: sha256)
    }
    let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
    let (_, options) = Stub.server { request, _ in
        switch request.url?.lastPathComponent {
        case "bg3se.zip.sha256": Stub.Reply(body: Data("\(a)\n".utf8))
        case "SHA256SUMS": Stub.Reply(body: Data("\(b)  game-arm64.zip\n".utf8))
        default: Stub.Reply(status: 404)
        }
    }
    let withDigest = GitHubRelease(id: 1, tag: "v1", name: "v1", assets: [asset(1, "tv.apk", sha256: hash)])
    #expect(try await withDigest.checksum(for: withDigest.assets[0], options: options) == hash)
    let sidecar = GitHubRelease(id: 2, tag: "v1", name: "v1", assets: [asset(1, "bg3se.zip"), asset(2, "bg3se.zip.sha256")])
    #expect(try await sidecar.checksum(for: sidecar.assets[0], options: options) == a)
    let sums = GitHubRelease(id: 3, tag: "v1", name: "v1", assets: [asset(1, "game-arm64.zip"), asset(2, "game-x64.zip"), asset(3, "SHA256SUMS")])
    #expect(try await sums.checksum(for: sums.assets[0], options: options) == b)
    #expect(try await sums.checksum(for: sums.assets[1], options: options) == nil)
}

@Test func theEnvironmentTokenIsReadWhenSet() {
    let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
    #expect(GitHubRelease.environmentToken == (token?.isEmpty == false ? token : nil))
}

@Test func comparesVersionsLikeReleaseTags() {
    #expect(ReleaseVersion.isNewer("0.4.10", than: "0.4.9"))
    #expect(ReleaseVersion.isNewer("v0.45.0", than: "0.44.1"))
    #expect(ReleaseVersion.isNewer("0.5.0", than: "0.5.0-rc.1"))
    #expect(ReleaseVersion.isNewer("0.5.0-rc.2", than: "0.5.0-rc.1"))
    #expect(ReleaseVersion.isNewer("1.0.0-beta", than: "1.0.0-2"))
    #expect(ReleaseVersion.compare("1.2", "1.2.0") == .orderedSame)
    #expect(ReleaseVersion.compare("1.2.0+abc", "V1.2.0") == .orderedSame)
    #expect(!ReleaseVersion.isNewer("0.4.6", than: "0.4.6"))
    #expect(ReleaseVersion.trimmed("v2.8.2") == "2.8.2" && ReleaseVersion.trimmed("2.8.2") == "2.8.2")
}

@Test func keepsTheRawUpdatedText() throws {
    let release = try GitHubRelease.decode(Data(releaseJSON().utf8))
    #expect(release.asset(named: "SHA256SUMS")?.updatedText == "2026-03-01T12:05:00Z")
    let fractional = """
    {"id": 1, "tag_name": "v1", "assets": [{"id": 2, "name": "a.zip", "browser_download_url": "https://example.com/a.zip",
      "updated_at": "2026-10-02T00:00:00.500Z"}]}
    """
    let asset = try #require(try GitHubRelease.decode(Data(fractional.utf8)).assets.first)
    #expect(asset.updatedText == "2026-10-02T00:00:00.500Z")
    #expect(asset.updated == Date(timeIntervalSince1970: 1_790_899_200.5))
}

@Test func aFeedWithoutIDsGetsStableOnes() throws {
    let json = """
    {"tag_name": "v2.0", "assets": [{"name": "a.zip", "browser_download_url": "https://example.com/a.zip"},
                                    {"name": "b.zip", "browser_download_url": "https://example.com/b.zip"}]}
    """
    let release = try GitHubRelease.decode(Data(json.utf8))
    let again = try GitHubRelease.decode(Data(json.utf8))
    #expect(release.id < 0 && release.id == again.id)
    #expect(release.assets.allSatisfy { $0.id < 0 })
    #expect(release.assets[0].id != release.assets[1].id)
    #expect(release.assets.map(\.id) == again.assets.map(\.id))
}

@Test func aReleaseKeptBeforeUpdatedTextStillReads() throws {
    let old = """
    {"id": 1, "tag": "v1", "name": "v1", "notes": "", "isPrerelease": false, "isDraft": false,
     "assets": [{"id": 2, "name": "a.zip", "url": "https://example.com/a.zip", "size": 3}]}
    """
    let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(old.utf8))
    #expect(release.assets.first?.updatedText == nil && release.assets.first?.id == 2)
}
