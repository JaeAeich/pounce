import Testing

@testable import PounceCore

private func isPrefixFree(_ labels: [String]) -> Bool {
    for (i, a) in labels.enumerated() {
        for (j, b) in labels.enumerated() where i != j && b.hasPrefix(a) { return false }
    }
    return true
}

/// Faster check for large sets: sorted neighbours suffice for prefix detection.
private func isPrefixFreeSorted(_ labels: [String]) -> Bool {
    let s = labels.sorted()
    for i in s.indices.dropLast() where s[i + 1].hasPrefix(s[i]) { return false }
    return Set(labels).count == labels.count
}

@Suite struct LabelsGenerateTests {
    @Test(arguments: ["asdfghjkl", "ab", "abc", "fjdkslaghrueiwoqp"])
    func countAndPrefixFree(alphabet: String) {
        let chars = Set(alphabet)
        for count in 1...2000 {
            let labels = Labels.generate(count: count, alphabet: alphabet)
            #expect(labels.count == count, "count \(count)")
            #expect(isPrefixFreeSorted(labels), "count \(count)")
            #expect(labels.allSatisfy { !$0.isEmpty && $0.allSatisfy(chars.contains) }, "count \(count)")
            if labels.count != count { return }
        }
    }

    @Test func singleLabelIsNonEmpty() {
        #expect(Labels.generate(count: 1, alphabet: "asdf") == ["a"])
        #expect(Labels.generate(count: 1, alphabet: "ab") == ["a"])
    }

    @Test func zeroOrNegative() {
        #expect(Labels.generate(count: 0, alphabet: "asdf").isEmpty)
        #expect(Labels.generate(count: -3, alphabet: "asdf").isEmpty)
        #expect(Labels.generate(count: 5, alphabet: "").isEmpty)
    }

    @Test func usesOneCharLabelsWhenPossible() {
        #expect(Labels.generate(count: 4, alphabet: "asdf") == ["a", "s", "d", "f"])
        #expect(Labels.generate(count: 9, alphabet: "asdfghjkl").allSatisfy { $0.count == 1 })
    }

    @Test func shortestFirstAndMaximisesShortLabels() {
        let labels = Labels.generate(count: 10, alphabet: "asdfghjkl")
        // One expansion: 8 single-char labels remain + 2 two-char.
        #expect(labels.filter { $0.count == 1 }.count == 8)
        #expect(labels.filter { $0.count == 2 }.count == 2)
        for n in [10, 50, 81, 82, 500, 2000] {
            let l = Labels.generate(count: n, alphabet: "asdfghjkl")
            #expect(zip(l, l.dropFirst()).allSatisfy { $0.count <= $1.count }, "n=\(n)")
        }
        // 81 labels over 9 chars fit exactly in 2 chars.
        #expect(Labels.generate(count: 81, alphabet: "asdfghjkl").allSatisfy { $0.count == 2 })
    }

    @Test func smallPrefixFreeExhaustive() {
        for n in 1...40 {
            #expect(isPrefixFree(Labels.generate(count: n, alphabet: "abc")), "n=\(n)")
        }
    }

    @Test func duplicateAndCaseAndSpaceCharsCollapse() {
        #expect(Labels.uniqueChars("aAb b") == ["a", "b"])
        let l = Labels.generate(count: 5, alphabet: "aabbAB")
        #expect(l.count == 5)
        #expect(isPrefixFree(l))
        #expect(l.allSatisfy { $0.allSatisfy { $0 == "a" || $0 == "b" } })
    }

    @Test func singleCharAlphabetDegenerate() {
        let l = Labels.generate(count: 3, alphabet: "aaa")
        #expect(l == ["a", "aa", "aaa"])
        #expect(Set(l).count == 3)
    }
}

@Suite struct LabelsAssignTests {
    typealias C = Labels.Candidate

    @Test func allUniqueAndCandidateOrder() {
        let cands = (0..<100).map { C(key: "k\($0)") }
        let labels = Labels.assign(cands, alphabet: "asdfghjkl")
        #expect(labels.count == 100)
        #expect(Set(labels).count == 100)
        #expect(Set(labels) == Set(Labels.generate(count: 100, alphabet: "asdfghjkl")))
    }

    @Test func keepsPreviousLabels() {
        let cands = (0..<20).map { C(key: "k\($0)") }
        let first = Labels.assign(cands, alphabet: "asdfghjkl")
        let prev = Dictionary(uniqueKeysWithValues: zip(cands.map(\.key), first))
        // Reorder candidates: labels follow keys.
        let shuffled = Array(cands.reversed())
        let second = Labels.assign(shuffled, alphabet: "asdfghjkl", previous: prev)
        for (c, l) in zip(shuffled, second) { #expect(prev[c.key] == l) }
    }

    @Test func previousLabelOutsideSetIsReassigned() {
        let cands = [C(key: "a"), C(key: "b")]
        let labels = Labels.assign(cands, alphabet: "asdf", previous: ["a": "zz", "b": "s"])
        #expect(labels[1] == "s")
        #expect(labels[0] != "zz")
        #expect(Set(labels).count == 2)
    }

    @Test func conflictingPreviousLabelsStayUnique() {
        let cands = [C(key: "a"), C(key: "b"), C(key: "c")]
        let labels = Labels.assign(cands, alphabet: "asdf", previous: ["a": "d", "b": "d"])
        #expect(labels[0] == "d")
        #expect(labels[1] != "d")
        #expect(Set(labels).count == 3)
    }

    @Test func highUsageGetsShortestLabel() {
        var cands = (0..<20).map { C(key: "k\($0)") }
        cands[17].usage = 50
        cands[12].usage = 10
        let labels = Labels.assign(cands, alphabet: "asdfghjkl")
        let minLen = labels.map(\.count).min()!
        #expect(labels[17].count == minLen)
        let order = Labels.generate(count: 20, alphabet: "asdfghjkl")
        #expect(labels[17] == order[0])  // first (shortest) label goes to most used
        #expect(labels[12] == order[1])
        #expect(Set(labels).count == 20)
    }

    @Test func usageTiesKeepCandidateOrder() {
        let cands = (0..<4).map { C(key: "k\($0)") }
        #expect(Labels.assign(cands, alphabet: "asdf") == ["a", "s", "d", "f"])
    }

    @Test func emptyAndSingle() {
        #expect(Labels.assign([], alphabet: "asdf").isEmpty)
        #expect(Labels.assign([C(key: "x")], alphabet: "asdf") == ["a"])
    }
}
