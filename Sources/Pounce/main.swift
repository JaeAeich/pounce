import AppKit
import Combine
import PounceCore

let usage = """
    Pounce – keyboard-driven clicking for macOS

    Usage: pounce [command]

      (no command)        start Pounce (menu bar app)
      hint | click        toggle click mode
      scroll              toggle scroll mode
      grid                toggle grid mode
      windows             toggle window switcher
      menu                toggle menu search
      text                toggle text (OCR) mode
      repeat              repeat the last action
      settings            open Settings
      welcome             open the welcome / permissions window
      cheatsheet          open the key cheat sheet
      pause | resume      pause or resume global shortcuts
      toggle              pause if running, resume if paused
      status              show permissions, tap, pause, login item, config state
      reload              reload the config file
      quit                quit the running app

      config path         print the config file path
      config init         write a starter config file (if none exists)
      config check        validate the config file
      config show         print the full effective config as TOML
      config diff         list settings that differ from the preset
      config export [f]   write your non-default settings to f (default: stdout)
      config import <f>   validate f and make it your config (old one kept as .bak)
      config edit         open the config file in $EDITOR (or the default text editor)
      config reset        back up the config file and start from defaults
      import <app> [file] [--apply]
                          import settings from homerow | shortcat | vimium <file> | mouseless
                          (prints what would change; --apply writes it)
      login on|off|status open Pounce at login
      doctor [bundle-id]  diagnose scanning of an app (default: frontmost)
      selftest            run end-to-end checks (prints results, exit 1 on failure)
      bench [runs]        time AX scans of heavy in-process fixture windows
      snapshot <dir>      render every UI surface to PNG files
      version             print the version

    Presets: [general] preset = "homerow" | "shortcat" | "vimium" | "mouseless" | "scoot"
    URL scheme: open pounce://hint (modes, settings, cheatsheet, welcome only).
    """

// Run via a symlink (Homebrew `binary`), Bundle.main misses the .app: re-exec the real path.
if Bundle.main.bundleURL.pathExtension != "app", let exe = Bundle.main.executablePath {
    let real = URL(fileURLWithPath: exe).resolvingSymlinksInPath().path
    if real != exe, real.contains(".app/Contents/MacOS/") {
        execv(real, ([real] + CommandLine.arguments.dropFirst()).map { strdup($0) } + [nil])
    }
}

let args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
let command = args.first?.lowercased()

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func requireRunning() {
    guard IPC.otherInstanceRunning else { fail("Pounce isn't running. Start it first: open -a Pounce") }
}

/// Asks the running app and prints its answer; answers starting with "error:" exit 1.
func ask(_ cmd: String, timeout: TimeInterval = 5) -> Never {
    requireRunning()
    guard let r = IPC.request(cmd, timeout: timeout) else {
        fail("no answer from Pounce after \(Int(timeout)) s (an older running version? restart it)")
    }
    if r.hasPrefix("error:") { fail(r.trimmingCharacters(in: .newlines)) }
    print(r, terminator: r.hasSuffix("\n") ? "" : "\n")
    exit(0)
}

/// Reads the config file: (text, parsed config). Missing file → (nil, defaults). Syntax error → exit.
func readConfig(_ url: URL = Paths.configFile) -> (text: String?, config: Config, warnings: [String]) {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (nil, Config(), []) }
    do {
        let (c, w) = try Config.parse(text)
        return (text, c, w)
    } catch {
        fail("error: \(url.lastPathComponent) \(error) — fix it first (pounce config edit)")
    }
}

func writeConfig(_ text: String, to url: URL = Paths.configFile) {
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    } catch {
        fail("couldn't write \(url.path): \(error.localizedDescription)")
    }
}

func backupConfig(_ url: URL = Paths.configFile) -> URL? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let bak = url.appendingPathExtension("bak")
    try? FileManager.default.removeItem(at: bak)
    do { try FileManager.default.copyItem(at: url, to: bak) } catch { fail("couldn't back up \(url.path): \(error.localizedDescription)") }
    return bak
}

