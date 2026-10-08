import Foundation
import Testing

@testable import PounceCore

@Suite struct ConflictsTests {
    @Test func knownConflicts() {
        let hint = KeyChord.parse("cmd+shift+space")!
        #expect(Conflicts.for(hint).contains("VS Code / Cursor parameter hints"))
        #expect(Conflicts.for(hint).contains("1Password Quick Access"))
        #expect(Conflicts.for(KeyChord.parse("cmd+shift+j")!).contains("Chrome Downloads"))
        #expect(Conflicts.for(Shortcut.parse("cmd+space")!) == ["Spotlight"])
        #expect(Conflicts.for(Shortcut.parse("tap:rcmd")!).isEmpty)
        #expect(Conflicts.for(KeyChord.parse("hyper+f")!).isEmpty)
        // Every table entry parses.
        for (raw, _) in Conflicts.known { #expect(KeyChord.parse(raw) != nil, "\(raw)") }
    }

    @Test func parseSymbolicHotkeys() {
        let dict: [String: Any] = [
            "64": ["enabled": false, "value": ["parameters": [32, 49, 1_048_576], "type": "standard"]],
            "60": ["enabled": true, "value": ["parameters": [32, 49, 262_144], "type": "standard"]],
            "164": ["enabled": true, "value": ["parameters": [65535, 65535, 0], "type": "standard"]],
            "32": ["enabled": true, "value": ["parameters": [65535, 126, 8_650_752], "type": "standard"]],
            "28": ["enabled": true],  // no value: default chord
            "999": ["enabled": true, "value": ["parameters": [102, 3, 1_179_648], "type": "standard"]],
        ]
        let e = SystemHotkeys.parse(dict)
        let space = KeyChord.parse("cmd+space")!
        #expect(SystemHotkeys.conflicts(space, in: e).isEmpty)  // Spotlight disabled
        #expect(SystemHotkeys.conflicts(KeyChord.parse("ctrl+space")!, in: e) == ["Select the previous input source"])
        #expect(SystemHotkeys.conflicts(KeyChord.parse("ctrl+up")!, in: e) == ["Mission Control"])
        #expect(SystemHotkeys.conflicts(KeyChord.parse("cmd+shift+3")!, in: e) == ["Save screenshot"])
        #expect(SystemHotkeys.conflicts(KeyChord.parse("cmd+shift+f")!, in: e) == ["macOS shortcut #999"])
        // Untouched ids keep their defaults.
        #expect(SystemHotkeys.conflicts(KeyChord.parse("cmd+opt+space")!, in: e) == ["Show Finder search window"])
        #expect(!e.contains { $0.id == 164 })
    }

    @Test func readsCurrentWithoutCrashing() {
        _ = SystemHotkeys.current()
    }
}
