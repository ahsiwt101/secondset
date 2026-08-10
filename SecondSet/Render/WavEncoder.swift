import Foundation

/// Shared by every procedurally-synthesized UI tone (`LocatorTone`,
/// `RegistrationChime`) — one PCM/WAV writer and one enveloped-sine-tone
/// generator rather than duplicating bit-packing per sound.
enum WavEncoder {

    /// A single sine tone with a linear attack/release envelope, as raw
    /// samples — no silence padding. Callers compose these into a full
    /// buffer (looped with trailing silence, or concatenated into a chime).
    static func tone(frequency: Double,
                     duration: Double,
                     sampleRate: Double,
                     amplitude: Double,
                     attack: Double = 0.01,
                     release: Double = 0.06) -> [Int16] {
        let count = Int(sampleRate * duration)
        let attackSamples = Int(sampleRate * attack)
        let releaseSamples = Int(sampleRate * release)

        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            var envelope = 1.0
            if i < attackSamples {
                envelope = Double(i) / Double(attackSamples)
            } else if i > count - releaseSamples {
                envelope = Double(count - i) / Double(releaseSamples)
            }
            let value = sin(2 * .pi * frequency * t) * amplitude * envelope
            samples[i] = Int16(max(-1, min(1, value)) * Double(Int16.max))
        }
        return samples
    }

    static func pcm16(_ samples: [Int16], sampleRate: Int) -> Data {
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
