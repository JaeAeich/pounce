import AppKit
import Carbon.HIToolbox
import ServiceManagement

enum Sound {
    static var enabled = true
    private static let click: NSSound? = {
        let s = NSSound(named: "Pop")
        s?.volume = 0.25
        return s
    }()
    private static let warn: NSSound? = {
        let s = NSSound(named: "Funk")
        s?.volume = 0.3
        return s
    }()

    static func playClick() { play(click) }
    static func playWarn() { play(warn) }

    private static func play(_ s: NSSound?) {
        guard enabled, let s else { return }
        s.stop()
        s.play()
    }
}

enum Permissions {
    static var accessibility: Bool { AX.isTrusted }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// First time: the system prompt (which offers to open Settings itself). After that: just the pane,
    /// so the prompt and System Settings never pop up together.
    static func openAccessibilitySettings() {
        let key = "accessibilityPrompted"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            AX.promptForTrust()
            return
        }
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }

    private static func open(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
}

enum LoginItem {
    /// On, or registered but waiting for the user to allow it in System Settings › Login Items.
    static var isEnabled: Bool { [.enabled, .requiresApproval].contains(SMAppService.mainApp.status) }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Launchd-managed installs (nix-darwin / home-manager) already start at login. Their agents set
    /// POUNCE_LAUNCHD=1; older ones are recognised by the agent label. Note every app launched from
    /// Finder/`open` also has XPC_SERVICE_NAME ("application.<bundle id>.…"), so that alone means nothing.
    static var managedByLaunchd: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["POUNCE_LAUNCHD"] == "1" { return true }
        guard let name = env["XPC_SERVICE_NAME"], !name.hasPrefix("application.") else { return false }
        return name.lowercased().contains("pounce")
    }

    static func set(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
            if needsApproval { SMAppService.openSystemSettingsLoginItems() }
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Commands accepted from the CLI (`pounce hint`) and URL scheme (`pounce://hint`).
/// Fast path: a Mach message port (direct, ~0.1 ms, no distnoted round-trip); the distributed
/// notification stays as a fallback for older running instances.
///
/// Request/response (`pounce status`, `doctor`, `login`): the CLI opens its own uniquely named
/// local port and sends msgid 1 with "<reply port>\n<command>"; the app answers by sending the
/// text to that port whenever it's ready (doctor scans asynchronously), so no temp files.
enum IPC {
    static let notification = Notification.Name("com.jaeaeich.pounce.command")
    static let bundleID = "com.jaeaeich.pounce"
    static let portName = "com.jaeaeich.pounce.ipc" as CFString
    static let requestMsgID: Int32 = 1

    typealias Reply = (String) -> Void

    private nonisolated(unsafe) static var handler: ((String, Reply?) -> Void)?
    private nonisolated(unsafe) static var localPort: CFMessagePort?

    static func send(_ command: String) {
        if let port = CFMessagePortCreateRemote(nil, portName), let data = command.data(using: .utf8) {
            if CFMessagePortSendRequest(port, 0, data as CFData, 1, 0, nil, nil) == kCFMessagePortSuccess { return }
        }
        DistributedNotificationCenter.default().postNotificationName(notification, object: command, userInfo: nil, deliverImmediately: true)
    }

    private nonisolated(unsafe) static var replyText: String?

    /// Sends `command` and waits up to `timeout` for the app's answer (nil: not running / no answer).
    static func request(_ command: String, timeout: TimeInterval = 5) -> String? {
        guard let remote = CFMessagePortCreateRemote(nil, portName) else { return nil }
        let name = "com.jaeaeich.pounce.reply.\(getpid()).\(UUID().uuidString)" as CFString
        replyText = nil
        guard
            let local = CFMessagePortCreateLocal(
                nil, name,
                { _, _, data, _ in
                    IPC.replyText = data.flatMap { String(data: $0 as Data, encoding: .utf8) } ?? ""
                    CFRunLoopStop(CFRunLoopGetCurrent())
                    return nil
                }, nil, nil),
            let src = CFMessagePortCreateRunLoopSource(nil, local, 0)
        else { return nil }
        defer { CFMessagePortInvalidate(local) }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .defaultMode)
        guard let data = "\(name)\n\(command)".data(using: .utf8),
            CFMessagePortSendRequest(remote, requestMsgID, data as CFData, 1, 0, nil, nil) == kCFMessagePortSuccess
        else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while replyText == nil, Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, deadline.timeIntervalSinceNow, true)
        }
        return replyText
    }

    /// Answers a request: the reply port is the requester's own local port.
    static func reply(to port: String, _ text: String) {
        guard let remote = CFMessagePortCreateRemote(nil, port as CFString), let data = text.data(using: .utf8) else { return }
        CFMessagePortSendRequest(remote, 0, data as CFData, 2, 0, nil, nil)
    }

    static func listen(_ handler: @escaping (String) -> Void) {
        listen { cmd, _ in handler(cmd) }
    }

    /// Like `listen(_:)`, but the handler also gets a reply callback for request/response commands.
    /// Calling it again only swaps the handler (the port and notification observer stay).
    static func listen(replying handler: @escaping (String, Reply?) -> Void) {
        let first = IPC.handler == nil
        IPC.handler = handler
        guard first else { return }
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { n in
            if let c = n.object as? String { IPC.handler?(c, nil) }
        }
        guard localPort == nil,
            let port = CFMessagePortCreateLocal(
                nil, portName,
                { _, msgid, data, _ in
                    guard let data, let text = String(data: data as Data, encoding: .utf8) else { return nil }
                    if msgid == IPC.requestMsgID, let nl = text.firstIndex(of: "\n") {
                        let replyPort = String(text[..<nl])
                        IPC.handler?(String(text[text.index(after: nl)...])) { IPC.reply(to: replyPort, $0) }
                    } else {
                        IPC.handler?(text, nil)
                    }
                    return nil
                }, nil, nil),
            let src = CFMessagePortCreateRunLoopSource(nil, port, 0)
        else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        localPort = port
    }

    static var otherInstanceRunning: Bool {
        // A live port means a running instance (and is ~10× cheaper than asking LaunchServices).
        if let p = CFMessagePortCreateRemote(nil, portName), CFMessagePortIsValid(p) { return true }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != getpid() }
    }
}

/// "1.2.3 (abc1234)" when the build stamped Info.plist's PounceGitCommit, else just the version.
var appVersionWithCommit: String {
    let commit = (Bundle.main.infoDictionary?["PounceGitCommit"] as? String)
        .flatMap { $0.isEmpty || $0.hasPrefix("@") || $0 == "unknown" ? nil : String($0.prefix(12)) }
    return commit.map { "\(appVersion) (\($0))" } ?? appVersion
}

extension Notification.Name {
    /// Posted (main queue, object nil, userInfo ["paused": Bool]) whenever AppController.paused
    /// changes — menu, Settings, CLI or URL. The menu bar icon refreshes on it.
    static let pouncePausedChanged = Notification.Name("PouncePausedChanged")
}

/// Pause survives relaunches. A separate suite so the CLI (any binary) and the app agree.
enum PauseState {
    private static let defaults = UserDefaults(suiteName: "com.jaeaeich.pounce.state") ?? .standard
    static var persisted: Bool {
        get { defaults.bool(forKey: "paused") }
        set { defaults.set(newValue, forKey: "paused") }
    }
}
