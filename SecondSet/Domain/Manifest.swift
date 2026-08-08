import Foundation
import simd

// SPEC §11. The JSON on disk is hand-authored from an overhead photograph, so
// the decode path stays forgiving: unknown keys (the `_units` / `_note`
// annotations) are ignored, and every optional has a sane default.

struct TrayManifest: Codable, Sendable, Identifiable {
    let trayID: String
    let displayName: String
    let procedure: String?
    let markerImageName: String
    let geometry: TrayGeometry
    let slots: [SlotSpec]
    let consumables: [ConsumableSpec]

    /// Spoken forms that deliberately map to more than one item on this tray,
    /// and should therefore produce the disambiguation card rather than a
    /// commit. Genuine ambiguity is a feature — "spreader" really does mean
    /// two different retractors — but it has to be *declared*, so that an
    /// accidental alias collision still fails the content tests.
    let ambiguousAliases: [String]

    var id: String { trayID }

    enum CodingKeys: String, CodingKey {
        case trayID, displayName, procedure, markerImageName, geometry, slots
        case consumables, ambiguousAliases
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trayID          = try c.decode(String.self, forKey: .trayID)
        displayName     = try c.decode(String.self, forKey: .displayName)
        procedure       = try c.decodeIfPresent(String.self, forKey: .procedure)
        markerImageName = try c.decode(String.self, forKey: .markerImageName)
        geometry        = try c.decode(TrayGeometry.self, forKey: .geometry)
        slots           = try c.decode([SlotSpec].self, forKey: .slots)
        consumables     = try c.decodeIfPresent([ConsumableSpec].self, forKey: .consumables) ?? []
        ambiguousAliases = (try c.decodeIfPresent([String].self, forKey: .ambiguousAliases) ?? [])
            .map { $0.lowercased() }
    }
}

struct TrayGeometry: Codable, Sendable {
    /// [width(x), height(y), length(z)] of the tray interior, in metres.
    private let interiorSize: [Float]
    /// Pose of the TRAY origin expressed in MARKER space. Split into
    /// translation + yaw so it stays hand-measurable: markers mount flat, so
    /// roll and pitch are zero by construction. SPEC §7.
    private let trayOriginInMarkerSpace: [Float]
    private let trayYawInMarkerSpaceDegrees: Float
    /// How far above the tray floor a highlight quad sits, in metres.
    let slotHeight: Float

    var interior: SIMD3<Float> {
        SIMD3(interiorSize.count == 3 ? interiorSize : [0, 0, 0])
    }

    var trayOriginInMarker: SIMD3<Float> {
        SIMD3(trayOriginInMarkerSpace.count == 3 ? trayOriginInMarkerSpace : [0, 0, 0])
    }

    var trayYawInMarker: Float {
        trayYawInMarkerSpaceDegrees * .pi / 180
    }

    /// markerFromTray. A physical measurement, not a guess — get it wrong and
    /// every highlight on the tray shifts by a constant offset, which is also
    /// the easiest bug in the build to spot. SPEC §7.
    var markerFromTray: simd_float4x4 {
        simd_float4x4(translation: trayOriginInMarker) * simd_float4x4(yaw: trayYawInMarker)
    }
}

struct SlotSpec: Codable, Sendable {
    let index: Int
    let instrumentID: String
    let displayName: String
    let aliases: [String]
    /// Normalised [0,1] over the tray interior footprint, so a layout can be
    /// authored from a photograph with no metric measurement. SPEC §11.
    let u: Float
    let v: Float
    /// [width, length] in metres. Sizes the highlight quad to hug the
    /// instrument instead of being a fixed dot — matters more than it sounds.
    private let footprint: [Float]
    /// Human string, decoupled from geometry so it can match the hospital's
    /// own count sheet wording.
    let label: String
    /// Nil for the overwhelming majority of slots. Only hero instruments get
    /// a trained reference object. SPEC §10.
    let referenceObjectName: String?
    let usagePhase: String?

    var footprintSize: SIMD2<Float> {
        SIMD2(footprint.count == 2 ? footprint : [0.04, 0.12])
    }

    /// Position of this slot in tray space.
    var trayFromSlot: (TrayGeometry) -> simd_float4x4 {
        { g in
            simd_float4x4(translation: SIMD3(u * g.interior.x,
                                             g.slotHeight,
                                             v * g.interior.z))
        }
    }

    enum CodingKeys: String, CodingKey {
        case index, instrumentID, displayName, aliases, u, v, footprint, label
        case referenceObjectName, usagePhase
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index               = try c.decode(Int.self, forKey: .index)
        instrumentID        = try c.decode(String.self, forKey: .instrumentID)
        displayName         = try c.decode(String.self, forKey: .displayName)
        aliases             = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        u                   = try c.decode(Float.self, forKey: .u)
        v                   = try c.decode(Float.self, forKey: .v)
        footprint           = try c.decodeIfPresent([Float].self, forKey: .footprint) ?? [0.04, 0.12]
        label               = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        referenceObjectName = try c.decodeIfPresent(String.self, forKey: .referenceObjectName)
        usagePhase          = try c.decodeIfPresent(String.self, forKey: .usagePhase)
    }
}

/// Tier 2. The printed packet label IS the reference image — no training,
/// no modification, it was already glued to the item. SPEC §9.
struct ConsumableSpec: Codable, Sendable {
    let consumableID: String
    let displayName: String
    let aliases: [String]
    let referenceImageName: String
}
