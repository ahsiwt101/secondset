import Foundation
import simd

// SPEC §7. `simd_float4x4(translation:)` and `.xyz` are not standard library
// and are used throughout the perception and render layers. Write them once.

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

extension simd_float4x4 {

    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t, 1)
    }

    init(yaw radians: Float) {
        self = simd_float4x4(simd_quatf(angle: radians, axis: [0, 1, 0]))
    }

    /// Translation component in the parent space.
    var translation: SIMD3<Float> {
        columns.3.xyz
    }

    /// Rotation component with any scale divided out.
    var rotation: simd_quatf {
        let c0 = simd_normalize(columns.0.xyz)
        let c1 = simd_normalize(columns.1.xyz)
        let c2 = simd_normalize(columns.2.xyz)
        return simd_quatf(simd_float3x3(c0, c1, c2))
    }

    /// Rotation about +Y only. Markers mount flat, so for tray poses this is
    /// the only rotation that carries information.
    var yaw: Float {
        atan2(columns.0.z, columns.0.x)
    }
}

/// Straight-line distance between the origins of two transforms, in metres.
func positionalDelta(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
    simd_distance(a.translation, b.translation)
}

/// Smallest angle between the orientations of two transforms, in radians.
func angularDelta(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
    let q = simd_normalize(a.rotation) * simd_normalize(b.rotation).inverse
    // simd_quatf.angle is unsigned but can exceed pi for non-normalised input.
    let angle = q.angle
    return angle > .pi ? (2 * .pi - angle) : angle
}

/// A transform that places `subject` at `position` facing `viewer`, keeping
/// +Y world-up. SPEC §14 — un-billboarded text viewed obliquely is illegible,
/// and we bill this ourselves rather than depending on BillboardComponent.
func billboardTransform(at position: SIMD3<Float>,
                        facing viewer: SIMD3<Float>) -> simd_float4x4 {
    var forward = viewer - position
    forward.y = 0                                  // keep the panel upright
    let lengthSquared = simd_length_squared(forward)
    guard lengthSquared > 1e-8 else {
        return simd_float4x4(translation: position)
    }
    forward = forward / sqrt(lengthSquared)

    let up = SIMD3<Float>(0, 1, 0)
    let right = simd_normalize(simd_cross(up, forward))
    let trueUp = simd_cross(forward, right)

    var m = matrix_identity_float4x4
    m.columns.0 = SIMD4(right, 0)
    m.columns.1 = SIMD4(trueUp, 0)
    m.columns.2 = SIMD4(forward, 0)
    m.columns.3 = SIMD4(position, 1)
    return m
}

extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
