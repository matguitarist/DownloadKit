# DownloadKit

How my apps download files and look up GitHub releases. It gathers what each app wrote on its own: RenChan's
runtime download hashed as it streams, Starseed's and Tadpole's downloads that keep the server's file name,
Hearthside's byte ranges that resume after a drop and survive archive.org's redirects, Attic's ETag stamps for builds
behind a fixed link, SM Launcher Plus's checked zips and release notes, and the checksums each release publishes.

- **Download**: a file with progress, streamed to a hidden part file beside the destination and hashed on the way.
  It appears only when every byte is in and the SHA-256 matches. Dropped connections are tried again from where they
  stopped. Never reads the whole file into memory.
- **GitHubRelease**: the latest release, one by tag, or all of them, with tag, name, notes, date, pre-release flag and
  files (name, URL, size, SHA-256). Honors `GITHUB_TOKEN`. Works with Gitea and Forgejo servers too.
- **SHA256Hex**, **ReleaseVersion**: hashes of files and bytes, checksums files in every layout, versions compared
  the way tags are written.

macOS 14 or iOS 17 or later. No dependencies.

## Add it to an app

SwiftPM (`Package.swift`):

```swift
.package(url: "https://github.com/matguitarist/DownloadKit", from: "0.1.0"),
// in the target:
.product(name: "DownloadKit", package: "DownloadKit"),
```

XcodeGen (`project.yml`):

```yaml
packages:
  DownloadKit:
    url: https://github.com/matguitarist/DownloadKit
    from: 0.1.0
targets:
  App:
    dependencies:
      - package: DownloadKit
        product: DownloadKit
```

## Download a file

```swift
import DownloadKit

// To a known place, checked. A file already there with this hash is kept and nothing is downloaded.
let archive = try await Download.file(url, to: store.appending(path: "renpy-8.3.4-sdk.tar.bz2"), sha256: expected) { progress in
    Task { @MainActor in model.fraction = progress.fraction ?? 0 }    // called from a background queue
}

// Into a fresh temporary folder under the server's name, so the archive keeps its extension.
let folder = try Download.temporaryFolder(prefix: "starseed")
let zip = try await Download.file(release.installerURL, into: folder)
defer { try? FileManager.default.removeItem(at: folder) }
```

`progress` gets `received` and `total` bytes (`total` is nil when the server doesn't say) and `fraction`. It comes at
most ten times a second, and once at the end.

A failure throws a `URLError` (offline, timed out), `CancellationError` when the task was cancelled, or a
`DownloadError`: `.http(status:url:)`, `.rateLimited(until:)`, `.checksumMismatch(expected:actual:)`,
`.invalidChecksum`, `.rangesNotSupported`, `.badResponse`. The app words them.

### Options

```swift
var options = DownloadOptions()
options.userAgent = "Tadpole-macOS/1.4"           // default: "<App>/<version> DownloadKit"
options.headers = ["apikey": key]                 // Authorization is dropped when a redirect leaves the host
options.retry = .patient                          // .standard (4 tries), .patient (9, up to 30 s apart), .none
options.keepsPartialFile = true                   // a stopped download picks up from its part file next time
options.timeout = 60
options.session = mySession                       // tests pass one with a URLProtocol stub
```

### A byte range

```swift
// Appends bytes 1000..<21000 of the zip to the file; bytes already there count, so a pause resumes.
try await Download.range(zipURL, offset: 1000, length: 20_000, appendingTo: packed, options: .init(retry: .patient)) { p in … }
```

The server must answer with ranges (206). Range is carried across redirects.

### Small things

```swift
let sums = String(decoding: try await Download.data(from: checksumsURL), as: UTF8.self)
let expected = SHA256Hex.find(for: "renpy-8.3.4-sdk.tar.bz2", in: sums)

// A new build behind a fixed link: compare with the stamp saved at install.
let stamp = await Download.stamp(of: nightlyURL)                   // "<ETag> <Last-Modified>", or nil
```

## GitHub releases

```swift
let release = try await GitHubRelease.latest(owner: "Pathoschild", repo: "SMAPI")
let installer = release.assets.first { $0.name.wholeMatch(of: /SMAPI-[\d.]+-installer\.zip/) != nil }

// Its SHA-256: GitHub's digest, a "<name>.sha256" file beside it, or its line in SHA256SUMS / checksums.txt.
if let installer, let sha256 = try await release.checksum(for: installer) {
    try await Download.file(installer.url, to: destination, sha256: sha256)
}

// What's new since the installed version, newest first.
let notes = try await GitHubRelease.all(owner: "mstan", repo: "SuperMetroidRecomp", limit: 10)
    .filter { !$0.isDraft && !$0.isPrerelease && ReleaseVersion.isNewer($0.version, than: installed) }

// A Gitea or Forgejo server, or a full API URL kept in a catalog.
let ryujinx = try await GitHubRelease.latest(at: URL(string: "https://git.ryujinx.app/api/v1/repos/projects/Ryubing/releases/latest")!)
```

A release has `id`, `tag`, `version` (the tag without "v"), `name` (the tag when untitled), `notes`, `page`,
`published`, `isPrerelease`, `isDraft` and `assets` (`id`, `name`, `url`, `size`, `sha256`, `contentType`,
`updated`). It is Codable, so an app can keep the last answer for offline use. `GitHubRelease.decode(data)` reads one
from JSON an app already has.

`GITHUB_TOKEN` from the environment is sent to api.github.com when set (CI machines share the anonymous rate limit);
pass `token:` to use another, or `nil` for none. It never goes to another host.

## Testing downloads in an app

Pass `DownloadOptions(session:)` a session whose configuration has a `URLProtocol` stub in `protocolClasses`, as
`Tests/DownloadKitTests/Stub.swift` does. Keep files under `FileManager.default.temporaryDirectory`.
