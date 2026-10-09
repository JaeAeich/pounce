import AppKit
import ApplicationServices

/// Browser engines only build their accessibility tree when an assistive app asks for it:
/// - Chromium (Chrome, Brave, Edge, Arc, …): reading the app's AXRole turns it on.
/// - Electron: AXManualAccessibility.
/// - Gecko (Firefox, Zen, LibreWolf, Floorp, Thunderbird…): AXEnhancedUserInterface.
/// Safari/WebKit and native apps always expose theirs.
enum AppSupport {
    static let chromiumBundles: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "company.thebrowser.dia", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "ai.perplexity.comet", "com.openai.atlas", "net.imput.helium", "com.yandex.desktop.yandex-browser",
    ]

    enum Engine { case chromium, electron, gecko, other }

    private static let lock = NSLock()
    private static var enabled: [pid_t: Date] = [:]
    /// pid → engine; the bundle never changes for a running process.
    private static var engines: [pid_t: Engine] = [:]

    static func isElectron(_ app: NSRunningApplication) -> Bool { engine(app) == .electron }

    static func engine(_ app: NSRunningApplication) -> Engine {
        let pid = app.processIdentifier
        lock.lock()
        let cached = engines[pid]
        lock.unlock()
        if let cached { return cached }
        var e = Engine.other
        if chromiumBundles.contains(app.bundleIdentifier ?? "") {
            e = .chromium
        } else if let url = app.bundleURL {  // disk checks once per process
            let fm = FileManager.default
            if fm.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) {
                e = .electron
            } else if fm.fileExists(atPath: url.appendingPathComponent("Contents/MacOS/XUL").path) {
                e = .gecko
            } else if let fw = try? fm.contentsOfDirectory(atPath: url.appendingPathComponent("Contents/Frameworks").path),
                fw.contains(where: { $0.hasSuffix(" Framework.framework") && ($0.contains("Chrom") || $0.contains("Browser")) })
            {
                e = .chromium  // unlisted Chromium browsers ("Foo Browser Framework.framework")
            }
        }
        lock.lock()
        engines[pid] = e
        lock.unlock()
        return e
    }

    /// Turns on the app's accessibility tree. Returns true if this is the first time
    /// for this process and the tree may need a moment to build.
    @discardableResult
    static func prepare(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        let e = engine(app)
        guard e != .other else { return false }
        let ax = AXUIElement.app(pid)
        ax.setTimeout(0.25)  // runs on the hotkey path; never stall on a busy app
        lock.lock()
        let first = enabled[pid] == nil
        enabled[pid] = Date()
        lock.unlock()
        // Apple's recommended activation signal for non-VoiceOver AT; Chromium listens for it.
        // Cheap and a no-op once on, so repeat it in case the app dropped accessibility.
        _ = ax.string("AXRole")
        guard first else { return false }
        switch e {
        case .chromium, .electron:
            // Electron (and older Chromium). AXEnhancedUserInterface is deliberately not set for
            // Chromium: it only honours it after 2 s without changes, and it slows window managers.
            ax.set("AXManualAccessibility", kCFBooleanTrue)
        case .gecko:
            // Gecko's only switch. Set once per process: toggling it is what slows window moves.
            ax.set("AXEnhancedUserInterface", kCFBooleanTrue)
        case .other:
            break
        }
        return true
    }
}
