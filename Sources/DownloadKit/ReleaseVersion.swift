import Foundation

/// Compares version strings the way release tags are written.
public enum ReleaseVersion {
    /// Without a leading "v" or "V": "v1.2.0" is "1.2.0".
    public static func trimmed(_ tag: String) -> String {
        let text = tag.trimmingCharacters(in: .whitespaces)
        return text.hasPrefix("v") || text.hasPrefix("V") ? String(text.dropFirst()) : text
    }

    /// Whether `candidate` is newer than `installed`.
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }

    /// Semantic versions: "0.4.10" is newer than "0.4.9", "0.5.0" newer than "0.5.0-rc.1", "1.2" the same as
    /// "1.2.0". A leading "v" and build metadata ("+abc") are ignored.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func split(_ version: String) -> (core: [Int], pre: [String]) {
            var text = trimmed(version)
            if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
            let parts = text.split(separator: "-", maxSplits: 1).map(String.init)
            let core = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            let pre = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
            return (core, pre)
        }
        let (x, y) = (split(a), split(b))
        for i in 0..<max(x.core.count, y.core.count) {
            let (p, q) = (i < x.core.count ? x.core[i] : 0, i < y.core.count ? y.core[i] : 0)
            if p != q { return p < q ? .orderedAscending : .orderedDescending }
        }
        // A release outranks its pre-releases.
        if x.pre.isEmpty != y.pre.isEmpty { return x.pre.isEmpty ? .orderedDescending : .orderedAscending }
        for i in 0..<max(x.pre.count, y.pre.count) {
            guard i < x.pre.count else { return .orderedAscending }
            guard i < y.pre.count else { return .orderedDescending }
            let (p, q) = (x.pre[i], y.pre[i])
            if p == q { continue }
            switch (Int(p), Int(q)) {
            case let (m?, n?): return m < n ? .orderedAscending : .orderedDescending
            case (.some, nil): return .orderedAscending
            case (nil, .some): return .orderedDescending
            default: return p < q ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }
}
