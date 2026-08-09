import Testing
import Foundation
@testable import SecondSet

// The resolver is the only part of this build that can be fully verified
// without a headset, so it is the part that gets real tests. Run these on
// every resolver change — SPEC §13 says tune against a corpus, not intuition,
// and this file is the floor under that corpus.

@Suite("Resolver")
struct ResolverTests {

    // MARK: - Fixtures

    static func candidate(_ tray: String,
                          _ index: Int,
                          _ name: String,
                          _ aliases: [String],
                          phase: CasePhase? = nil) -> Candidate {
        Candidate(slot: .instrument(tray, index),
                  displayName: name,
                  aliases: aliases,
                  usagePhase: phase)
    }

    static let metz    = candidate("ORT-01", 8, "Metzenbaum Scissors 7\"", ["metz", "metzenbaum", "tissue scissors"])
    static let mayo    = candidate("ORT-01", 9, "Mayo Scissors, straight 7\"", ["mayo", "heavy scissors"])
    static let mosquito = candidate("ORT-01", 5, "Mosquito Forceps, curved 5\"", ["mosquito", "snap", "small clamp"])
    static let mallet  = candidate("ORT-01", 0, "Orthopaedic Mallet 1 lb", ["mallet", "hammer"], phase: .exposure)
    static let iris    = candidate("GEN-01", 5, "Iris Scissors, curved", ["iris", "fine scissors"])

    static func makeResolver(onField: [Candidate] = [metz, mayo, mosquito, mallet],
                             catalogue: [Candidate]? = nil,
                             phase: CasePhase = .setup,
                             marked: Set<SlotRef> = []) -> Resolver {
        Resolver(onField: onField,
                 catalogue: catalogue ?? (onField + [iris]),
                 phase: phase,
                 markedInPlay: marked)
    }

    // MARK: - The regression guard

    /// The bug this file exists for. The original scoring was
    /// `0.55*exact + 0.30*phonetic + 0.15*prior`, which caps a non-exact match
    /// at 0.45 — below the 0.55 silent-miss floor. Phonetic matching was
    /// therefore dead code and every mishearing fell silently on the floor.
    ///
    /// Any change to the weights must keep all four tiers reachable.
    @Test("Every decision tier is reachable")
    func reachability() {
        let r = Self.makeResolver()

        // Tier 1: exact alias must clear the strictest bar (partial commit).
        let exact = r.rank("metz").first!.score
        #expect(exact >= Resolver.Threshold.partialCommit,
                "exact alias scored \(exact), below partial-commit \(Resolver.Threshold.partialCommit)")

