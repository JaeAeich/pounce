import AppKit
import PounceCore

/// Finds another tool's settings and imports them (shared by `pounce import` and Settings › Import from…).
enum ImportFlow {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The tool's settings text and where it came from. `file` overrides the default location.
    static func locate(_ source: ImportSource, file: URL?) throws -> (text: String, origin: String) {
        if let file {
            guard let t = try? String(contentsOf: file, encoding: .utf8) else { throw Failure(message: "Can't read \(file.path).") }
            return (t, file.path)
        }
        if let domain = source.defaultsDomain {
            let r = runTool("/usr/bin/defaults", ["export", domain, "-"])
            guard r.status == 0, !r.out.isEmpty else {
                throw Failure(message: "No \(source.rawValue.capitalized) settings found on this Mac.")
            }
            return (r.out, "defaults \(domain)")
        }
        if source == .mouseless {
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            var candidates: [URL] = []
            let support = home.appendingPathComponent("Library/Application Support/Mouseless")
            for f in (try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? []
            where ["yaml", "yml"].contains(f.pathExtension) {
                candidates.append(f)
            }
            candidates.append(home.appendingPathComponent(".mouseless/configs/config.yaml"))
            let containers = home.appendingPathComponent("Library/Containers")
            for c in (try? fm.contentsOfDirectory(atPath: containers.path)) ?? [] where c.lowercased().contains("mouseless") {
                candidates.append(containers.appendingPathComponent(c).appendingPathComponent("Data/.mouseless/configs/config.yaml"))
            }
            guard let f = candidates.first(where: { fm.fileExists(atPath: $0.path) }), let t = try? String(contentsOf: f, encoding: .utf8)
            else {
                throw Failure(message: "No Mouseless config found on this Mac.")
            }
            return (t, f.path)
        }
        throw Failure(message: "Vimium settings come from its options file: Vimium › Options › Backup and Restore › Backup.")
    }

    /// Settings UI entry point: imports into the config file (the running app hot-reloads it) and
    /// returns a one-line summary. Vimium asks for its exported options file.
    @MainActor
    static func run(_ tool: String) throws -> String {
        guard let source = ImportSource(rawValue: tool) else { throw Failure(message: "Unknown app \(tool).") }
        var file: URL?
        if source == .vimium {
            let panel = NSOpenPanel()
            panel.message = "Choose the file from Vimium › Options › Backup and Restore › Backup."
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return "Import cancelled." }
            file = url
        }
        let (text, _) = try locate(source, file: file)
        let url = Paths.configFile
        let existing = try? String(contentsOf: url, encoding: .utf8)
        let current = try existing.map { try Config.parse($0).0 } ?? Config()
        let result = try Importers.run(source, text: text, onto: current)
        guard !result.changes.isEmpty else { return "Nothing to import from \(source.rawValue.capitalized)." }
        let out = try result.config.savedText(previous: current, existing: existing)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: url, atomically: true, encoding: .utf8)
        let n = result.changes.count
        return "Imported \(n) setting\(n == 1 ? "" : "s") from \(source.rawValue.capitalized)."
    }

    static func runTool(_ path: String, _ arguments: [String]) -> (status: Int32, out: String) {
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
}
