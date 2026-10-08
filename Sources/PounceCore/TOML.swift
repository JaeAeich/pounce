import Foundation

/// Minimal TOML subset: comments, [tables], [a."quoted.key"], key = string | int | float | bool | [array].
/// Enough for Pounce's config; not a general-purpose TOML implementation.
public enum TOMLValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var table: [String: TOMLValue]? { if case .table(let t) = self { t } else { nil } }
    public var double: Double? {
        switch self {
        case .double(let d): d
        case .int(let i): Double(i)
        default: nil
        }
    }
    public var int: Int? {
        switch self {
        case .int(let i): i
        case .double(let d) where d.rounded() == d: Int(d)
        default: nil
        }
    }
    public var strings: [String]? {
        guard case .array(let a) = self else { return nil }
        let s = a.compactMap(\.string)
        return s.count == a.count ? s : nil
    }
}

public struct TOMLError: Error, Equatable, CustomStringConvertible {
    public var line: Int
    public var message: String
    public var description: String { "line \(line): \(message)" }
}

public enum TOML {
    public static func parse(_ text: String) throws -> [String: TOMLValue] {
        var root: [String: TOMLValue] = [:]
        var path: [String] = []
        // Split on Characters so "\r\n" counts as one line break (keeps line numbers right).
        for (n, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let lineNo = n + 1
            var p = Parser(Array(rawLine), line: lineNo)
            p.skipSpace()
            if p.atEnd || p.peek == "#" { continue }
            if p.peek == "[" {
                p.advance()
                path = try p.keyPath(until: "]")
                try p.expect("]")
                try p.endOfLine()
                try ensureTable(&root, path, line: lineNo)
                continue
            }
            let keys = try p.keyPath(until: "=")
            try p.expect("=")
            p.skipSpace()
            let value = try p.value()
            try p.endOfLine()
            try insert(&root, path + keys, value, line: lineNo)
        }
        return root
    }

    private static func ensureTable(_ t: inout [String: TOMLValue], _ path: [String], line: Int) throws {
        guard let first = path.first else { return }
        var sub = t[first]?.table ?? [:]
        if let existing = t[first], existing.table == nil {
            throw TOMLError(line: line, message: "'\(first)' is not a table")
        }
        try ensureTable(&sub, Array(path.dropFirst()), line: line)
        t[first] = .table(sub)
    }

    private static func insert(_ t: inout [String: TOMLValue], _ path: [String], _ v: TOMLValue, line: Int) throws {
        if path.count == 1 {
            if t[path[0]] != nil { throw TOMLError(line: line, message: "duplicate key '\(path[0])'") }
            t[path[0]] = v
            return
        }
        var sub = t[path[0]]?.table ?? [:]
        if let existing = t[path[0]], existing.table == nil {
            throw TOMLError(line: line, message: "'\(path[0])' is not a table")
        }
        try insert(&sub, Array(path.dropFirst()), v, line: line)
        t[path[0]] = .table(sub)
    }

    // MARK: Serialization helpers

    public static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    public static func key(_ k: String) -> String {
        let bare = !k.isEmpty && k.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        return bare ? k : quote(k)
    }

    public static func format(_ d: Double) -> String {
        d.rounded() == d && abs(d) < 1e15 ? String(format: "%.1f", d) : String(d)
    }
}

private struct Parser {
    var chars: [Character]
    var i = 0
    let line: Int
    init(_ chars: [Character], line: Int) {
        self.chars = chars
        self.line = line
    }

    var atEnd: Bool { i >= chars.count }
    var peek: Character? { atEnd ? nil : chars[i] }
    mutating func advance() { i += 1 }
    mutating func skipSpace() { while let c = peek, c == " " || c == "\t" { advance() } }
    func fail(_ m: String) -> TOMLError { TOMLError(line: line, message: m) }

    mutating func expect(_ c: Character) throws {
        skipSpace()
        guard peek == c else { throw fail("expected '\(c)'") }
        advance()
    }

    mutating func endOfLine() throws {
        skipSpace()
        if atEnd || peek == "#" { return }
        throw fail("unexpected '\(peek!)'")
    }

    mutating func keyPath(until end: Character) throws -> [String] {
        var keys: [String] = []
        while true {
            skipSpace()
            if peek == "\"" {
                keys.append(try quoted())
            } else {
                var k = ""
                while let c = peek, c.isLetter || c.isNumber || c == "_" || c == "-" {
                    k.append(c)
                    advance()
                }
                if k.isEmpty { throw fail("expected key") }
                keys.append(k)
            }
            skipSpace()
            if peek == "." {
                advance()
                continue
            }
            if peek == end { return keys }
            throw fail("expected '\(end)'")
        }
    }

    mutating func quoted() throws -> String {
        advance()  // opening quote
        var s = ""
        while let c = peek {
            advance()
            if c == "\"" { return s }
            if c == "\\" {
                guard let e = peek else { break }
                advance()
                switch e {
                case "n": s.append("\n")
                case "t": s.append("\t")
                case "\"": s.append("\"")
                case "\\": s.append("\\")
                default: throw fail("bad escape '\\\(e)'")
                }
            } else {
                s.append(c)
            }
        }
        throw fail("unterminated string")
    }

    mutating func value() throws -> TOMLValue {
        skipSpace()
        guard let c = peek else { throw fail("expected value") }
        if c == "\"" { return .string(try quoted()) }
        if c == "[" {
            advance()
            var items: [TOMLValue] = []
            while true {
                skipSpace()
                if peek == "]" {
                    advance()
                    return .array(items)
                }
                items.append(try value())
                skipSpace()
                if peek == "," {
                    advance()
                    continue
                }
                if peek == "]" {
                    advance()
                    return .array(items)
                }
                throw fail("expected ',' or ']' in array")
            }
        }
        var word = ""
        while let c = peek, !(c == "," || c == "]" || c == "#" || c == " " || c == "\t") {
            word.append(c)
            advance()
        }
        switch word {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default:
            let w = word.replacingOccurrences(of: "_", with: "")
            if let i = Int(w) { return .int(i) }
            if let d = Double(w) { return .double(d) }
            throw fail("invalid value '\(word)'")
        }
    }
}