        // Tier 2: a clean prefix must clear the final-commit bar.
        let prefix = r.rank("metzenb").first!.score
        #expect(prefix >= Resolver.Threshold.finalCommit,
                "prefix scored \(prefix), below final-commit \(Resolver.Threshold.finalCommit)")

        // Tier 3: a phonetic near-miss must at minimum reach the
        // disambiguation card rather than vanishing.
        let phonetic = r.rank("mets").first!.score
        #expect(phonetic >= Resolver.Threshold.ambiguous,
                "phonetic near-miss scored \(phonetic), below ambiguous \(Resolver.Threshold.ambiguous)")

        // Tier 4: unrelated speech must stay under the floor.
        let noise = r.rank("can you turn the music down").first!.score
        #expect(noise < Resolver.Threshold.ambiguous,
                "OR chatter scored \(noise), which would have produced UI")
    }

    // MARK: - Committing

    @Test("Exact alias commits on a final result")
    func exactCommits() {
        let r = Self.makeResolver()
        #expect(r.resolve("metz", isFinal: true) == .commit(Self.metz.slot))
    }

    @Test("Exact alias commits early on a partial")
    func partialCommits() {
        let r = Self.makeResolver()
        #expect(r.resolve("mosquito", isFinal: true) == .commit(Self.mosquito.slot))
        #expect(r.resolve("mosquito", isFinal: false) == .commit(Self.mosquito.slot))
    }

    @Test("A partial that has not separated yet waits for the final")
    func partialWaits() {
        // "s" is a fragment consistent with several candidates: committing on
        // it would fire a highlight the utterance is about to contradict.
        let r = Self.makeResolver()
        #expect(r.resolve("s", isFinal: false) == .silent)
    }

    @Test("Punctuation and casing are normalised away")
    func normalisation() {
        let r = Self.makeResolver()
        #expect(r.resolve("  Metz. ", isFinal: true) == .commit(Self.metz.slot))
        #expect(r.resolve("METZ", isFinal: true) == .commit(Self.metz.slot))
    }

    // MARK: - Phonetic recovery

    @Test("Acoustic mishearings recover to the right instrument",
          arguments: ["mets", "metz's", "metzen"])
    func phoneticRecovery(heard: String) {
        let r = Self.makeResolver()
        let top = r.rank(heard).first
        #expect(top?.slot == Self.metz.slot,
                "\"\(heard)\" ranked \(top?.displayName ?? "nothing") first")
    }

    @Test("Phonetic codes collapse the classic ASR confusions")
    func phoneticCodes() {
        #expect(Phonetics.encode("metz") == Phonetics.encode("mets"))
        #expect(Phonetics.encode("phone") == Phonetics.encode("fone"))
        #expect(Phonetics.encode("knife") == Phonetics.encode("nife"))
        // And does NOT collapse things that must stay distinct.
        #expect(Phonetics.encode("mallet") != Phonetics.encode("mayo"))
    }

    // MARK: - Ambiguity

    @Test("A term shared by several instruments asks instead of guessing")
    func ambiguityAsks() {
        // Both Metzenbaum and Mayo are reachable via a "scissors" phrase.
        let scissorsA = Self.candidate("ORT-01", 8, "Metzenbaum Scissors", ["scissors", "metz"])
        let scissorsB = Self.candidate("ORT-01", 9, "Mayo Scissors", ["scissors", "mayo"])
        let r = Self.makeResolver(onField: [scissorsA, scissorsB])

        guard case .ambiguous(let options) = r.resolve("scissors", isFinal: true) else {
            Issue.record("expected an ambiguous result, got \(r.resolve("scissors", isFinal: true))")
            return
        }
        #expect(options.count == 2)
    }

    @Test("Ambiguity never fires from a partial")
    func ambiguityNeverPartial() {
        let a = Self.candidate("ORT-01", 8, "Metzenbaum", ["scissors", "metz"])
        let b = Self.candidate("ORT-01", 9, "Mayo", ["scissors", "mayo"])
        let r = Self.makeResolver(onField: [a, b])
        #expect(r.resolve("scissors", isFinal: false) == .silent)
    }

    // MARK: - Silence and off-field

    @Test("Ordinary theatre chatter renders nothing at all",
          arguments: ["how was your weekend", "can we get some music on",
                      "suction please doctor", "what time is it"])
    func silentOnChatter(heard: String) {
        let r = Self.makeResolver()
        let result = r.resolve(heard, isFinal: true)
        #expect(result == .silent, "\"\(heard)\" produced \(result)")
    }

    @Test("A real instrument that is not open says so")
    func notOnField() {
        // Iris scissors are in the catalogue but GEN-01 is not registered.
        let r = Self.makeResolver(onField: [Self.metz, Self.mallet],
                                  catalogue: [Self.metz, Self.mallet, Self.iris])
        #expect(r.resolve("iris", isFinal: true) == .notOnField(displayName: "Iris Scissors, curved"))
    }

    @Test("Off-field lookup never overrides something that IS on the field")
    func onFieldWins() {
        let r = Self.makeResolver(onField: [Self.metz, Self.mallet],
                                  catalogue: [Self.metz, Self.mallet, Self.iris])
        #expect(r.resolve("metz", isFinal: true) == .commit(Self.metz.slot))
    }

    // MARK: - Control phrases

    @Test("Control phrases bypass instrument ranking",
          arguments: [("passed", ControlPhrase.passed), ("back", .returned)])
    func controlPhrases(input: String, expected: ControlPhrase) {
        let r = Self.makeResolver()
        #expect(r.resolve(input, isFinal: true) == .control(expected))
    }

    // MARK: - Priors

    @Test("Phase prior breaks a tie but cannot invent a match")
    func phasePrior() {
        let exposurePhase = Self.makeResolver(phase: .exposure)
        let closingPhase  = Self.makeResolver(phase: .closing)

        let inPhase = exposurePhase.rank("mallet").first!.score
        let outOfPhase = closingPhase.rank("mallet").first!.score
        #expect(inPhase > outOfPhase, "phase prior had no effect")

        // But the prior alone must never lift noise over the floor.
        #expect(exposurePhase.resolve("blue", isFinal: true) == .silent)
    }

    @Test("An instrument already marked in play is deprioritised")
    func recencyPenalty() {
        let clean  = Self.makeResolver()
        let marked = Self.makeResolver(marked: [Self.metz.slot])
        #expect(marked.rank("metz").first!.score < clean.rank("metz").first!.score)
        // Still resolvable though — the nurse may genuinely want it back.
        #expect(marked.resolve("metz", isFinal: true) == .commit(Self.metz.slot))
    }

    // MARK: - Number handling

    @Test("Digit and spelled-out number forms both resolve")
    func numberVariants() {
        let silk = Candidate(slot: .consumable("GEN-01", 0),
                             displayName: "3-0 Silk Tie",
                             aliases: ["three oh silk", "silk tie"],
                             usagePhase: nil)
        let r = Resolver(onField: [silk], catalogue: [silk])
        #expect(r.resolve("3-0 silk", isFinal: true) == .commit(silk.slot))
        #expect(r.resolve("three oh silk", isFinal: true) == .commit(silk.slot))
    }

    // MARK: - Vocabulary

    @Test("Contextual strings stay under the cap and lead with the short forms")
    func vocabularyCap() {
        let many = (0..<60).map {
            Self.candidate("T", $0, "Instrument \($0)",
                           ["a very long spoken form number \($0)", "x\($0)"])
        }
        let terms = Vocabulary.contextualStrings(for: many, phase: .setup, cap: 20)
        #expect(terms.count == 20)
        #expect(terms.allSatisfy { $0.count <= 30 }, "long forms crowded out the short ones")
    }
}

