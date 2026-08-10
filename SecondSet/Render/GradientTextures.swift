import CoreGraphics
import RealityKit
import UIKit

// The difference between a beam that reads as volumetric light and one that
// reads as a plastic tube is entirely in the alpha ramp. Rather than ship
// artwork, generate the ramps procedurally at launch — same approach as
// Tools/GenerateMarkers.swift, and it keeps them tunable in one place.
//
// Generated once and cached. Material and texture creation are the frame-hitch
// sources this app most needs to avoid (SPEC §17), so nothing here runs in
// response to a request.

@MainActor
enum GradientTextures {

    /// Vertical ramp: opaque at the base, fading to nothing at the top.
    /// Applied to the beam cylinder so it dissolves into the air rather than
    /// ending in a hard disc.
    static let verticalFade: TextureResource? = make(width: 8, height: 256) { ctx, w, h in
        for y in 0..<h {
            // V runs top-to-bottom in image space, so invert: the *bottom* of
            // the image is the base of the beam.
            let t = Float(y) / Float(h - 1)
            // Cubic falloff keeps the base solid and the tail long and soft.
            let alpha = pow(t, 2.2)
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: CGFloat(alpha))
            ctx.fill(CGRect(x: 0, y: y, width: w, height: 1))
        }
    }

    /// Radial pool where the beam meets the tray. Bright core, long soft edge.
    static let radialPool: TextureResource? = make(width: 256, height: 256) { ctx, w, h in
        let c = CGFloat(w) / 2
        for r in stride(from: c, to: 0, by: -1) {
            let t = 1 - (r / c)
            let alpha = pow(t, 2.0) * 0.9
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: alpha)
            ctx.fillEllipse(in: CGRect(x: c - r, y: c - r, width: r * 2, height: r * 2))
        }
    }

    /// Ring for the halo: transparent centre so the object stays visible,
    /// a bright band, then a soft outer falloff.
    static let ring: TextureResource? = make(width: 256, height: 256) { ctx, w, h in
        let c = CGFloat(w) / 2
        let peak: CGFloat = 0.82          // band position, as a fraction of radius
        let width: CGFloat = 0.16
        for r in stride(from: c, to: 0, by: -0.5) {
            let t = r / c
            let d = abs(t - peak) / width
            guard d < 1 else { continue }
            let alpha = pow(1 - d, 2.0)
            ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: alpha)
            ctx.setLineWidth(1.2)
            ctx.strokeEllipse(in: CGRect(x: c - r, y: c - r, width: r * 2, height: r * 2))
        }
    }

    /// Glowing rounded-rect border, transparent centre. Stretched onto
    /// whatever aspect ratio a tray's footprint plane has, so the border
    /// reads slightly thicker on the long edge of an elongated tray — an
    /// acceptable trade for a texture that doesn't need regenerating per
    /// tray shape, and the effect is on-screen for under two seconds.
    static let frame: TextureResource? = make(width: 256, height: 256) { ctx, w, h in
        let inset: CGFloat = 16
        let rect = CGRect(x: inset, y: inset,
                          width: CGFloat(w) - inset * 2, height: CGFloat(h) - inset * 2)
        let path = CGPath(roundedRect: rect, cornerWidth: 22, cornerHeight: 22, transform: nil)

        for i in stride(from: 10, through: 2, by: -2) {
            let t = CGFloat(i) / 10
            ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: (1 - t) * 0.35 + 0.05)
            ctx.setLineWidth(CGFloat(i) * 2.2)
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1.0)
        ctx.setLineWidth(3)
        ctx.addPath(path)
        ctx.strokePath()
    }

    /// Soft round sprite for individual particles. A default square particle is
    /// the single most obvious tell that an effect was not art-directed.
    static let mote: TextureResource? = make(width: 64, height: 64) { ctx, w, h in
        let c = CGFloat(w) / 2
        for r in stride(from: c, to: 0, by: -0.5) {
            let t = 1 - (r / c)
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: pow(t, 1.6))
            ctx.fillEllipse(in: CGRect(x: c - r, y: c - r, width: r * 2, height: r * 2))
        }
    }

    // MARK: - Plumbing

    private static func make(width: Int,
                             height: Int,
                             _ draw: (CGContext, Int, Int) -> Void) -> TextureResource? {
        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        draw(ctx, width, height)

        guard let image = ctx.makeImage() else { return nil }
        do {
            return try TextureResource(image: image,
                                       withName: nil,
                                       options: .init(semantic: .color))
        } catch {
            Log.render.error("Gradient texture failed: \(error.localizedDescription)")
            return nil
        }
    }
}
