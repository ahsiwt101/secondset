import Foundation
import simd

// SPEC §6. Every type that crosses an actor boundary is a Sendable value type.
// `Entity` never appears in this file and never will.

// MARK: - Identity

/// Points at one item in one tray. The universal address of anything the
/// system can highlight.
///
/// Consumables live in the same address space using negative indices, so the
/// resolver, the renderer and the marked-in-play set all stay single-typed.
/// SPEC §9 — packet labels are Tier 2 and need to be requestable by voice
/// exactly like instruments.
struct SlotRef: Hashable, Sendable, Codable {
    let trayID: String
    let index: Int

    var isConsumable: Bool { index < 0 }

    /// Position in the manifest's `consumables` array, for a consumable ref.
    var consumableIndex: Int? { index < 0 ? -(index + 1) : nil }

    static func instrument(_ trayID: String, _ index: Int) -> SlotRef {
        SlotRef(trayID: trayID, index: index)
    }

    static func consumable(_ trayID: String, _ index: Int) -> SlotRef {
        SlotRef(trayID: trayID, index: -(index + 1))
    }
}

/// Which of the three perception tiers produced a position. SPEC §3.
/// Drives the visual treatment and the wording of the callout. This is the
/// type that keeps "we observed it" and "it should be here" from blurring.
enum ConfidenceTier: String, Sendable, Codable {
    /// Tier 3 / Tier 2 — a live tracked lock on the actual object or label.
    case confirmed
    /// Tier 1 — manifest geometry relative to the tray anchor.
    case asPacked

    var calloutSuffix: String {
        switch self {
        case .confirmed: return ""
        case .asPacked:  return "as packed"
        }
    }
}

enum InstrumentState: String, Sendable, Codable {
    case available
    case markedInPlay
    /// Terminal: dropped, contaminated, off the field for good.
    case offField
}

enum SurfaceKind: String, Sendable, Codable, CaseIterable {
    case backTable, mayoStand, ringStand, prepTable, unknown

    var displayName: String {
        switch self {
        case .backTable: return "Back Table"
        case .mayoStand: return "Mayo Stand"
        case .ringStand: return "Ring Stand"
        case .prepTable: return "Prep Table"
        case .unknown:   return "Unassigned"
        }
    }
}

/// Coarse phase of the case. Feeds the resolver prior — retractors early,
/// needle drivers at closing. SPEC §13.
enum CasePhase: String, Sendable, Codable, CaseIterable {
    case setup, exposure, dissection, closing

    var displayName: String { rawValue.capitalized }
}

// MARK: - Perception payloads

struct TrayPose: Sendable {
    let trayID: String
    let originFromTray: simd_float4x4
    /// Nil until the image anchor has been promoted to a world anchor (§7.1).
    let worldAnchorID: UUID?
    let timestamp: TimeInterval
}

/// Tier 3 — ObjectTrackingProvider lock on a trained reference object.
struct ObjectLock: Sendable {
    /// Reference object name, which by convention equals the instrumentID.
    let instrumentID: String
    let originFromObject: simd_float4x4
    /// Half-extents of the tracked bounding box, in object space.
    let extents: SIMD3<Float>
    let isTracked: Bool
    let timestamp: TimeInterval
}

/// Tier 2 — ImageTrackingProvider lock on a printed consumable label.
struct LabelLock: Sendable {
    let consumableID: String
    let originFromLabel: simd_float4x4
    let isTracked: Bool
    let timestamp: TimeInterval
}

struct SurfaceAnchor: Sendable, Identifiable {
    let id: UUID
    var kind: SurfaceKind
    let originFromAnchor: simd_float4x4
    /// Full width and depth of the detected plane, in metres.
    let extent: SIMD2<Float>
}

// MARK: - Runtime tray

/// A manifest that has been bound to a physical position in the room.
struct Tray: Identifiable, Sendable {
    let manifest: TrayManifest
    var originFromTray: simd_float4x4?
    var worldAnchorID: UUID?
    var surface: SurfaceKind
    /// True when bound by the operator from the fallback list rather than by
    /// marker detection. Shown in the debug panel; never shown to the nurse.
    var boundManually: Bool

    var id: String { manifest.trayID }
    var isBound: Bool { originFromTray != nil }
    var displayName: String { manifest.displayName }

    init(manifest: TrayManifest) {
        self.manifest = manifest
        self.originFromTray = nil
        self.worldAnchorID = nil
        self.surface = .unknown
        self.boundManually = false
    }
}

// MARK: - Voice

/// What the voice layer hands the domain. Never raw text — the resolver runs
/// inside the voice engine so the domain only ever sees decisions. SPEC §6.
enum VoiceRequest: Sendable {
    /// Resolved to exactly one slot with enough margin to act.
    case resolved(SlotRef, heard: String)
    /// Two or three plausible candidates. Ask, never guess.
    case ambiguous([SlotRef], heard: String)
    /// Recognised against the full catalogue but that tray is not registered.
    case notOnField(displayName: String, heard: String)
    /// Mark the currently highlighted instrument as passed.
    case markPassed
    /// Return the most recently passed instrument to its slot.
    case markReturned
    /// Below threshold. Render nothing at all. SPEC §13.
    case silent(heard: String)
}

// MARK: - Guidance state

/// SPEC §16. What the render layer is being asked to draw, right now.
enum GuidanceState: Sendable, Equatable {
    case idle
    case listening
    /// Target tray is more than the far/near threshold away: show which tray.
    case guidingFar(SlotRef)
    /// Within reach: show which object.
    case guidingNear(SlotRef, tier: ConfidenceTier)
    case ambiguous([SlotRef])
    case notOnField(displayName: String)

    var activeSlot: SlotRef? {
        switch self {
        case .guidingFar(let s):       return s
        case .guidingNear(let s, _):   return s
        case .idle, .listening, .ambiguous, .notOnField: return nil
        }
    }

    var isGuiding: Bool { activeSlot != nil }
}

// MARK: - Tunables

/// Every magic number in the build, in one place, so they can be tuned on
/// device without hunting through files. SPEC §12, §13, §14.
enum Tunables {
    // Far / near crossfade, SPEC §14.
    static let nearThreshold: Float = 1.5          // metres
    static let nearHysteresis: Float = 0.2         // metres
    static let crossfadeDuration: TimeInterval = 0.25

    // Guidance lifetime.
    static let guidanceTimeout: TimeInterval = 6.0
    static let listenWindow: TimeInterval = 3.0

    // Voice, SPEC §12.4.
    static let commitLockout: TimeInterval = 0.8   // NOT 1.2 — see SPEC §12.4
    static let vocabularyCap = 80

    // Tier 3 fusion, SPEC §10.6.
    static let objectLockStaleAfter: TimeInterval = 0.5
    static let objectLockRequiredHits = 2

    // Anchor promotion, SPEC §7.1.
    static let stableDetectionCount = 5
    static let trayMovedPositionThreshold: Float = 0.03      // 3 cm
    static let trayMovedAngleThreshold: Float = 5 * .pi / 180 // 5 degrees

    // Render, SPEC §14.
    static let calloutHeightAboveTray: Float = 0.08
    static let highlightFadeIn: TimeInterval = 0.15
}