@Suite("Manifests")
struct ManifestTests {

    /// Read the manifests from source rather than from the built bundle: these
    /// are content-authoring tests, and they should fail the moment a bad
    /// coordinate is typed, not once someone remembers to rebuild.
    static func bundledManifests() -> [TrayManifest] {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()      // SecondSetTests
            .deletingLastPathComponent()      // repo root
            .appending(path: "SecondSet/Resources/Manifests")

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        return ManifestStore.load(urls: urls.filter { $0.pathExtension == "json" })
    }

    @Test("Every shipped manifest decodes")
    func allDecode() {
        let manifests = Self.bundledManifests()
        #expect(!manifests.isEmpty, "no manifests found in the bundle")
    }

    @Test("Slot coordinates are normalised and geometry is sane")
    func geometryIsSane() {
        for m in Self.bundledManifests() {
            let g = m.geometry
            #expect(g.interior.x > 0 && g.interior.z > 0, "\(m.trayID) has zero interior")
            #expect(g.slotHeight > 0 && g.slotHeight < 0.1, "\(m.trayID) slotHeight implausible")

            for slot in m.slots {
                #expect((0...1).contains(slot.u), "\(m.trayID)[\(slot.index)] u=\(slot.u) not normalised")
                #expect((0...1).contains(slot.v), "\(m.trayID)[\(slot.index)] v=\(slot.v) not normalised")
                #expect(!slot.aliases.isEmpty, "\(m.trayID)[\(slot.index)] has no aliases")
            }
        }
    }

