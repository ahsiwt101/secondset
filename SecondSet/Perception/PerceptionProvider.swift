import Foundation
import simd

// SPEC §6. Define this in hour one and never change it. Three developers and
// one headset — this protocol is the only reason the work parallelises.

/// Main-actor isolated rather than `Sendable`. The expensive work here is
/// already asynchronous (ARKit hands us AsyncSequences), so there is nothing
/// to gain from a separate actor and a great deal of Swift 6 friction to
/// avoid: every payload would need to cross an isolation boundary twice on
/// its way to `CaseSession`, which lives on the main actor regardless.
@MainActor
protocol PerceptionProvider: AnyObject {

    /// Tray poses, already promoted from image anchor to world anchor (§7.1).
    var trayPoses: AsyncStream<TrayPose> { get }

    /// Tier 3 object locks. An empty stream is a valid, expected state —
    /// reference objects take hours to train and may not exist yet.
    var objectLocks: AsyncStream<ObjectLock> { get }

    /// Tier 2 consumable-label locks.
    var labelLocks: AsyncStream<LabelLock> { get }

    /// Detected horizontal surfaces. Display and filtering only — the render
    /// path never depends on these, so a bad guess degrades a label, not a
    /// highlight. SPEC §7.3.
    var surfaces: [SurfaceAnchor] { get }

    /// Head pose in world space. Drives the far/near crossfade, the peripheral
    /// chevron, and manual billboarding.
    func deviceTransform() -> simd_float4x4?

    func start() async throws
    func stop() async

    /// Fallback identity path. Ten seconds of work that turns a total demo
    /// failure into a minor one. SPEC §8.
    func bindManually(trayID: String)
}

enum PerceptionError: Error, LocalizedError {
    case authorizationDenied
    case providerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "World sensing permission was denied. Enable it in Settings."
        case .providerUnavailable(let name):
            return "\(name) is not available on this device."
        }
    }
}

/// Coarse health of the perception stack, surfaced in the debug panel and as
/// a single discreet chip in the immersive view. SPEC §17 — undefined
/// behaviour in front of judges looks like a crash even when it isn't.
struct PerceptionHealth: Sendable, Equatable {
    var worldTracking: Bool = false
    var imageTracking: Bool = false
    var objectTracking: Bool = false
    var planeDetection: Bool = false
    var relocalizing: Bool = false
    var boundTrayCount: Int = 0

    var summary: String {
        if relocalizing { return "Relocalising" }
        if !worldTracking { return "No world tracking" }
        return "\(boundTrayCount) tray\(boundTrayCount == 1 ? "" : "s") bound"
    }
}
