import Testing

@testable import PounceCore

@Suite struct TOMLTests {
    @Test func scalarsAndTables() throws {
        let t = try TOML.parse(
            """
            title = "hi"
            [a]
            n = 42
            neg = -7
            big = 1_000
            f = 1.5
            e = 2e3
            yes = true
            no = false
            [a.b]
            x = "y"
            """)
        #expect(t["title"] == .string("hi"))
        let a = try #require(t["a"]?.table)
        #expect(a["n"] == .int(42))
        #expect(a["neg"] == .int(-7))
        #expect(a["big"] == .int(1000))
        #expect(a["f"] == .double(1.5))
        #expect(a["e"] == .double(2000))
        #expect(a["yes"] == .bool(true))
        #expect(a["no"] == .bool(false))
        #expect(a["b"]?.table?["x"] == .string("y"))
    }

    @Test func dottedKeys() throws {
        let t = try TOML.parse("a.b.c = 1\na.b.d = 2")
        #expect(t["a"]?.table?["b"]?.table?["c"] == .int(1))
        #expect(t["a"]?.table?["b"]?.table?["d"] == .int(2))
    }

    @Test func quotedKeys() throws {
        let t = try TOML.parse(
            """
            [apps."com.foo.bar"]
            ignore = true
            "key with space" = 1
            """)
        let app = try #require(t["apps"]?.table?["com.foo.bar"]?.table)
        #expect(app["ignore"] == .bool(true))
        #expect(app["key with space"] == .int(1))
    }

    @Test func stringEscapes() throws {
        let t = try TOML.parse(#"s = "a\"b\\c\nd\te # not a comment""#)
        #expect(t["s"] == .string("a\"b\\c\nd\te # not a comment"))
    }

    @Test func quoteRoundtrip() throws {
        let raw = "q\"uo\\te\nnew\ttab #hash"
        let t = try TOML.parse("s = \(TOML.quote(raw))")
        #expect(t["s"]?.string == raw)
    }

    @Test func keyQuoting() {
        #expect(TOML.key("plain_key-1") == "plain_key-1")
        #expect(TOML.key("com.foo.bar") == "\"com.foo.bar\"")
        #expect(TOML.key("") == "\"\"")
    }

    @Test func formatDouble() throws {
        #expect(TOML.format(12) == "12.0")
        #expect(TOML.format(1.25) == "1.25")
        for d in [0.0, 12, 1.25, -3.5, 1e20, 900] {
            #expect(try TOML.parse("x = \(TOML.format(d))")["x"]?.double == d)
        }
    }

    @Test func arrays() throws {
        let t = try TOML.parse(#"a = ["x", "y" , "z"]"# + "\nb = []\nc = [1, 2.5, true]\nd = [[1], [2, 3]]\ne = [\"t\",]")
        #expect(t["a"]?.strings == ["x", "y", "z"])
        #expect(t["b"] == .array([]))
        #expect(t["b"]?.strings == [])
        #expect(t["c"] == .array([.int(1), .double(2.5), .bool(true)]))
        #expect(t["c"]?.strings == nil)
        #expect(t["d"] == .array([.array([.int(1)]), .array([.int(2), .int(3)])]))
        #expect(t["e"]?.strings == ["t"])
    }

    @Test func comments() throws {
        let t = try TOML.parse(
            """
            # full line
              # indented
            [t] # after header
            a = 1 # after value
            b = "x" # after string
            c = [1, 2] # after array

            """)
        #expect(t["t"]?.table == ["a": .int(1), "b": .string("x"), "c": .array([.int(1), .int(2)])])
    }

    @Test func accessors() {
        #expect(TOMLValue.int(3).double == 3)
        #expect(TOMLValue.double(3).int == 3)
        #expect(TOMLValue.double(3.5).int == nil)
        #expect(TOMLValue.string("x").int == nil)
        #expect(TOMLValue.bool(true).string == nil)
    }

    private func error(_ text: String) -> TOMLError? {
        do {
            _ = try TOML.parse(text)
            return nil
        } catch let e as TOMLError {
            return e
        } catch {
            return nil
        }
    }

    @Test func duplicateKey() throws {
        let e = try #require(error("a = 1\n\nb = 2\na = 3"))
        #expect(e.line == 4)
        #expect(e.message.contains("duplicate"))
        #expect(error("[t]\nx = 1\n[t]\nx = 2")?.line == 4)
    }

    @Test func badValue() throws {
        let e = try #require(error("[t]\nx = nope"))
        #expect(e.line == 2)
        #expect(e.message.contains("nope"))
        #expect(error("x = ")?.line == 1)
        #expect(error("x = 1 2")?.line == 1)
        #expect(error("x = [1, 2")?.line == 1)
        #expect(error("\n\nx = [1 2]")?.line == 3)
    }

    @Test func unterminatedString() throws {
        let e = try #require(error("a = 1\nb = \"oops"))
        #expect(e.line == 2)
        #expect(e.message.contains("unterminated"))
        #expect(error("s = \"bad \\q escape\"")?.message.contains("escape") == true)
    }

    @Test func structuralErrors() {
        #expect(error("[t\nx = 1")?.line == 1)
        #expect(error("= 1")?.line == 1)
        #expect(error("x 1")?.line == 1)
        #expect(error("a = 1\n[a]")?.line == 2)  // not a table
        #expect(error("a = 1\na.b = 2")?.line == 2)
        #expect(error("[t] junk")?.line == 1)
        #expect(error("x = 1\ny = 2").self == nil)
    }

    @Test func crlfLineNumbers() throws {
        let t = try TOML.parse("a = 1\r\nb = 2\r\n")
        #expect(t == ["a": .int(1), "b": .int(2)])
        #expect(error("a = 1\r\nb = 2\r\nc = bad")?.line == 3)
    }

    @Test func errorDescription() {
        #expect(TOMLError(line: 3, message: "boom").description == "line 3: boom")
    }
}