    @Test("Slot indices are unique within a tray")
    func indicesUnique() {
        for m in Self.bundledManifests() {
            let indices = m.slots.map(\.index)
            #expect(Set(indices).count == indices.count, "\(m.trayID) has duplicate slot indices")
        }
    }

    /// Two instruments answering to the same word can never be separated by
    /// score, so the resolver will always produce a disambiguation card. That
    /// is correct behaviour — but only when it was intended. An undeclared
    /// collision is an authoring mistake that silently degrades a commit into
    /// a two-tap interaction, which is exactly what this product exists to
    /// avoid, so it must fail the build.
    @Test("Alias collisions within a tray are declared, not accidental")
    func aliasCollisionsAreDeclared() {
        for m in Self.bundledManifests() {
            var seen: [String: String] = [:]
            for slot in m.slots {
                for alias in slot.aliases.map({ $0.lowercased() }) {
                    if let other = seen[alias], !m.ambiguousAliases.contains(alias) {
                        Issue.record("""
                            \(m.trayID): "\(alias)" maps to both \(other) and \(slot.instrumentID). \
                            Either rename one, or add "\(alias)" to this tray's ambiguousAliases.
                            """)
                    }
                    seen[alias] = slot.instrumentID
                }
            }
        }
    }

    /// A declared ambiguous alias that only maps to one instrument is stale —
    /// it will commit rather than ask, and the demo beat will silently break.
    @Test("Declared ambiguous aliases really are ambiguous")
    func declaredAmbiguityIsReal() {
        for m in Self.bundledManifests() {
            for alias in m.ambiguousAliases {
                let owners = m.slots.filter { $0.aliases.map { $0.lowercased() }.contains(alias) }
                #expect(owners.count >= 2,
                        "\(m.trayID): \"\(alias)\" is declared ambiguous but maps to \(owners.count) instrument(s)")
            }
        }
    }

    @Test("Reference object names match their instrument IDs")
    func referenceObjectNaming() {
        // SPEC §10.6 — naming the reference object exactly the instrumentID
        // removes an entire mapping layer. Enforce the convention.
        for m in Self.bundledManifests() {
            for slot in m.slots {
                if let ref = slot.referenceObjectName {
                    #expect(ref == slot.instrumentID,
                            "\(m.trayID)[\(slot.index)] reference object \"\(ref)\" != id \"\(slot.instrumentID)\"")
                }
            }
        }
    }
}

import ARKit

@Suite("Markers")
struct MarkerTests {

    /// A malformed AR resource group does not fail the build — it just returns
    /// an empty array at runtime, and marker binding silently never works.
    /// That is a genuinely horrible thing to discover on stage, so assert it.
    @Test("Reference images load from the asset catalog")
    func referenceImagesLoad() {
        let images = ReferenceImage.loadReferenceImages(inGroupNamed: "Markers")
        #expect(!images.isEmpty, "asset group \"Markers\" produced no reference images")
    }

    /// Wrong physical size means wrong depth, and the highlight floats above or
    /// sinks below the tray. The markers are authored at 15 cm.
    @Test("Every marker declares a plausible physical size")
    func physicalSizes() {
        for image in ReferenceImage.loadReferenceImages(inGroupNamed: "Markers") {
            let w = image.physicalSize.width
            #expect(w > 0.08 && w < 0.40,
                    "\(image.name ?? "unnamed") declares \(w) m — SPEC §8 wants >= 10 cm")
        }
    }

    /// Every manifest's markerImageName must exist in the catalog, or that tray
    /// can never bind by marker and will silently need a manual bind.
    @Test("Manifest marker names match the asset catalog")
    func namesMatchManifests() {
        let available = Set(ReferenceImage.loadReferenceImages(inGroupNamed: "Markers")
            .compactMap(\.name))
        for m in ManifestTests.bundledManifests() {
            #expect(available.contains(m.markerImageName),
                    "\(m.trayID) wants marker \"\(m.markerImageName)\", catalog has \(available.sorted())")
        }
    }
}
