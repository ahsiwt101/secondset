import RealityKit
import UIKit

// SPEC §14, revised. One meaning per colour, and no red anywhere — red in a
// theatre means something else, and a judge who works in one will notice.
//
//   gold  = this is the one you asked for
//   cyan  = a candidate you must choose between
//   grey  = marked in play, off the tray
//
// Ambiguity is deliberately NOT a colour change any more. It used to be amber,
// which now collides with gold. Multiple simultaneous cyan beacons communicate
// "pick one" far better than a hue shift does, and it keeps the mapping clean.
//
// Materials are created once and shared. The budget is ten unique materials in
// the whole app, because material compilation is the largest single source of
// frame hitches and a hitch on the key interaction is the one thing that
// cannot happen.

@MainActor
enum Palette {

    /// Warm gold. Reads as "precious / found" and survives bright rooms.
    static let gold  = UIColor(red: 1.00, green: 0.78, blue: 0.42, alpha: 1.0)
    static let cyan  = UIColor(red: 0.30, green: 0.85, blue: 0.95, alpha: 1.0)
    static let ghost = UIColor(white: 0.75, alpha: 1.0)

    // MARK: - Beacon materials

    /// The beam core. Additive so it behaves like light rather than paint, and
    /// textured with a vertical ramp so it dissolves upward instead of ending
    /// in a hard disc.
    static func beam(_ tint: UIColor, intensity: Float) -> UnlitMaterial {
        var m = UnlitMaterial(color: tint)
        if let ramp = GradientTextures.verticalFade {
            m.color = .init(tint: tint, texture: .init(ramp))
        }
        m.blending = .transparent(opacity: .init(floatLiteral: intensity))
        m.faceCulling = .none
        return m
    }

    /// Soft disc where the beam meets the tray.
    static func pool(_ tint: UIColor, intensity: Float) -> UnlitMaterial {
        var m = UnlitMaterial(color: tint)
        if let tex = GradientTextures.radialPool {
            m.color = .init(tint: tint, texture: .init(tex))
        }
        m.blending = .transparent(opacity: .init(floatLiteral: intensity))
        m.faceCulling = .none
        return m
    }

    /// Crisp band under the halo particles, so the effect has an edge to read
    /// against rather than being a formless cloud.
    static func ring(_ tint: UIColor, intensity: Float) -> UnlitMaterial {
        var m = UnlitMaterial(color: tint)
        if let tex = GradientTextures.ring {
            m.color = .init(tint: tint, texture: .init(tex))
        }
        m.blending = .transparent(opacity: .init(floatLiteral: intensity))
        m.faceCulling = .none
        return m
    }

    // MARK: - Prebuilt instances (created once)

    static let goldBeam   = beam(gold, intensity: 0.85)
    static let goldSheath = beam(gold, intensity: 0.22)
    static let goldPool   = pool(gold, intensity: 0.75)
    static let goldRing   = ring(gold, intensity: 0.80)

    static let cyanBeam   = beam(cyan, intensity: 0.55)
    static let cyanSheath = beam(cyan, intensity: 0.15)
    static let cyanPool   = pool(cyan, intensity: 0.45)

    /// Marked in play — a dimmed empty position, visible at a glance.
    static let ghostSlot: UnlitMaterial = {
        var m = UnlitMaterial(color: ghost)
        m.blending = .transparent(opacity: .init(floatLiteral: 0.18))
        m.faceCulling = .none
        return m
    }()

    static let text = UnlitMaterial(color: .white)
}
