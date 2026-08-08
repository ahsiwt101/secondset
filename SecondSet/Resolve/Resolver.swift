import Foundation

// SPEC §13. Scoring is normalised so that every decision tier is actually
// reachable. The naive `0.55*exact + 0.30*phonetic + 0.15*prior` formulation
// caps a non-exact match at 0.45, which sits below the silent-miss floor —
// meaning phonetic matching could never influence an outcome and every
// mishearing fell silently on the floor. See `ResolverTests.reachability`.

struct Match: Sendable, Equatable {
    let slot: SlotRef
    let displayName: String
    let score: Double
}

enum Resolution: Sendable, Equatable {
    case commit(SlotRef)
    case ambiguous([SlotRef])
    case notOnField(displayName: String)
    case silent
    case control(ControlPhrase)
}

enum ControlPhrase: String, Sendable, CaseIterable {
    case passed, returned

    static func match(_ normalised: String) -> ControlPhrase? {
        switch normalised {
        case "passed", "pass", "handed", "taken", "gone":     return .passed
        case "back", "returned", "return", "back on":          return .returned
        default: return nil
        }
    }
}

/// One searchable instrument. Phonetic codes are precomputed at build time —
/// re-encoding on every ASR partial would burn the latency budget.
struct Candidate: Sendable {
    let slot: SlotRef
    let displayName: String
    let aliases: [String]
    let aliasCodes: [String]
    let usagePhase: CasePhase?

    init(slot: SlotRef, displayName: String, aliases: [String], usagePhase: CasePhase?) {
        self.slot = slot
        self.displayName = displayName
        // Always searchable by full display name, not just curated aliases.
        let all = (aliases + [displayName]).map {
            $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.aliases = Array(Set(all)).sorted()
        self.aliasCodes = self.aliases.map(Phonetics.encode)
        self.usagePhase = usagePhase
    }
}

struct Resolver: Sendable {

    /// Instruments on trays that are registered right now. Only these can win.
    let onField: [Candidate]
    /// Everything the app ships manifests for. Used solely to tell
    /// "I don't know that word" apart from "that isn't open yet".
    let catalogue: [Candidate]
    var phase: CasePhase
    var markedInPlay: Set<SlotRef>

    init(onField: [Candidate],
         catalogue: [Candidate],
         phase: CasePhase = .setup,
         markedInPlay: Set<SlotRef> = []) {
        self.onField = onField
        self.catalogue = catalogue
        self.phase = phase
        self.markedInPlay = markedInPlay
    }

    // MARK: - Thresholds (SPEC §13)

    enum Threshold {
        static let partialCommit = 0.80
        static let partialMargin = 0.25
        static let finalCommit   = 0.65
        static let finalMargin   = 0.15
        static let ambiguous     = 0.50
        /// How well a phrase must match the wider catalogue before we are
        /// willing to say "not on the field" rather than staying silent.
        static let notOnField    = 0.65
    }

    // MARK: - Ranking

    func rank(_ heard: String, in pool: [Candidate]? = nil) -> [Match] {
        let candidates = pool ?? onField
        let variants = Self.normalisedVariants(heard)
        guard !variants.isEmpty else { return [] }

        return candidates.map { c in
            let lexical = variants.map { lexicalScore($0, c) }.max() ?? 0
            let prior = usagePrior(c)
            let recency = markedInPlay.contains(c.slot) ? -0.15 : 0.0
            let score = (0.85 * lexical + 0.15 * prior + recency).clamped(to: 0...1)
            return Match(slot: c.slot, displayName: c.displayName, score: score)
        }
        .sorted { $0.score > $1.score }
    }

    /// One normalised signal in [0, 1], three tiers. Keeping this as a single
    /// signal rather than three separate weighted terms is what makes the
    /// thresholds mean something.
    private func lexicalScore(_ heard: String, _ c: Candidate) -> Double {
        if c.aliases.contains(heard) { return 1.00 }

        if c.aliases.contains(where: { $0.hasPrefix(heard) || heard.hasPrefix($0) }) {
            // "metz" against "metzenbaum" — a clean prefix, but shorter
            // fragments are weaker evidence, so scale by how much was heard.
            let best = c.aliases
                .filter { $0.hasPrefix(heard) || heard.hasPrefix($0) }
                .map { Double(min(heard.count, $0.count)) / Double(max(heard.count, $0.count)) }
                .max() ?? 0
            return 0.70 + 0.15 * best        // 0.70 ... 0.85
        }

        // Capped below the prefix tier so a phonetic hit can reach the
        // disambiguation card but never silently outrank a real prefix match.
        let heardCode = Phonetics.encode(heard)
        var best = 0.0
        for (alias, code) in zip(c.aliases, c.aliasCodes) {
            let s = code.isEmpty
                ? Phonetics.similarity(heard, alias)
                : max(Phonetics.similarity(heard, alias),
                      0.7 * ratioOfCodes(heardCode, code) + 0.3 * Phonetics.similarity(heard, alias))
            best = max(best, s)
        }
        return min(0.68, best)
    }

