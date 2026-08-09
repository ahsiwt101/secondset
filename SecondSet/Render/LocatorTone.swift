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
        let toneDuration = 0.15
        let frequency = 880.0
        let amplitude = 0.5

        let totalSamples = Int(sampleRate * loopDuration)
        let toneSamples = Int(sampleRate * toneDuration)
        let attackSamples = Int(sampleRate * 0.01)
        let releaseSamples = Int(sampleRate * 0.06)

        var samples = [Int16](repeating: 0, count: totalSamples)
        for i in 0..<toneSamples {
            let t = Double(i) / sampleRate
            var envelope = 1.0
            if i < attackSamples {
                envelope = Double(i) / Double(attackSamples)
            } else if i > toneSamples - releaseSamples {
                envelope = Double(toneSamples - i) / Double(releaseSamples)
            }
            let value = sin(2 * .pi * frequency * t) * amplitude * envelope
            samples[i] = Int16(max(-1, min(1, value)) * Double(Int16.max))
        }

        return wav(from: samples, sampleRate: Int(sampleRate))
    }

    private static func wav(from samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        let byteRate = sampleRate * 2
        let dataSize = samples.count * 2

        func append(_ s: StaticString) { s.withUTF8Buffer { data.append(contentsOf: $0) } }
        func append(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF" as StaticString)
        append(UInt32(36 + dataSize))
        append("WAVE" as StaticString)
        append("fmt " as StaticString)
        append(UInt32(16))              // PCM fmt chunk size
        append(UInt16(1))               // PCM
        append(UInt16(1))               // mono
        append(UInt32(sampleRate))
        append(UInt32(byteRate))
        append(UInt16(2))               // block align
        append(UInt16(16))              // bits per sample
        append("data" as StaticString)
        append(UInt32(dataSize))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }

        return data
    }
}
