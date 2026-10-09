import AppKit
import Combine
import PounceCore

enum Paths {
    static var configDir: URL {
        let env = ProcessInfo.processInfo.environment
        let base =
            env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("pounce")
    }
    static var configFile: URL {
        if let p = ProcessInfo.processInfo.environment["POUNCE_CONFIG"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return configDir.appendingPathComponent("config.toml")
    }
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pounce")
    }
    static var usageFile: URL { supportDir.appendingPathComponent("usage.json") }
}

/// Owns the live Config: loads ~/.config/pounce/config.toml, hot-reloads on external edits,
/// and writes back (debounced) when the Settings UI changes something.
@MainActor
final class ConfigStore: ObservableObject {
    @Published var config: Config {
        didSet { if config != oldValue && !loading { scheduleSave() } }
    }
    @Published private(set) var warnings: [String] = []
    @Published private(set) var error: String?
    /// True if the config file is a read-only symlink into the Nix store (managed declaratively).
    @Published private(set) var isManaged = false

    private var loading = false
    private var saveWork: DispatchWorkItem?
    private var watcher: DispatchSourceFileSystemObject?
    private var lastWritten: String?
    /// The config as last read from / written to disk: the saver diffs against it.
    private var saved = Config()
    /// The file on disk doesn't parse: keep the last good config and don't overwrite the file.
    private(set) var parseFailed = false
    private var lastReportedError: String?

    private let persist: Bool

    /// `persist: false` gives an in-memory store (self-test, snapshots) that never touches the user's file.
    init(persist: Bool = true) {
        self.persist = persist
        config = Config()
        guard persist else { return }
        load()
        watch()
    }

    func load() {
        let url = Paths.configFile
        isManaged = url.resolvingSymlinksInPath().path.hasPrefix("/nix/store")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            warnings = []
            error = nil
            parseFailed = false
            saved = Config()
            return
        }
        if text == lastWritten { return }
        do {
            let (c, w) = try Config.parse(text)
            loading = true
            config = c
            loading = false
            saved = c
            warnings = w
            error = nil
            parseFailed = false
            lastReportedError = nil
        } catch {
            parseFailed = true
            self.error = "\(url.lastPathComponent): \(error)"
            reportReloadError()
        }
    }

    /// Called (once per distinct error) when the file stops parsing; the last good config stays live.
    var onReloadError: ((String) -> Void)? {
        didSet { reportReloadError() }
    }

    private func reportReloadError() {
        guard parseFailed, let e = error, e != lastReportedError, let cb = onReloadError else { return }
        lastReportedError = e
        cb("\(e) — using last good config")
    }

    /// Writes only what changed since the file was read (comments and ordering kept); a new file
    /// gets just the non-default keys. Never overwrites a file that doesn't parse.
    func saveNow() {
        saveWork?.cancel()
        guard persist, !isManaged else { return }
        let url = Paths.configFile
        if parseFailed {
            error = "\(url.lastPathComponent) has an error — fix config.toml first; changes in Settings aren't saved until then"
            return
        }
        let existing = try? String(contentsOf: url, encoding: .utf8)
        do {
            let text = try config.savedText(previous: saved, existing: existing)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if text != existing { try text.write(to: url, atomically: true, encoding: .utf8) }
            lastWritten = text
            saved = config
            watch()  // atomic writes replace the inode
        } catch let e as TOMLError {
            parseFailed = true
            error = "\(url.lastPathComponent): \(e) — fix config.toml first; changes aren't saved"
        } catch {
            self.error = "Couldn't save config: \(error.localizedDescription)"
        }
    }

    func reset() {
        config = Config()
        saveNow()
    }

    func revealInFinder() {
        if !FileManager.default.fileExists(atPath: Paths.configFile.path) { saveNow() }
        NSWorkspace.shared.activateFileViewerSelecting([Paths.configFile])
    }

    func openInEditor() {
        if !FileManager.default.fileExists(atPath: Paths.configFile.path) { saveNow() }
        NSWorkspace.shared.open(Paths.configFile)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    /// Watches the config directory (handles editors that replace files atomically).
    private func watch() {
        watcher?.cancel()
        let dir = Paths.configFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self?.load() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }
}

/// Persists label memory and click counts.
@MainActor
final class UsageKeeper {
    private(set) var store = UsageStore()
    private var dirty = false

    init() {
        if let data = try? Data(contentsOf: Paths.usageFile), let s = try? JSONDecoder().decode(UsageStore.self, from: data) {
            store = s
        }
    }

    func remember(_ labels: [String: String]) {
        store.remember(labels: labels)
        scheduleFlush()
    }

    func recordUse(_ key: String) {
        store.recordUse(key)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !dirty else { return }
        dirty = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.flush() }
    }

    func flush() {
        dirty = false
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(at: Paths.supportDir, withIntermediateDirectories: true)
        try? data.write(to: Paths.usageFile, options: .atomic)
    }
}
