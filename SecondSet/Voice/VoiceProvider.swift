import Foundation

// SPEC §6. The resolver runs inside the voice layer, so the domain only ever
// receives decisions. Never raw text.

@MainActor
protocol VoiceProvider: AnyObject {

    var requests: AsyncStream<VoiceRequest> { get }

    /// Rebuild the constrained vocabulary. Called on every tray register.
    /// SPEC §12.3 — contextualStrings degrades well before any hard limit,
    /// so this submits only what is on the field, capped.
    func setResolver(_ resolver: Resolver)

    /// Open a listening window. Pinch-to-find is deterministic and works in
    /// noise, which is why it is the primary trigger and the wake phrase is
    /// the convenience. SPEC §12.1.
    func beginListening()

    func start() async throws
    func stop() async
}

enum VoiceError: Error, LocalizedError {
    case recognizerUnavailable
    case permissionDenied
    case onDeviceUnsupported

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognition is unavailable. Use the instrument list."
        case .permissionDenied:
            return "Microphone or speech permission was denied."
        case .onDeviceUnsupported:
            return "On-device recognition is unavailable for this locale."
        }
    }
}
