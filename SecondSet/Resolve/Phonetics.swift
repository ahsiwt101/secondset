import Foundation

// SPEC §13. ASR errors are acoustic, not typographic: "metz" mishears as
// "mets" or "maids", not as a random edit. Comparing raw strings by edit
// distance therefore misses most real recognition failures, and comparing
// phonetic codes catches them.
//
// This is Metaphone-lite: the subset of the English rules that matters for
// surgical nomenclature, at ~150 lines instead of Double Metaphone's ~600.
// It reduces all three of metz / mets / maids to "MTS".

enum Phonetics {

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]

    /// Reduce a spoken form to a consonant skeleton. Vowels survive only in
    /// first position, because that is the only place ASR reliably gets them.
    static func encode(_ input: String) -> String {
        let s = Array(input.lowercased().filter { $0.isLetter })
        guard !s.isEmpty else { return "" }

        var chars = s
        var start = 0

        // Silent leading pairs.
        if chars.count >= 2 {
            let pair = String(chars[0...1])
            if ["ae", "gn", "kn", "pn", "wr"].contains(pair) { start = 1 }
            if pair == "wh" { chars[1] = "w"; start = 1 }
        }
        if chars[start] == "x" { chars[start] = "s" }

        var out = ""
        var i = start

        func at(_ k: Int) -> Character? {
            (k >= 0 && k < chars.count) ? chars[k] : nil
        }
        func isVowel(_ k: Int) -> Bool {
            guard let c = at(k) else { return false }
            return vowels.contains(c)
        }

        while i < chars.count {
            let c = chars[i]
            let next = at(i + 1)
            let afterNext = at(i + 2)

            // Skip a doubled letter, except "cc" which can change sound.
            if i > start, c == chars[i - 1], c != "c" {
                i += 1
                continue
            }

            switch c {
            case "a", "e", "i", "o", "u":
                if i == start { out.append(c) }

            case "b":
                // Silent b in a trailing "mb".
                if !(i == chars.count - 1 && at(i - 1) == "m") { out.append("B") }

            case "c":
                if next == "i", afterNext == "a" { out.append("X"); i += 2 }
                else if next == "h" { out.append("X"); i += 1 }
                else if next == "i" || next == "e" || next == "y" { out.append("S") }
                else { out.append("K") }

            case "d":
                if next == "g", let a = afterNext, "eyi".contains(a) { out.append("J"); i += 2 }
                else { out.append("T") }

            case "g":
                if next == "h" {
                    // "gh" is silent unless it opens a syllable.
                    if isVowel(i + 2) { out.append("K") }
                    i += 1
                } else if next == "n" {
                    i += 1                                  // silent
                } else if let n = next, "eyi".contains(n) {
                    out.append("J")
                } else {
                    out.append("K")
                }

            case "h":
                // Pronounced only between a vowel and a vowel, or word-initial.
                if i == start, isVowel(i + 1) { out.append("H") }
                else if isVowel(i - 1), isVowel(i + 1) { out.append("H") }

            case "k":
                if at(i - 1) != "c" { out.append("K") }

            case "p":
                if next == "h" { out.append("F"); i += 1 } else { out.append("P") }

            case "q":
                out.append("K")

            case "s":
                if next == "h" { out.append("X"); i += 1 }
                else if next == "i", let a = afterNext, "oa".contains(a) { out.append("X"); i += 2 }
                else { out.append("S") }

            case "t":
                if next == "i", let a = afterNext, "oa".contains(a) { out.append("X"); i += 2 }
                else if next == "h" { out.append("0"); i += 1 }
                else if next == "c", afterNext == "h" { }      // silent t in "tch"
                else { out.append("T") }

            case "v":
                out.append("F")

            case "w", "y":
                if isVowel(i + 1) { out.append(Character(String(c).uppercased())) }

            case "x":
                out.append("KS")

            case "z":
                out.append("S")

            case "f", "j", "l", "m", "n", "r":
                out.append(Character(String(c).uppercased()))

            default:
                break
            }
            i += 1
        }

        return collapseRuns(out)
    }

    private static func collapseRuns(_ s: String) -> String {
        var out = ""
        for c in s where out.last != c { out.append(c) }
        return out
    }

    /// Similarity in [0, 1]. Blends the phonetic skeleton (dominant) with raw
    /// spelling (a tiebreaker), so that codes colliding on short words do not
    /// produce false confidence.
    static func similarity(_ a: String, _ b: String) -> Double {
        let rawA = a.lowercased().filter { $0.isLetter || $0 == " " }
        let rawB = b.lowercased().filter { $0.isLetter || $0 == " " }
        guard !rawA.isEmpty, !rawB.isEmpty else { return 0 }

        let codeSim = ratio(encode(rawA), encode(rawB))
        let rawSim  = ratio(rawA, rawB)
        return (0.7 * codeSim + 0.3 * rawSim).clamped(to: 0...1)
    }

    private static func ratio(_ a: String, _ b: String) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 0 }
        return 1.0 - Double(levenshtein(a, b)) / Double(longest)
    }

    /// Two-row dynamic programming. Allocation-light: this runs once per
    /// candidate per alias per ASR partial, which is a few thousand calls a
    /// second during an utterance.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }

        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)

        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1,          // deletion
                              curr[j - 1] + 1,      // insertion
                              prev[j - 1] + cost)   // substitution
            }
            swap(&prev, &curr)
        }
        return prev[y.count]
    }
}
