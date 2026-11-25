# DownloadKit

How my apps download files and look up GitHub releases: streamed to disk with progress, retried and resumed after a
dropped connection, checked against a SHA-256 before the file appears. Written for RenChan, Starseed, Tadpole,
Hearthside, Attic and SM Launcher Plus, which each had their own copy. A change here reaches every app at its next
package update, so keep the API stable and additive.

Shared rules for how every project is laid out and named:
@~/.claude/project-layout.md

## Layout

- `Sources/DownloadKit/` no SwiftUI, macOS and iOS:
  - `Download`: `file(_:to:)`, `file(_:into:)`, `range`, `data`, `stamp`, `temporaryFolder`.
  - `DownloadOptions`, `RetryPolicy`, `DownloadProgress`, `DownloadError`.
  - `Transfer.swift`: the data task delegate that streams into the part file, redirects, retries. Internal.
  - `SHA256Hex`: hashes of bytes and files, normalizing, finding a file in a checksums file.
  - `GitHubRelease`: `latest`, `release(tag:)`, `latest(at:)` (Gitea and Forgejo too), `all`, `checksum(for:)`.
  - `ReleaseVersion`: compares tags as semantic versions.
- `Tests/DownloadKitTests/` Swift Testing. `Stub` is a URLProtocol server keyed by an "X-Stub" header, so tests
  run side by side with no network.

## Rules

- Everything is safe from any thread and does no I/O on the main thread by itself: the async functions run off it.
  `SHA256Hex.ofFile` is synchronous; callers keep it off the main thread.
- Never read a whole download into memory: bytes go to the part file chunk by chunk, hashed on the way.
- The destination only appears when every byte is in and the hash matches; a mismatch keeps nothing.
- A token only goes to api.github.com, and Authorization is dropped when a redirect leaves the host.
- The User-Agent names the app, never a person.
- No strings people read: errors are cases an app words itself.
- Tests never touch the network or the person's files: temp folders only, under `FileManager.default.temporaryDirectory`.
- Add a test for every change. `swift build && swift test` pass with no warnings, and the iOS build, then CI on macOS.
- Release: tag `x.y.z` and push the tag; apps use `from:`.

## Git

Commit after each working change, with a message that says what an app can now do.