func runTool(_ path: String, _ arguments: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func configCommand(_ sub: String, _ rest: [String]) -> Never {
    let url = Paths.configFile
    switch sub {
    case "path":
        print(url.path)
    case "init":
        if FileManager.default.fileExists(atPath: url.path) { fail("\(url.path) already exists") }
        writeConfig(Config().toTOML(), to: url)
        print("Wrote \(url.path)")
    case "check", "show":
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            if sub == "show" { print(Config().toTOML()) } else { print("No config file at \(url.path) – using defaults.") }
            exit(0)
        }
        do {
            let (c, warnings) = try Config.parse(text)
            if sub == "show" {
                print(c.toTOML())
            } else {
                for w in warnings { print("warning: \(w)") }
                print(warnings.isEmpty ? "✓ \(url.path) is valid" : "\(warnings.count) warning(s); defaults used for those keys")
            }
            exit(warnings.isEmpty || sub == "show" ? 0 : 2)
        } catch {
            fail("error: \(url.lastPathComponent) \(error)")
        }
    case "diff":
        let c = readConfig(url).config
        let base = Dictionary(c.general.preset.baseline.flattened().map { ($0.path, $0.value) }, uniquingKeysWith: { a, _ in a })
        let o = c.overrides()
        if o.isEmpty { print("No differences from the \(c.general.preset.rawValue) preset.") }
        for e in o {
            let was = e.path == Config.presetPath ? "\"homerow\"" : base[e.path].map(TOML.serialize) ?? "–"
            print("\(e.path.map(TOML.key).joined(separator: ".")) = \(TOML.serialize(e.value))   (default \(was))")
        }
    case "export":
        let c = readConfig(url).config
        let full = rest.contains("--full")
        let text = full ? c.toTOML() : c.overridesTOML()
        if let f = rest.first(where: { !$0.hasPrefix("--") }) {
            writeConfig(text, to: URL(fileURLWithPath: (f as NSString).expandingTildeInPath))
            print("Wrote \(f)")
        } else {
            print(text, terminator: "")
        }
    case "import":
        guard let f = rest.first else { fail("usage: pounce config import <file>") }
        let src = URL(fileURLWithPath: (f as NSString).expandingTildeInPath)
        guard let text = try? String(contentsOf: src, encoding: .utf8) else { fail("can't read \(src.path)") }
        do {
            let (_, w) = try Config.parse(text)
            for x in w { print("warning: \(x)") }
        } catch {
            fail("error: \(src.lastPathComponent) \(error) — not imported")
        }
        let bak = backupConfig(url)
        writeConfig(text, to: url)
        print("Imported \(src.path) → \(url.path)" + (bak.map { " (previous: \($0.path))" } ?? ""))
    case "edit":
        if !FileManager.default.fileExists(atPath: url.path) { writeConfig(Config().overridesTOML(), to: url) }
        let env = ProcessInfo.processInfo.environment
        if let ed = (env["VISUAL"] ?? env["EDITOR"]).flatMap({ $0.isEmpty ? nil : $0 }) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "\(ed) \"$1\"", "sh", url.path]
            do { try p.run() } catch { fail("couldn't run \(ed): \(error.localizedDescription)") }
            p.waitUntilExit()
            exit(p.terminationStatus)
        }
        exit(runTool("/usr/bin/open", ["-t", url.path]).status)
    case "reset":
        let bak = backupConfig(url)
        writeConfig(Config().overridesTOML(), to: url)
        print("Reset \(url.path) to defaults" + (bak.map { " (previous: \($0.path))" } ?? ""))
    default:
        fail("unknown config command '\(sub)'\n\n\(usage)")
    }
    exit(0)
}

