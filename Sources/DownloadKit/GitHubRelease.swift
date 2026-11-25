import Foundation

/// A release on GitHub (or on a Gitea or Forgejo server, which answer the same way): its tag, name, notes, date
/// and files. Codable, so an app can keep the last answer for offline use.
public struct GitHubRelease: Codable, Hashable, Sendable, Identifiable {
    /// One file of a release.
    public struct Asset: Codable, Hashable, Sendable, Identifiable {
        public var id: Int
        public var name: String
        /// Where to download it (`browser_download_url`).
        public var url: URL
        public var size: Int64
        /// The SHA-256 GitHub publishes for the file (its "digest"), when it has one.
        public var sha256: String?
        public var contentType: String?
        /// When the file was last uploaded: with `id`, it tells a new build under the same name.
        public var updated: Date?
        /// `updated_at` exactly as the API wrote it ("2026-10-02T00:00:00Z"), for an identity recorded as text.
        public var updatedText: String?

        public init(id: Int, name: String, url: URL, size: Int64, sha256: String? = nil, contentType: String? = nil, updated: Date? = nil,
                    updatedText: String? = nil) {
            self.id = id
            self.name = name
            self.url = url
            self.size = size
            self.sha256 = sha256
            self.contentType = contentType
            self.updated = updated
            self.updatedText = updatedText
        }
    }

    /// The API's id. A feed that leaves it out (a hand-written catalog, some mirrors) gets a stable negative number
    /// made from the tag; an asset's from its download URL. Never 0.
    public var id: Int
    /// "v1.2.0".
    public var tag: String
    /// The release's title, or its tag when it has none.
    public var name: String
    /// The release notes, in Markdown ("" when there are none).
    public var notes: String
    /// The release's page on the website.
    public var page: URL?
    public var published: Date?
    public var isPrerelease: Bool
    public var isDraft: Bool
    public var assets: [Asset]

    public init(id: Int, tag: String, name: String, notes: String = "", page: URL? = nil, published: Date? = nil,
                isPrerelease: Bool = false, isDraft: Bool = false, assets: [Asset] = []) {
        self.id = id
        self.tag = tag
        self.name = name
        self.notes = notes
        self.page = page
        self.published = published
        self.isPrerelease = isPrerelease
        self.isDraft = isDraft
        self.assets = assets
    }

    /// The tag without a leading "v": "1.2.0".
    public var version: String { ReleaseVersion.trimmed(tag) }

    /// The file with this exact name.
    public func asset(named name: String) -> Asset? {
        assets.first { $0.name == name }
    }

    // MARK: Lookups

    /// GitHub's API.
    public static let api = URL(string: "https://api.github.com")!

