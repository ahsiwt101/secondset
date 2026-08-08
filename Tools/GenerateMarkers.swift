#!/usr/bin/env swift
// Generates tray marker reference images to SPEC §8.
//
//   swift Tools/GenerateMarkers.swift Markers/
//
// Design notes, because "random noise" is the obvious wrong answer here:
//
//  * Per-pixel noise does NOT survive printing and camera blur. Feature
//    detectors need structure at several scales, so this draws blobs across a
//    range of sizes instead.
//  * No rotational symmetry — a symmetric marker is orientation-ambiguous and
//    the tray renders rotated. Each marker gets an asymmetric corner wedge.
//  * High contrast, pure black on white, no mid-greys to be crushed by
//    theatre lighting.
//  * Deterministic per seed, so a reprint is identical to the original.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Reproducible PRNG so regenerating a marker gives byte-identical output.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

func makeMarker(name: String, seed: UInt64, darkBias: Double = 0.5, size: Int = 2048) -> CGImage? {
    var rng = SplitMix64(seed: seed)
    let space = CGColorSpaceCreateDeviceGray()
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: space,
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }

    let s = CGFloat(size)
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

    // Quiet margin: detectors need the pattern bounded by white.
    let margin = s * 0.06
    let inner = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    ctx.clip(to: inner)

    // Multi-scale blobs. Large shapes give the detector coarse structure to
    // lock onto at distance; small ones give fine features up close.
    //
    // The large tier is deliberately modest: oversized blobs coalesce into a
    // solid mass, and a solid mass has no features at all. Coverage is
    // asserted at the end of this function rather than eyeballed.
    let scales: [(count: Int, minR: CGFloat, maxR: CGFloat)] = [
        (10,  s * 0.055, s * 0.110),
        (48,  s * 0.028, s * 0.062),
        (190, s * 0.010, s * 0.026),
        (520, s * 0.003, s * 0.009),
    ]

    for tier in scales {
        for i in 0..<tier.count {
            // Deterministic well-spread alternation rather than a coin flip:
            // random fill colour streaks, and a streak of same-colour large
            // blobs is exactly how the solid-mass failure happens. The bias is
            // swept by the caller against measured coverage, because painting
            // white on a white ground is a no-op and an even split therefore
            // converges far darker-poor than it looks like it should.
            let dark = Double((i &* 7) % 10) < darkBias * 10
            ctx.setFillColor(gray: dark ? 0 : 1, alpha: 1)
            let r = CGFloat.random(in: tier.minR...tier.maxR, using: &rng)
            let cx = CGFloat.random(in: inner.minX...inner.maxX, using: &rng)
            let cy = CGFloat.random(in: inner.minY...inner.maxY, using: &rng)

            if Bool.random(using: &rng) {
                ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            } else {
                // Rotated rectangles add corner features, which is what most
                // detectors actually key on.
                ctx.saveGState()
                ctx.translateBy(x: cx, y: cy)
                ctx.rotate(by: CGFloat.random(in: 0...(2 * .pi), using: &rng))
                let w = r * CGFloat.random(in: 0.6...2.2, using: &rng)
                let h = r * CGFloat.random(in: 0.6...2.2, using: &rng)
                ctx.fill(CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                ctx.restoreGState()
            }
        }
    }

    // Orientation key: a solid wedge in exactly one corner. Breaks every
    // rotational symmetry, so the tray can never bind 90° or 180° out.
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.move(to: CGPoint(x: inner.minX, y: inner.minY))
    ctx.addLine(to: CGPoint(x: inner.minX + s * 0.17, y: inner.minY))
    ctx.addLine(to: CGPoint(x: inner.minX, y: inner.minY + s * 0.17))
    ctx.closePath()
    ctx.fillPath()

    return ctx.makeImage()
}

/// Fraction of the image that is dark. A marker that is mostly one tone has
/// poor feature density regardless of how many shapes went into it, so this is
/// checked rather than assumed.
func inkCoverage(_ image: CGImage) -> Double {
    let w = image.width, h = image.height
    var buffer = [UInt8](repeating: 0, count: w * h)
    guard let ctx = CGContext(data: &buffer, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let dark = buffer.reduce(into: 0) { acc, px in if px < 128 { acc += 1 } }
    return Double(dark) / Double(w * h)
}

// MARK: - Main

let outDir = CommandLine.arguments.count > 1
    ? URL(filePath: CommandLine.arguments[1])
    : URL(filePath: "Markers")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Names must match `markerImageName` in the manifests.
let markers: [(String, UInt64)] = [
    ("marker_ort_01", 0xA11CE),
    ("marker_ort_02", 0xB0B),
    ("marker_gen_01", 0xC0FFEE),
    ("marker_demo_01", 0xD00D),
]

for (name, seed) in markers {
    // Sweep the dark bias against measured coverage and keep the best result.
    // Deterministic, so a regenerated marker is byte-identical to the printed
    // one — reprinting a marker that no longer matches the bundle would be a
    // genuinely awful bug to debug at hour 40.
    let target = 0.46
    var image: CGImage?
    var coverage = 0.0
    var bestDistance = Double.infinity

    for bias in stride(from: 0.50, through: 0.92, by: 0.06) {
        guard let candidate = makeMarker(name: name, seed: seed, darkBias: bias) else { continue }
        let c = inkCoverage(candidate)
        let distance = abs(c - target)
        if distance < bestDistance {
            bestDistance = distance; image = candidate; coverage = c
        }
        if distance < 0.04 { break }
    }
    guard let image else { print("failed: \(name)"); continue }
    if !(0.34...0.60).contains(coverage) {
        print("⚠️  \(name): ink coverage \(String(format: "%.0f%%", coverage * 100)) — check the quality rating in Xcode")
    }

    let url = outDir.appending(path: "\(name).png")
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.lastPathComponent)  (ink \(String(format: "%.0f%%", coverage * 100)))")
}

print("""

Next:
  1. Print each at EXACTLY 15 cm x 15 cm. Matte paper. No scaling in the
     print dialog — "actual size", not "fit to page".
  2. Mount flat on rigid backing. Never on sterile wrap: it is semi-reflective
     and it wrinkles, and both destroy pose estimation.
  3. In Xcode, add each to Assets.xcassets > Markers, and set the physical
     width to 0.15. Wrong size means wrong depth, and the highlight floats.
  4. Check the quality rating on each. Reject anything not rated high.
""")