func importCommand(_ rest: [String]) -> Never {
    let apply = rest.contains("--apply")
    let pos = rest.filter { !$0.hasPrefix("--") }
    guard let name = pos.first?.lowercased(), let source = ImportSource(rawValue: name == "vimiumc" || name == "vimium-c" ? "vimium" : name)
    else {
        fail("usage: pounce import homerow|shortcat|vimium <options.json>|mouseless [file] [--apply]")
    }
    let file = pos.dropFirst().first.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    let text: String
    let origin: String
    do { (text, origin) = try ImportFlow.locate(source, file: file) } catch { fail("\(error.localizedDescription)") }

    let current = readConfig()
    let result: ImportResult
    do { result = try Importers.run(source, text: text, onto: current.config) } catch { fail("can't read \(origin): \(error)") }
    print("Import from \(source.rawValue) (\(origin)):")
    if result.changes.isEmpty { print("  nothing to change") }
    for c in result.changes { print("  \(c.key): \(c.from) → \(c.to)   (from \(c.source))") }
    if !result.unmapped.isEmpty {
        print("\nNot imported:")
        for u in result.unmapped { print("  - \(u)") }
    }
    guard apply else {
        if !result.changes.isEmpty { print("\nRun again with --apply to write these to \(Paths.configFile.path).") }
        exit(0)
    }
    guard !result.changes.isEmpty else { exit(0) }
    do {
        let out = try result.config.savedText(previous: current.config, existing: current.text)
        writeConfig(out)
        print("\nWrote \(Paths.configFile.path)" + (IPC.otherInstanceRunning ? " (Pounce reloads it automatically)" : ""))
    } catch {
        fail("error: \(error)")
    }
    exit(0)
}

/// Commands the app runs on request; everything else is forwarded fire-and-forget.
let replyCommands: Set = ["status", "pause", "resume", "toggle", "reload", "repeat", "overlayshot"]

