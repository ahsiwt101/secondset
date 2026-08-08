import Foundation
import QuartzCore
import simd

// SPEC §18. The visionOS Simulator supports none of the perception stack — no
// world tracking, no image tracking, no object tracking, no planes. With one
// headset and three developers this class is what makes the build parallel,
// which is why it exists before any of the real engines do.

@MainActor
final class MockPerceptionProvider: PerceptionProvider {

    let trayPoses: AsyncStream<TrayPose>
    let objectLocks: AsyncStream<ObjectLock>
    let labelLocks: AsyncStream<LabelLock>
    private(set) var surfaces: [SurfaceAnchor] = []

    private let poseC: AsyncStream<TrayPose>.Continuation
    private let objectC: AsyncStream<ObjectLock>.Continuation
    private let labelC: AsyncStream<LabelLock>.Continuation

    /// Simulated head pose. The debug panel can walk this forward and back to
    /// exercise the far/near crossfade without standing up.
    var simulatedDevicePosition = SIMD3<Float>(0, 1.4, 0)

    private var manifests: [TrayManifest] = []
    private var driftTask: Task<Void, Never>?

    init() {
        (trayPoses, poseC)   = AsyncStream.makeStream()
        (objectLocks, objectC) = AsyncStream.makeStream()
        (labelLocks, labelC) = AsyncStream.makeStream()
    }

    func start() async throws {
        manifests = ManifestStore.loadBundled()

        // Three trays in a shallow arc 1.2 m in front of the origin, at back
        // table height, which is roughly the real geometry.
        surfaces = [
            SurfaceAnchor(id: UUID(), kind: .backTable,
                          originFromAnchor: simd_float4x4(translation: [0, 0.9, -1.2]),
                          extent: SIMD2(1.8, 0.7)),
            SurfaceAnchor(id: UUID(), kind: .mayoStand,
                          originFromAnchor: simd_float4x4(translation: [0.6, 1.1, -0.7]),
                          extent: SIMD2(0.6, 0.4))
        ]
    }

    func stop() async {
        driftTask?.cancel()
        poseC.finish(); objectC.finish(); labelC.finish()
    }

    func deviceTransform() -> simd_float4x4? {
        simd_float4x4(translation: simulatedDevicePosition)
    }

    func bindManually(trayID: String) {
        emitPose(trayID: trayID)
    }

    // MARK: - Injection (wired to the debug panel)

    /// Register every bundled tray at once — the fast path for iterating on
    /// the guidance UI without re-scanning anything.
    func registerAll() {
        for (i, m) in manifests.enumerated() {
            emitPose(trayID: m.trayID, index: i)
        }
    }

    func emitPose(trayID: String, index: Int? = nil) {
        let i = index ?? (manifests.firstIndex { $0.trayID == trayID } ?? 0)
        let x = Float(i - 1) * 0.62                    // -0.62, 0, 0.62
        let transform = simd_float4x4(translation: [x, 0.92, -1.2])
                      * simd_float4x4(yaw: Float(i) * 0.12)

        poseC.yield(TrayPose(trayID: trayID,
                             originFromTray: transform,
                             worldAnchorID: UUID(),
                             timestamp: CACurrentMediaTime()))
    }

    /// Tier 3. Fires a lock slightly offset from the as-packed slot so the
    /// crossfade between "as packed" and "confirmed" is visibly different —
    /// if they render identically you cannot tell the tiers apart on stage.
    func emitObjectLock(instrumentID: String, at position: SIMD3<Float>, tracked: Bool = true) {
        objectC.yield(ObjectLock(instrumentID: instrumentID,
                                 originFromObject: simd_float4x4(translation: position),
                                 extents: SIMD3(0.05, 0.03, 0.12),
                                 isTracked: tracked,
                                 timestamp: CACurrentMediaTime()))
    }

    func emitLabelLock(consumableID: String, at position: SIMD3<Float>, tracked: Bool = true) {
        labelC.yield(LabelLock(consumableID: consumableID,
                               originFromLabel: simd_float4x4(translation: position),
                               isTracked: tracked,
                               timestamp: CACurrentMediaTime()))
    }

    /// Exercise the degraded paths (SPEC §17) that are otherwise impossible to
    /// reproduce on demand: a tray that gets nudged mid-case, and an object
    /// lock that drops out while the highlight is up.
    func injectTrayMoved(trayID: String, by offset: SIMD3<Float> = [0.25, 0, 0.1]) {
        guard let i = manifests.firstIndex(where: { $0.trayID == trayID }) else { return }
        let x = Float(i - 1) * 0.62
        let moved = simd_float4x4(translation: SIMD3(x, 0.92, -1.2) + offset)
        poseC.yield(TrayPose(trayID: trayID,
                             originFromTray: moved,
                             worldAnchorID: UUID(),
                             timestamp: CACurrentMediaTime()))
    }

    func injectLockLoss(instrumentID: String) {
        objectC.yield(ObjectLock(instrumentID: instrumentID,
                                 originFromObject: matrix_identity_float4x4,
                                 extents: .zero,
                                 isTracked: false,
                                 timestamp: CACurrentMediaTime()))
    }

    /// Walk the simulated head toward or away from the trays so the far/near
    /// threshold can be crossed from a desk.
    func walk(to distance: Float) {
        simulatedDevicePosition = SIMD3(0, 1.4, -1.2 + distance)
    }
}
