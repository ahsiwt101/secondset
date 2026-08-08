import RealityKit
import UIKit

// SPEC §14. One meaning per colour, and no red anywhere — red in a theatre
// means something else entirely, and a judge who works in one will notice.
//
// Materials are created exactly once and shared. The performance budget allows
// ten unique materials in the whole app because material compilation is the
// single largest source of frame hitches, and a hitch on the key interaction
// is the one thing that cannot happen.

@MainActor
enum Palette {

    static let cyan  = UIColor(red: 0.30, green: 0.85, blue: 0.95, alpha: 1.0)
    static let amber = UIColor(red: 1.00, green: 0.72, blue: 0.30, alpha: 1.0)
    static let ghost = UIColor(white: 0.75, alpha: 1.0)

    /// Unlit and additive: reads through bright theatre lighting, costs almost
    /// nothing, and needs no custom shader. SPEC §14 — start here, and only
    /// reach for an inverted-hull outline if there is time left over.
    private static func glow(_ color: UIColor, opacity: Float) -> UnlitMaterial {
        var m = UnlitMaterial(color: color)
        m.blending = .transparent(opacity: .init(floatLiteral: opacity))
        m.faceCulling = .none
        return m
    }

    /// Tier 1 — "should be here". Deliberately softer than confirmed.
    static let asPacked  = glow(cyan, opacity: 0.38)
    /// Tier 2/3 — "that one, right there". Brighter, and it hugs the object.
    static let confirmed = glow(cyan, opacity: 0.70)
    /// Tray-level rim glow for far mode.
    static let trayRim   = glow(cyan, opacity: 0.30)
    /// Needs a choice.
    static let ambiguous = glow(amber, opacity: 0.45)
    /// Marked in play — an empty position, visible at a glance.
    static let ghostSlot = glow(ghost, opacity: 0.18)
    /// Callout text.
    static let text      = UnlitMaterial(color: .white)
}
