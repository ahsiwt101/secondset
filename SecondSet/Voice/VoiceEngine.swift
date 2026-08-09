import Foundation
import Speech
import AVFoundation
import QuartzCore

// SPEC §12. On-device only: an OR audio stream leaving the building is a
// non-starter, and network latency would kill the interaction regardless.
// Nothing is recorded or persisted — rolling buffer, discarded.

@MainActor
final class VoiceEngine: VoiceProvider {

    let requests: AsyncStream<VoiceRequest>
    private let continuation: AsyncStream<VoiceRequest>.Continuation

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var resolver: Resolver?
    private var lastCommit: TimeInterval = 0
    private(set) var isListening = false

    /// Always-on ambient capture, so a request the surgeon speaks aloud appears
    /// on its own without the nurse doing anything — which is the whole point.
    ///
    /// On by default despite SPEC §12.1's caution: the mic array is beamformed
    /// toward the wearer, so a masked surgeon two metres off-axis may not be
    /// picked up reliably. If the hour-zero mic test shows that, this becomes
    /// the nurse repeating the request rather than the surgeon being overheard
    /// — the interaction is identical either way, so nothing downstream cares.
    var ambientMode = true

    init() {
        (requests, continuation) = AsyncStream.makeStream()
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard let recognizer, recognizer.isAvailable else { throw VoiceError.recognizerUnavailable }
        guard recognizer.supportsOnDeviceRecognition else { throw VoiceError.onDeviceUnsupported }

        // @Sendable pins this closure as nonisolated. Without it, the compiler
        // infers MainActor isolation from the enclosing method (the SDK's
        // handler parameter isn't marked @Sendable), and Swift 6's strict
        // concurrency then inserts a dynamic check that the closure actually
        // runs on the main actor. It doesn't: TCC invokes this completion
        // handler from its own XPC reply queue, not the main actor, so that
        // check trapped instead of throwing — the app died before any
        // permission dialog could show. `resume` is safe from any thread by
        // design, so nonisolated is also the correct fix, not just the one
        // that avoids the trap.
        let speechOK = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                c.resume(returning: status == .authorized)
            }
        }
        guard speechOK else { throw VoiceError.permissionDenied }

        let micOK = await AVAudioApplication.requestRecordPermission()
        guard micOK else { throw VoiceError.permissionDenied }

        // `.measurement` asks the platform to skip AGC and noise suppression.
        // Whether it honours that is exactly what the hour-zero mic test
        // measures. SPEC §2.2.
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        if ambientMode { try beginRecognition() }
    }

    func stop() async {
        endRecognition()
        continuation.finish()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func setResolver(_ resolver: Resolver) {
        self.resolver = resolver
        // Rebuild the constrained vocabulary on every tray register. Only what
        // is actually on the field, ranked by expected frequency, capped —
        // contextualStrings degrades well before any hard limit. SPEC §12.3.
        request?.contextualStrings = Vocabulary.contextualStrings(
            for: resolver.onField, phase: resolver.phase)
    }

    func beginListening() {
        guard !isListening else { return }
        do {
            try beginRecognition()
            isListening = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Tunables.listenWindow))
                guard let self, !self.ambientMode else { return }
                self.endRecognition()
                self.isListening = false
            }
        } catch {
            Log.voice.error("Could not begin listening: \(error.localizedDescription)")
        }
    }

    // MARK: - Recognition

    private func beginRecognition() throws {
        endRecognition()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true   // hard requirement
        request.shouldReportPartialResults = true    // required for early commit
        request.taskHint = .search                   // short, keyword-like
        if let resolver {
            request.contextualStrings = Vocabulary.contextualStrings(
                for: resolver.onField, phase: resolver.phase)
        }
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)

        // The tap callback is real-time: no allocation, no locking, no await.
        // Copy the buffer into the recognition request and return. SPEC §15.
        // @Sendable for the same reason as the two closures above — this one
        // is the one that actually crashed: the tap runs on AVAudioEngine's
        // real-time thread (confirmed via the trap's own backtrace, inside
        // AVAudioNodeTap::TapMessage::RealtimeMessenger_Perform), never the
        // main actor, so an inferred MainActor isolation here is guaranteed
        // to trap on literally every audio buffer.
        let box = RequestBox(request)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            box.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        // @Sendable for the same reason as the authorization closure above:
        // Speech invokes this from its own internal queue, not the main
        // actor, and an inferred MainActor isolation here traps instead of
        // just hopping via the Task below.
        task = recognizer?.recognitionTask(with: request) { @Sendable [weak self] result, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in Log.voice.debug("Recognition ended: \(error.localizedDescription)") }
                return
            }
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            Task { @MainActor in self.consume(text, isFinal: isFinal) }
        }
    }

    private func endRecognition() {
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }

    // MARK: - Decision

    private func consume(_ text: String, isFinal: Bool) {
        guard let resolver else { return }

        // Partials mutate as recognition refines. Without this lock a single
        // utterance fires two highlights. 800 ms, not 1200 — the demo script
        // asks for three instruments in quick succession and a longer lock
        // silently swallows one. SPEC §12.4.
        let now = CACurrentMediaTime()
        if now - lastCommit < Tunables.commitLockout { return }

        switch resolver.resolve(text, isFinal: isFinal) {
        case .commit(let ref):
            lastCommit = now
            continuation.yield(.resolved(ref, heard: text))
        case .ambiguous(let refs):
            lastCommit = now
            continuation.yield(.ambiguous(refs, heard: text))
        case .notOnField(let name):
            lastCommit = now
            continuation.yield(.notOnField(displayName: name, heard: text))
        case .control(.passed):
            lastCommit = now
            continuation.yield(.markPassed)
        case .control(.returned):
            lastCommit = now
            continuation.yield(.markReturned)
        case .silent:
            if isFinal { continuation.yield(.silent(heard: text)) }
        }
    }
}

/// The audio tap runs on a real-time thread and cannot hop actors. The
/// recognition request is not Sendable, but `append` is safe to call from the
/// tap — this box makes that assumption explicit and auditable in one place
/// rather than scattering `nonisolated(unsafe)` through the engine.
private final class RequestBox: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
}
