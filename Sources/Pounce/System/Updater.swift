import AppKit
import Combine

/// A newer release on GitHub.
struct UpdateInfo: Equatable, Sendable {
    let version: String
    let pageURL: URL
    /// The release's .dmg asset, if any (opened instead of the page).
    let downloadURL: URL?
    let notes: String
}

/// Lightweight update check: one anonymous GET to the GitHub Releases API, at most once a day.
/// Never downloads or installs anything — `open(_:)` just shows the release page / DMG.
/// Disabled for Nix installs (/nix/store), dev builds, and with POUNCE_NO_UPDATE_CHECK=1.
/// Opt-out: `Updater.shared.automaticChecks = false` (UserDefaults "automaticUpdateChecks").
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "jaeaeich/pounce"
    private static let interval: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "lastUpdateCheck"
    private static let enabledKey = "automaticUpdateChecks"

    /// Newer release than the running build, or nil.
    @Published private(set) var available: UpdateInfo?
    @Published private(set) var checking = false

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    /// Why update checks can't run at all (nil = they can).
    var disabledReason: String? {
        if ProcessInfo.processInfo.environment["POUNCE_NO_UPDATE_CHECK"] == "1" { return "POUNCE_NO_UPDATE_CHECK=1" }
        if Bundle.main.bundlePath.hasPrefix("/nix/store/") { return "Installed with Nix — update through Nix" }
        if Self.parse(currentVersion) == nil { return "Development build" }
        return nil
    }

    var automaticChecks: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            objectWillChange.send()
        }
    }

    var lastCheck: Date? { UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date }

    private var timer: Timer?

    /// Call once at startup: checks now if due, then re-evaluates every few hours.
    func scheduleAutomaticChecks() {
        Task { await check(manual: false) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check(manual: false) }
        }
    }

    /// Checks GitHub for a newer release. Automatic checks respect the opt-out and the daily limit;
    /// manual ones (a "Check for Updates" button) always run unless `disabledReason` is set.
    @discardableResult
    func check(manual: Bool) async -> UpdateInfo? {
        guard disabledReason == nil, !checking else { return available }
        if !manual {
            guard automaticChecks else { return available }
            if let last = lastCheck, Date().timeIntervalSince(last) < Self.interval { return available }
        }
        checking = true
        defer { checking = false }

        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Pounce/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let config = URLSessionConfiguration.ephemeral  // no cookies, no on-disk cache
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let (data, resp) = try? await session.data(for: req),
            (resp as? HTTPURLResponse)?.statusCode == 200,
            let release = try? decoder.decode(Release.self, from: data)
        else {
            log.info("update check failed")
            return available
        }
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

        let tag = release.tagName
        guard !release.draft, !release.prerelease,
            let latest = Self.parse(tag), let current = Self.parse(currentVersion),
            Self.isNewer(latest, than: current),
            let page = URL(string: release.htmlUrl)
        else {
            available = nil
            return nil
        }
        let dmg = release.assets.first { $0.name.hasSuffix(".dmg") }.flatMap { URL(string: $0.browserDownloadUrl) }
        let info = UpdateInfo(version: Self.strip(tag), pageURL: page, downloadURL: dmg, notes: release.body ?? "")
        available = info
        return info
    }

    /// Opens the DMG download (or the release page) in the browser.
    func open(_ info: UpdateInfo, download: Bool = false) {
        NSWorkspace.shared.open(download ? info.downloadURL ?? info.pageURL : info.pageURL)
    }

    // MARK: - SemVer

    struct Version: Equatable {
        var core: [Int]
        var pre: [String]  // empty = release
    }

    nonisolated static func strip(_ s: String) -> String {
        s.hasPrefix("v") || s.hasPrefix("V") ? String(s.dropFirst()) : s
    }

    nonisolated static func parse(_ s: String) -> Version? {
        let noBuild = strip(s.trimmingCharacters(in: .whitespaces)).split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
        let parts = noBuild.split(separator: "-", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return nil }
        let core = first.split(separator: ".").map { Int($0) }
        guard (1...3).contains(core.count), core.allSatisfy({ $0 != nil }) else { return nil }
        let padded = core.compactMap { $0 } + Array(repeating: 0, count: 3 - core.count)
        let pre = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        return Version(core: padded, pre: pre)
    }

    nonisolated static func isNewer(_ a: Version, than b: Version) -> Bool {
        if a.core != b.core { return b.core.lexicographicallyPrecedes(a.core) }
        // Same core: a release beats any pre-release; otherwise compare identifiers.
        if a.pre.isEmpty || b.pre.isEmpty { return a.pre.isEmpty && !b.pre.isEmpty }
        for (x, y) in zip(a.pre, b.pre) where x != y {
            switch (Int(x), Int(y)) {
            case (let i?, let j?): return i > j
            case (nil, _?): return true
            case (_?, nil): return false
            default: return x > y
            }
        }
        return a.pre.count > b.pre.count
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlUrl: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
        }
    }
}
