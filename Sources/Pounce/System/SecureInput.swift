import AppKit
import Carbon.HIToolbox
import IOKit

/// Secure Event Input (password fields, some terminals / password managers) blocks event taps from
/// seeing keystrokes, so Pounce shortcuts silently stop working while it's on.
enum SecureInput {
    /// True while any process has Secure Event Input enabled.
    static var isEnabled: Bool { IsSecureEventInputEnabled() }

    /// PID holding Secure Input, from the console session (`IOConsoleUsers` → `kCGSSessionSecureInputPID`).
    /// nil when off or unknown.
    static var holderPID: pid_t? {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/")
        guard root != MACH_PORT_NULL else { return nil }
        defer { IOObjectRelease(root) }
        guard
            let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [[String: Any]]
        else { return nil }
        for u in users {
            if let pid = (u["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, pid > 0 { return pid }
        }
        return nil
    }

    /// Display name of the holder ("Terminal", or "pid 123" if it isn't a regular app).
    static var holderName: String? {
        guard let pid = holderPID else { return nil }
        if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName { return n }
        var buf = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "pid \(pid)"
    }

    /// One-line status, e.g. "on (held by Terminal)" / "off".
    static var summary: String {
        guard isEnabled else { return "off" }
        return holderName.map { "on (held by \($0))" } ?? "on"
    }
}
