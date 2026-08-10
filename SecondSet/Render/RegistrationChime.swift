import Foundation

/// Plays once when a tray transitions from unbound to bound — confirmation
/// that doesn't require looking at the 2D setup list to notice. Deliberately
/// a different shape from `LocatorTone`: a short two-note rise, not a
/// repeating pulse, so the two are never confused for each other mid-case.
enum RegistrationChime {

    static func wavData() -> Data {
        let sampleRate = 44100.0
        let note1 = WavEncoder.tone(frequency: 660, duration: 0.09,
                                    sampleRate: sampleRate, amplitude: 0.45,
                                    attack: 0.004, release: 0.02)
        let note2 = WavEncoder.tone(frequency: 990, duration: 0.16,
                                    sampleRate: sampleRate, amplitude: 0.45,
                                    attack: 0.004, release: 0.06)
        return WavEncoder.pcm16(note1 + note2, sampleRate: Int(sampleRate))
    }
}