switch command {
case nil:
    if IPC.otherInstanceRunning {
        IPC.send("settings")
        exit(0)
    }
case "help", "--help", "-h":
    print(usage)
    exit(0)
case "version", "--version", "-v":
    print(appVersionWithCommit)
    exit(0)
case "config":
    configCommand(args.dropFirst().first?.lowercased() ?? "path", Array(args.dropFirst(2)))
case "import":
    importCommand(Array(args.dropFirst()))
case "status":
    if IPC.otherInstanceRunning, let r = IPC.request("status", timeout: 3) {
        print(r, terminator: "")
        exit(0)
    }
    // Not running (or an older build without status): report what the CLI can see itself.
    let url = Paths.configFile
    var cfg = "no file (defaults)", preset = "homerow"
    if let text = try? String(contentsOf: url, encoding: .utf8) {
        do {
            let (c, w) = try Config.parse(text)
            cfg = w.isEmpty ? "valid" : "\(w.count) warning(s)"
            preset = c.general.preset.rawValue
        } catch { cfg = "error: \(error)" }
    }
    print("running: \(IPC.otherInstanceRunning ? "yes (older version, no status support)" : "no")")
    print("version: \(appVersionWithCommit)")
    print("secure input: \(SecureInput.isEnabled ? "ON" : "off")")
    print("config: \(url.path) (\(cfg))")
    print("preset: \(preset)")
    exit(IPC.otherInstanceRunning ? 0 : 3)
case "doctor":
    // The running app has Accessibility; it scans and sends back a report.
    ask((["doctor"] + args.dropFirst()).joined(separator: " "), timeout: 20)
case "login":
    ask((["login"] + args.dropFirst()).joined(separator: " "))
case "selftest", "snapshot", "bench":
    break  // run in-process below
default:
    let known = [
        "hint", "click", "scroll", "grid", "windows", "window", "menu", "text", "settings", "preferences", "welcome", "cheatsheet", "cheat",
        "keys", "keytest", "overlayshot", "onboarding", "pause", "resume", "toggle", "repeat", "reload", "quit",
    ]
    guard let cmd = command, known.contains(cmd) else { fail("unknown command '\(command ?? "")'\n\n\(usage)") }
    if IPC.otherInstanceRunning {
        if replyCommands.contains(cmd) {
            // Older running builds don't answer requests: fall back to a plain send.
            if let r = IPC.request(cmd, timeout: 3) { print(r, terminator: "") } else { IPC.send(cmd) }
        } else {
            IPC.send(cmd)
        }
        exit(0)
    }
    if cmd == "quit" { exit(0) }
    if cmd == "pause" || cmd == "resume" || cmd == "toggle" {
        // Not running: just record the state the app picks up at launch.
        let now = cmd == "toggle" ? !PauseState.persisted : cmd == "pause"
        PauseState.persisted = now
        print(now ? "paused (applies when Pounce starts)" : "resumed (applies when Pounce starts)")
        exit(0)
    }
    // Not running: start the app and hand over the command once it's up.
    guard Bundle.main.bundleURL.pathExtension == "app" else { fail("Pounce isn't running. Start it first: open -a Pounce") }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = false
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in }
    for _ in 0..<50 where !IPC.otherInstanceRunning { usleep(100_000) }
    usleep(800_000)
    IPC.send(cmd)
    exit(0)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: AppController!
    var statusMenu: StatusMenu!
    private var pausedSub: AnyCancellable?

    func applicationDidFinishLaunching(_ n: Notification) {
        MainActor.assumeIsolated {
            NSApp.applicationIconImage = renderIcon(size: 512)
            installMainMenu()
            if command == "selftest" { return runHeadlessSelfTest() }
            if command == "bench" { return Bench(runs: Int(args.dropFirst().first ?? "") ?? 7).run { exit(0) } }
            if command == "snapshot" { return runSnapshot(args.dropFirst().first ?? "snapshots") }

            controller = AppController()
            controller.paused = PauseState.persisted
            controller.startup()
            let c = controller!
            // Replace startup's handler with one that can answer CLI requests (status, doctor…).
            IPC.listen(replying: { [weak c] cmd, reply in c?.run(command: cmd, reply: reply) })
            controller.store.onReloadError = { [weak c] msg in c?.overlay.model.flash(msg) }
            statusMenu = StatusMenu(app: controller)
            // Every pause change (menu, Settings, CLI): persist, refresh the icon, tell observers.
            // @Published fires before the value is stored, hence the async hop.
            pausedSub = controller.$paused.dropFirst().removeDuplicates().sink { [weak self] p in
                PauseState.persisted = p
                DispatchQueue.main.async {
                    self?.statusMenu.refreshIcon()
                    NotificationCenter.default.post(name: .pouncePausedChanged, object: nil, userInfo: ["paused": p])
                }
            }
            NSAppleEventManager.shared().setEventHandler(
                self, andSelector: #selector(handleURL(_:reply:)), forEventClass: AEEventClass(kInternetEventClass),
                andEventID: AEEventID(kAEGetURL))
            if !AX.isTrusted || !UserDefaults.standard.bool(forKey: "onboarded") {
                WindowManager.shared.showOnboarding(controller)
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        MainActor.assumeIsolated { controller?.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { if let c = controller { WindowManager.shared.showSettings(c) } }
        return true
    }

    /// Any web page can open pounce:// links, so only harmless commands are accepted here:
    /// toggling a mode and showing Pounce's own windows. quit/pause/reload/doctor/login etc. are CLI-only.
    static let urlCommands: Set = ["click", "window", "settings", "preferences", "cheatsheet", "cheat", "keys", "welcome", "onboarding"]

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        let cmd = (url.host ?? url.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        MainActor.assumeIsolated {
            guard ModeKind(rawValue: cmd) != nil || Self.urlCommands.contains(cmd) else {
                log.info("ignored pounce:// URL command \(cmd, privacy: .public)")
                return
            }
            controller.run(command: cmd)
        }
    }

    @MainActor private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Pounce", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Pounce", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Pounce", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.mainMenu = main
    }

    @MainActor private func runHeadlessSelfTest() {
        let runner = SelfTest(app: nil)
        runner.run {
            for r in runner.results {
                let mark = r.status == .pass ? "✓" : r.status == .fail ? "✗" : "–"
                print("\(mark) \(r.name): \(r.detail)")
            }
            let passed = runner.results.filter { $0.status == .pass }.count
            print("\n\(passed) passed, \(runner.failed) failed, \(runner.results.count - passed - runner.failed) skipped")
            exit(runner.failed == 0 ? 0 : 1)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