// MARK: - Serialization of values

extension TOML {
    /// Inline TOML for a value (tables aren't inline-serializable here and yield "{}").
    public static func serialize(_ v: TOMLValue) -> String {
        switch v {
        case .string(let s): quote(s)
        case .int(let i): String(i)
        case .double(let d): format(d)
        case .bool(let b): b ? "true" : "false"
        case .array(let a): "[" + a.map(serialize).joined(separator: ", ") + "]"
        case .table: "{}"
        }
    }

    /// Value equality that treats `20` and `20.0` as the same.
    public static func equivalent(_ a: TOMLValue?, _ b: TOMLValue?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (.some(let x), .some(let y)):
            if case .array(let xs) = x, case .array(let ys) = y {
                return xs.count == ys.count && zip(xs, ys).allSatisfy { equivalent($0, $1) }
            }
            if case .bool = x { return x == y }
            if case .string = x { return x == y }
            if let dx = x.double, let dy = y.double { return dx == dy }
            return x == y
        default: return false
        }
    }
}

// MARK: - Comment-preserving document editing

/// A TOML file as lines, editable key by key. Comments, blank lines, ordering and formatting of
/// untouched lines are kept verbatim; edited values keep their trailing comment.
public struct TOMLDocument: Sendable, Equatable {
    public var lines: [String]

    public struct Entry: Sendable, Equatable {
        /// Full path: table path + key path.
        public var path: [String]
        public var table: [String]
        public var line: Int
        public var value: TOMLValue
        /// Character offsets of the value text within the line.
        var valueStart: Int
        var valueEnd: Int
    }

    struct Header: Equatable {
        var path: [String]
        var line: Int
    }

    /// Throws on syntax errors (same rules as `TOML.parse`).
    public init(_ text: String) throws {
        _ = try TOML.parse(text)
        var ls = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if ls.last == "" { ls.removeLast() }
        lines = ls
    }

    public var text: String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }

    func scan() -> (entries: [Entry], headers: [Header]) {
        var entries: [Entry] = []
        var headers: [Header] = []
        var table: [String] = []
        for (n, raw) in lines.enumerated() {
            var p = Parser(Array(raw), line: n + 1)
            p.skipSpace()
            if p.atEnd || p.peek == "#" { continue }
            if p.peek == "[" {
                p.advance()
                guard let path = try? p.keyPath(until: "]") else { continue }
                table = path
                headers.append(Header(path: path, line: n))
                continue
            }
            guard let keys = try? p.keyPath(until: "="), (try? p.expect("=")) != nil else { continue }
            p.skipSpace()
            let start = p.i
            guard let v = try? p.value() else { continue }
            entries.append(Entry(path: table + keys, table: table, line: n, value: v, valueStart: start, valueEnd: p.i))
        }
        return (entries, headers)
    }

    /// Key/value pairs in file order.
    public var entries: [Entry] { scan().entries }

    public func value(_ path: [String]) -> TOMLValue? { entries.first { $0.path == path }?.value }

    /// Sets `path` (last component is the key). Existing lines are edited in place; new keys go
    /// after the last key of their table, creating `[table]` at the end of the file if needed.
    public mutating func set(_ path: [String], _ v: TOMLValue) {
        guard let key = path.last else { return }
        let (entries, headers) = scan()
        let text = TOML.serialize(v)
        if let e = entries.first(where: { $0.path == path }) {
            var chars = Array(lines[e.line])
            chars.replaceSubrange(e.valueStart..<e.valueEnd, with: Array(text))
            lines[e.line] = String(chars)
            return
        }
        let table = Array(path.dropLast())
        let newLine = "\(TOML.key(key)) = \(text)"
        if let last = entries.last(where: { $0.table == table }) {
            lines.insert(newLine, at: last.line + 1)
        } else if let h = headers.first(where: { $0.path == table }) {
            lines.insert(newLine, at: h.line + 1)
        } else if table.isEmpty {
            lines.insert(newLine, at: headers.first?.line ?? lines.count)
        } else {
            if let l = lines.last, !l.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines.append("[\(table.map(TOML.key).joined(separator: "."))]")
            lines.append(newLine)
        }
    }

    /// Removes the key's line. A `[table]` left with nothing but blank lines goes too.
    public mutating func remove(_ path: [String]) {
        let (entries, _) = scan()
        guard let e = entries.first(where: { $0.path == path }) else { return }
        lines.remove(at: e.line)
        guard !e.table.isEmpty, !entries.contains(where: { $0.table == e.table && $0.path != path }) else { return }
        let headers = scan().headers
        guard let hi = headers.firstIndex(where: { $0.path == e.table }) else { return }
        let h = headers[hi]
        let end = hi + 1 < headers.count ? headers[hi + 1].line : lines.count
        let body = lines[(h.line + 1)..<end]
        let header = lines[h.line].trimmingCharacters(in: .whitespaces)
        guard body.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }), !header.contains("#") else { return }
        lines.removeSubrange(h.line..<end)
        // Collapse a double blank line left behind.
        if h.line > 0, h.line <= lines.count, lines[h.line - 1].trimmingCharacters(in: .whitespaces).isEmpty,
            h.line == lines.count || lines[h.line].trimmingCharacters(in: .whitespaces).isEmpty
        {
            lines.remove(at: h.line - 1)
        }
    }
}
