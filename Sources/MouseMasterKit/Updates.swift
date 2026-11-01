import Foundation

/// What the agent knows about newer versions. Updates are published as GitHub releases.
public struct UpdateStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case idle, checking, downloading, installing
    }

    public var phase: Phase = .idle
    /// The newest published version, once a check has succeeded.
    public var latestVersion: String?
    /// The newest version is newer than the one running.
    public var available = false
    /// Release notes (Markdown) and the release page.
    public var notes: String?
    public var pageURL: String?
    /// Why the last check or installation failed.
    public var error: String?
    public var lastChecked: Date?

    public init() {}
}

public enum AppVersion {
    /// The numbers in "v1.2.3", "1.2" or "1.2.3-beta.1": [1, 2, 3], [1, 2], [1, 2, 3].
    public static func parts(_ version: String) -> [Int] {
        var s = Substring(version.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        let core = s.split(whereSeparator: { $0 == "-" || $0 == "+" || $0 == " " }).first ?? ""
        return core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    /// `a` comes after `b`. Missing parts count as zero, so 1.2 and 1.2.0 are the same.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

/// The parts of a GitHub release (`GET /repos/{owner}/{repo}/releases/latest`) an update needs.
public struct GitHubRelease: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public var name: String
        public var url: URL
        public var size: Int

        public init(name: String, url: URL, size: Int) {
            self.name = name
            self.url = url
            self.size = size
        }

        enum CodingKeys: String, CodingKey {
            case name, url = "browser_download_url", size
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            url = try c.decode(URL.self, forKey: .url)
            size = c.value(.size, 0)
        }
    }

    public var tag: String
    public var title: String?
    public var notes: String?
    public var page: URL
    public var draft: Bool
    public var prerelease: Bool
    public var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name", title = "name", notes = "body", page = "html_url", draft, prerelease, assets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decode(String.self, forKey: .tag)
        title = c.optional(.title)
        notes = c.optional(.notes)
        page = try c.decode(URL.self, forKey: .page)
        draft = c.value(.draft, false)
        prerelease = c.value(.prerelease, false)
        assets = c.value(.assets, [])
    }

    /// "1.2.0" for the tag "v1.2.0".
    public var version: String {
        tag.first == "v" || tag.first == "V" ? String(tag.dropFirst()) : tag
    }

    /// The zipped app: "Mouse-Master-1.2.0.zip", or else the only zip attached.
    public var archive: Asset? {
        let zips = assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        return zips.first { $0.name.contains(version) } ?? (zips.count == 1 ? zips.first : nil)
    }
}
