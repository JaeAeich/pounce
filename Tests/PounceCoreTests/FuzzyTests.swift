import Testing

@testable import PounceCore

@Suite struct FuzzyTests {
    @Test func caseAndSpaceInsensitive() {
        #expect(Fuzzy.score("NS", "new song") != nil)
        #expect(Fuzzy.score("n s", "New Song") != nil)
        #expect(Fuzzy.score("newsong", "New Song") == Fuzzy.score("New Song", "new song"))
        #expect(Fuzzy.normalize(" A b\tC ") == "abc")
    }

    @Test func nonSubsequenceIsNil() {
        #expect(Fuzzy.score("xyz", "New Song") == nil)
        #expect(Fuzzy.score("sn", "ns") == nil)
        #expect(Fuzzy.score("aa", "a") == nil)
        #expect(Fuzzy.score("a", "") == nil)
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(Fuzzy.score("", "anything") == 0)
        #expect(Fuzzy.score("   ", "anything") == 0)
        #expect(Fuzzy.score("", "") == 0)
    }

    @Test func wordStartsRankOverMidWord() throws {
        let a = try #require(Fuzzy.score("ns", "New Song"))
        let b = try #require(Fuzzy.score("ns", "insert"))
        #expect(a > b)
    }

    @Test func contiguousRanksOverScattered() throws {
        let contiguous = try #require(Fuzzy.score("ert", "xxinsertxx"))
        let scattered = try #require(Fuzzy.score("ert", "xexrxtx"))
        #expect(contiguous > scattered)
    }

    @Test func prefixBeatsMiddle() throws {
        let p = try #require(Fuzzy.score("sa", "Save file"))
        let m = try #require(Fuzzy.score("sa", "File save"))
        #expect(p > m)
    }

    @Test func exactMatchBeatsPartial() throws {
        let exact = try #require(Fuzzy.score("save", "Save"))
        let partial = try #require(Fuzzy.score("save", "Save As"))
        #expect(exact > partial)
        let exactSpaced = try #require(Fuzzy.score("saveas", "Save As"))
        let longer = try #require(Fuzzy.score("saveas", "Save As Template"))
        #expect(exactSpaced > longer)
    }

    @Test func shorterCandidatePreferredForSameMatch() throws {
        let short = try #require(Fuzzy.score("ok", "OK button"))
        let long = try #require(Fuzzy.score("ok", "OK button with a much longer description text here"))
        #expect(short > long)
    }
}
