import Foundation

// SPEC §18. One button per vocabulary term, plus the paths that are hard to
// trigger deliberately with a real microphone: a near-miss that should produce
// the disambiguation card, and garbage that should produce nothing at all.

@MainActor
final class MockVoiceProvider: VoiceProvider {

    let requests: AsyncStream<VoiceRequest>
    private let continuation: AsyncStream<VoiceRequest>.Continuation

    private(set) var resolver: Resolver?
    private(set) var isListening = false

    /// Every term currently on the field, for the debug panel's button grid.
    var vocabulary: [String] {
        guard let resolver else { return [] }
        return Vocabulary.contextualStrings(for: resolver.onField, phase: resolver.phase, cap: 200)
    }

    init() {
        (requests, continuation) = AsyncStream.makeStream()
    }

    func start() async throws {}
    func stop() async { continuation.finish() }

    func setResolver(_ resolver: Resolver) {
        self.resolver = resolver
    }

    func beginListening() {
        isListening = true
        Task {
            try? await Task.sleep(for: .seconds(Tunables.listenWindow))
            isListening = false
        }
    }

    /// Run a phrase through the real resolver. The mock fakes the microphone,
    /// never the decision logic — otherwise the thing under test is not the
    /// thing that ships.
    func say(_ phrase: String, isFinal: Bool = true) {
        guard let resolver else {
            continuation.yield(.silent(heard: phrase))
            return
        }

        switch resolver.resolve(phrase, isFinal: isFinal) {
        case .commit(let ref):
            continuation.yield(.resolved(ref, heard: phrase))
        case .ambiguous(let refs):
            continuation.yield(.ambiguous(refs, heard: phrase))
        case .notOnField(let name):
            continuation.yield(.notOnField(displayName: name, heard: phrase))
        case .control(.passed):
            continuation.yield(.markPassed)
        case .control(.returned):
            continuation.yield(.markReturned)
        case .silent:
            continuation.yield(.silent(heard: phrase))
        }
    }

    func injectGarbage() {
        say(["how was your weekend", "can we get some music on",
             "what time did we start", "is the patient warm"].randomElement()!)
    }
}
