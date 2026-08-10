import Foundation

/// The far-mode beam only helps once it's already in view — nothing can
/// render outside the headset's field of view, so a beam behind the wearer
/// is invisible no matter how tall or bright. A spatial audio ping anchored
/// to the target's position sidesteps that entirely: real head-tracked
/// stereo tells you which way to turn before your eyes ever could.
///
/// Synthesized in code rather than bundled as a file, the same "generate at
/// launch" approach `GradientTextures.swift` uses for the beam's gradients —
/// one less asset to ship or get the import settings wrong on.
enum LocatorTone {

    /// A short tone followed by silence, looped. The silence is what makes it
    /// read as a locator pulse rather than a drone.
    static func wavData() -> Data {
        let sampleRate = 44100.0
        let loopDuration = 1.1

        var samples = [Int16](repeating: 0, count: Int(sampleRate * loopDuration))
        let tone = WavEncoder.tone(frequency: 880, duration: 0.15,
                                   sampleRate: sampleRate, amplitude: 0.5)
        samples.replaceSubrange(0..<tone.count, with: tone)

        return WavEncoder.pcm16(samples, sampleRate: Int(sampleRate))
    }
}