    /// GITHUB_TOKEN from the environment, when set: CI machines share GitHub's anonymous rate limit.
    public static var environmentToken: String? {
        ProcessInfo.processInfo.environment["GITHUB_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The newest release that is neither a draft nor a pre-release. A repository without one throws
    /// `DownloadError.http(status: 404, …)`.
    public static func latest(owner: String, repo: String, token: String? = environmentToken,
                              options: DownloadOptions = DownloadOptions()) async throws -> GitHubRelease {
        try await latest(at: url(owner, repo, "releases/latest"), token: token, options: options)
    }

    /// The release with this tag.
    public static func release(tag: String, owner: String, repo: String, token: String? = environmentToken,
                               options: DownloadOptions = DownloadOptions()) async throws -> GitHubRelease {
        try await latest(at: url(owner, repo, "releases/tags/\(tag)"), token: token, options: options)
    }

    /// One release from a full API URL: GitHub's ".../releases/latest", or a Gitea or Forgejo server's
    /// ("https://git.example.org/api/v1/repos/<owner>/<repo>/releases/latest"). `token` only goes to api.github.com.
    public static func latest(at apiURL: URL, token: String? = environmentToken,
                              options: DownloadOptions = DownloadOptions()) async throws -> GitHubRelease {
        let data = try await Download.data(for: request(apiURL, token: token, options: options), options: options)
        do { return try decode(data) } catch { throw DownloadError.badResponse(apiURL) }
    }

    /// Releases newest first, up to `limit` (pre-releases included; drafts only show with a token that can see
    /// them). Filter with `isPrerelease` and `isDraft`.
    public static func all(owner: String, repo: String, limit: Int = 30, token: String? = environmentToken,
                           options: DownloadOptions = DownloadOptions()) async throws -> [GitHubRelease] {
        let perPage = min(max(limit, 1), 100)
        var releases: [GitHubRelease] = []
        var page = 1
        while releases.count < limit {
            var pageURL = url(owner, repo, "releases")
            pageURL.append(queryItems: [URLQueryItem(name: "per_page", value: String(perPage)), URLQueryItem(name: "page", value: String(page))])
            let data = try await Download.data(for: request(pageURL, token: token, options: options), options: options)
            let batch: [GitHubRelease]
            do { batch = try decodeList(data) } catch { throw DownloadError.badResponse(pageURL) }
            releases += batch
            if batch.count < perPage { break }
            page += 1
        }
        return Array(releases.prefix(limit))
    }

    /// The SHA-256 of `asset`: GitHub's digest, else a "<name>.sha256" file beside it, else its line in a
    /// SHA256SUMS or checksums.txt file of the release. Nil when the release publishes none.
    public func checksum(for asset: Asset, options: DownloadOptions = DownloadOptions()) async throws -> String? {
        if let sha256 = asset.sha256 { return sha256 }
        let sidecars = [".sha256", ".sha256sum", ".sha256.txt"].compactMap { self.asset(named: asset.name + $0) }
        let lists = assets.filter { ["sha256sums", "sha256sums.txt", "sha256sum.txt", "checksums.txt", "checksums.sha256"].contains($0.name.lowercased()) }
        for file in sidecars + lists {
            let text = String(decoding: try await Download.data(from: file.url, options: options), as: UTF8.self)
            if let hash = SHA256Hex.find(for: asset.name, in: text) { return hash }
        }
        return nil
    }

    // MARK: Reading the API's JSON

    /// One release from the API's JSON.
    public static func decode(_ data: Data) throws -> GitHubRelease {
        try decoder().decode(APIRelease.self, from: data).release
    }

    /// A list of releases from the API's JSON.
    public static func decodeList(_ data: Data) throws -> [GitHubRelease] {
        try decoder().decode([APIRelease].self, from: data).map(\.release)
    }

    static func url(_ owner: String, _ repo: String, _ path: String) -> URL {
        api.appending(path: "repos/\(owner)/\(repo)/\(path)")
    }

    static func request(_ url: URL, token: String?, options: DownloadOptions) -> URLRequest {
        var request = options.request(url)
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        }
        if url.host?.lowercased() == api.host {
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            if let token, request.value(forHTTPHeaderField: "Authorization") == nil {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    private static func decoder() -> JSONDecoder { JSONDecoder() }

    /// An ISO 8601 date, with or without fractional seconds or an offset; nil for anything else.
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// A stable id for a feed without one: negative, so it never meets a real one, and never 0.
    static func fallbackID(_ text: String) -> Int {
        -(Int(SHA256Hex.of(Data(text.utf8)).prefix(12), radix: 16) ?? 0) - 1
    }
}

/// The API's shape, read leniently: Gitea leaves out some fields and GitHub sends null for others.
private struct APIRelease: Decodable {
    struct Asset: Decodable {
        var id: Int?
        var name: String
        var browser_download_url: URL
        var size: Int64?
        var digest: String?
        var content_type: String?
        var updated_at: String?
        var created_at: String?
    }

    var id: Int?
    var tag_name: String
    var name: String?
    var body: String?
    var html_url: URL?
    var published_at: String?
    var created_at: String?
    var prerelease: Bool?
    var draft: Bool?
    var assets: [Asset]?

    var release: GitHubRelease {
        let title = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GitHubRelease(
            id: id ?? GitHubRelease.fallbackID(tag_name), tag: tag_name, name: title?.isEmpty == false ? title! : tag_name,
            notes: body ?? "", page: html_url,
            published: GitHubRelease.date(published_at) ?? GitHubRelease.date(created_at),
            isPrerelease: prerelease ?? false, isDraft: draft ?? false,
            assets: (assets ?? []).map { asset in
                GitHubRelease.Asset(id: asset.id ?? GitHubRelease.fallbackID(asset.browser_download_url.absoluteString), name: asset.name,
                                    url: asset.browser_download_url, size: asset.size ?? 0,
                                    sha256: asset.digest.flatMap(SHA256Hex.normalized), contentType: asset.content_type,
                                    updated: GitHubRelease.date(asset.updated_at) ?? GitHubRelease.date(asset.created_at),
                                    updatedText: asset.updated_at)
            })
    }
}