    private func ratioOfCodes(_ a: String, _ b: String) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 0 }
        return 1.0 - Double(Phonetics.levenshtein(a, b)) / Double(longest)
    }

    /// Retractors early, needle drivers at closing. Neutral (0.5) when the
    /// manifest does not say, so an unannotated slot is never penalised.
    private func usagePrior(_ c: Candidate) -> Double {
        guard let p = c.usagePhase else { return 0.5 }
        return p == phase ? 1.0 : 0.25
    }

    // MARK: - Decision policy

    func resolve(_ heard: String, isFinal: Bool) -> Resolution {
        let normalised = Self.normalise(heard)
        guard !normalised.isEmpty else { return .silent }

        if let control = ControlPhrase.match(normalised) {
            return .control(control)
        }

        let ranked = rank(normalised)
        guard let top = ranked.first else { return .silent }
        let margin = top.score - (ranked.dropFirst().first?.score ?? 0)

        if !isFinal {
            // A partial is provisional and may still mutate, so committing on
            // one clears a higher bar than committing on a final.
            return (top.score >= Threshold.partialCommit && margin >= Threshold.partialMargin)
                ? .commit(top.slot)
                : .silent
        }

        if top.score >= Threshold.finalCommit && margin >= Threshold.finalMargin {
            return .commit(top.slot)
        }
        if top.score >= Threshold.ambiguous {
            let top3 = ranked.prefix(3).filter { $0.score >= Threshold.ambiguous - 0.1 }
            return top3.count > 1 ? .ambiguous(top3.map(\.slot)) : .commit(top.slot)
        }

        // Below the floor on the field. Before going silent, ask whether the
        // phrase is a real instrument that simply is not open — a genuinely
        // useful answer, and it makes the system look like it understands the
        // room rather than just its own database. SPEC §4.
        let offField = catalogue.filter { c in !onField.contains { $0.slot == c.slot } }
        if let alt = rank(normalised, in: offField).first, alt.score >= Threshold.notOnField {
            return .notOnField(displayName: alt.displayName)
        }

        // A wrong highlight costs trust permanently. A silent miss costs a
        // second. This line is a product decision expressed in code.
        return .silent
    }

    // MARK: - Normalisation

    static func normalise(_ s: String) -> String {
        let lowered = s.lowercased()
        let cleaned = lowered.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == " " { return ch }
            return " "                                   // hyphens, commas, "2-0"
        }
        return String(cleaned)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Surgical speech is full of numbers that ASR renders inconsistently:
    /// "2-0 vicryl" / "two oh vicryl", "10 blade" / "ten blade". Try both
    /// spellings and let the better one win rather than authoring every
    /// permutation into the alias table by hand.
    static func normalisedVariants(_ s: String) -> [String] {
        let base = normalise(s)
        guard !base.isEmpty else { return [] }

        let digits = ["0": "oh", "1": "one", "2": "two", "3": "three", "4": "four",
                      "5": "five", "6": "six", "7": "seven", "8": "eight",
                      "9": "nine", "10": "ten", "11": "eleven", "12": "twelve",
                      "15": "fifteen", "20": "twenty"]

        let spelled = base.split(separator: " ").map { token -> String in
            digits[String(token)] ?? String(token)
        }.joined(separator: " ")

        return spelled == base ? [base] : [base, spelled]
    }
}

// MARK: - Vocabulary for ASR biasing

enum Vocabulary {
    /// SPEC §12.3. `contextualStrings` degrades well before any hard limit, so
    /// submit only what is on the field, ranked by expected frequency, capped.
    /// Short spoken forms are the ones surgeons actually use.
    static func contextualStrings(for candidates: [Candidate],
                                  phase: CasePhase,
                                  cap: Int = Tunables.vocabularyCap) -> [String] {
        struct Ranked { let term: String; let rank: Double }

        var seen = Set<String>()
        var ranked: [Ranked] = []

        for c in candidates {
            let phaseBoost: Double = (c.usagePhase == phase) ? 0 : 1
            for alias in c.aliases where !seen.contains(alias) {
                seen.insert(alias)
                // Lower is better: phase-relevant first, then shortest.
                ranked.append(Ranked(term: alias, rank: phaseBoost * 100 + Double(alias.count)))
            }
        }

        return ranked.sorted { $0.rank < $1.rank }
                     .prefix(cap)
                     .map(\.term)
    }
}
