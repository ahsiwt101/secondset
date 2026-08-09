import Foundation
import RealityKit
import UIKit
import simd

/// One target marker, in two forms that are really one continuous object:
/// a light column visible across the room, which **retracts down into** a halo
/// circling the item as the wearer arrives.
///
/// Built as a single assembly rather than two separate effects so the
/// transition can be choreographed rather than cut. The cut is what would make
/// it look assembled instead of designed.
///
/// Everything is allocated once. Changing mode only toggles `isEnabled` and
/// animates transforms — SPEC §14, nothing is created in response to a request.
@MainActor
final class Beacon {

    enum Mode: Equatable {
        case hidden
        /// Across the room: full column, pool at its base.
        case far
        /// At the tray: column collapsed, halo orbiting the item.
        case near
    }

    /// Nested types do not inherit the enclosing type's actor isolation, and
    /// every one of these reaches into `Palette`, which is main-actor bound
    /// because it holds RealityKit materials.
    @MainActor
    enum Tint {
        case gold      // this is the one you asked for
        case cyan      // one of several candidates — choose

        var color: UIColor { self == .gold ? Palette.gold : Palette.cyan }
        var beam: UnlitMaterial { self == .gold ? Palette.goldBeam : Palette.cyanBeam }
        var sheath: UnlitMaterial { self == .gold ? Palette.goldSheath : Palette.cyanSheath }
        var pool: UnlitMaterial { self == .gold ? Palette.goldPool : Palette.cyanPool }
    }

    let root = Entity()

    /// Parent of the column. Scaling this in Y collapses the beam *downward*
    /// into its base, which is why the cylinder is offset inside it rather
    /// than centred on the origin — scaling a centred cylinder would shrink it
    /// toward its middle and read as a glitch.
    private let column = Entity()
    private let core: ModelEntity
    private let sheath: ModelEntity
    private let motes = Entity()

    private let pool: ModelEntity
    private let haloRing: ModelEntity
    private let haloParticles = Entity()

    private let tint: Tint
    private var mode: Mode = .hidden

    /// Only the primary (gold) beacon gets a locator ping — three candidate
    /// beacons all pinging at once in the ambiguous case would be noise, not
    /// guidance, and that's not the problem being solved here anyway.
    private let enablesAudio: Bool
    private var locatorAudio: AudioResource?

    // MARK: - Build

    init(tint: Tint, enablesAudio: Bool = false) {
        self.tint = tint
        self.enablesAudio = enablesAudio

        let h = Tunables.beamHeight
        core = ModelEntity(mesh: .generateCylinder(height: h, radius: Tunables.beamCoreRadius),
                           materials: [tint.beam])
        sheath = ModelEntity(mesh: .generateCylinder(height: h, radius: Tunables.beamSheathRadius),
                             materials: [tint.sheath])
        // Sit the cylinders on the origin so the column grows upward from the
        // item rather than being bisected by it.
        core.position.y = h / 2
        sheath.position.y = h / 2

        pool = ModelEntity(
            mesh: .generatePlane(width: Tunables.poolDiameter, depth: Tunables.poolDiameter),
            materials: [tint.pool])
        pool.position.y = 0.002

        haloRing = ModelEntity(mesh: .generatePlane(width: 0.2, depth: 0.2),
                               materials: [Palette.goldRing])
        haloRing.position.y = 0.004

        column.addChild(core)
        column.addChild(sheath)
        column.addChild(motes)

        root.addChild(column)
        root.addChild(pool)
        root.addChild(haloRing)
        root.addChild(haloParticles)

        motes.components.set(Self.risingMotes(tint: tint))
        haloParticles.components.set(Self.orbitingHalo(radius: 0.06, tint: tint))

        if enablesAudio {
            root.spatialAudio = SpatialAudioComponent(gain: -6, distanceAttenuation: .default)
        }

        setEnabled(column: false, pool: false, halo: false)
        startPulse()
    }

    /// Loaded asynchronously (`AudioFileResource(from:)` is async) once at
    /// launch by `GuidanceRenderer.prepareAudio()`, then handed in here. Far
    /// mode may already be active by the time this arrives — in that case
    /// start it immediately rather than waiting for the next transition.
    func setLocatorAudio(_ resource: AudioResource) {
        locatorAudio = resource
        if mode == .far { startLocatorAudio() }
    }

    private func startLocatorAudio() {
        guard enablesAudio, let locatorAudio else { return }
        root.playAudio(locatorAudio)
    }

    private func stopLocatorAudio() {
        guard enablesAudio else { return }
        root.stopAllAudio()
    }

    /// A slow, shallow breathing scale on the sheath — the layer with the
    /// widest silhouette, so the pulse actually changes the shape a passerby
    /// sees rather than just its brightness. Started once at build time and
    /// left running continuously; toggling `isEnabled` on the parent pauses
    /// the visible effect for free without touching the animation itself.
    ///
    /// Driven by RealityKit's own animation system, not the SwiftUI update
    /// loop — TheatreView's `update:` closure stays empty by design (SPEC
    /// §17), and this respects that rather than working around it.
    private func startPulse() {
        // Base the animation on the sheath's ACTUAL transform, not .identity —
        // it already carries `position.y = h/2`. A from/to pair built on
        // .identity would snap that offset to zero at the start of every
        // cycle, teleporting the sheath down to the tray floor and back.
        // Only the scale component differs between from and to.
        let base = sheath.transform
        var grown = base
        grown.scale = base.scale * Tunables.pulseScale

        let animation = FromToByAnimation<Transform>(
            from: base,
            to: grown,
            duration: Tunables.pulseDuration,
            timing: .easeInOut,
            repeatMode: .autoReverse)
        do {
            let resource = try AnimationResource.generate(with: animation)
            sheath.playAnimation(resource)
        } catch {
            Log.render.error("Beacon pulse animation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Particles

    /// Slow motes drifting up the column. Low birth rate on purpose: this
    /// should read as dust caught in a light shaft, not a firework.
    private static func risingMotes(tint: Tint) -> ParticleEmitterComponent {
        var e = ParticleEmitterComponent()
        e.emitterShape = .cylinder
        e.emitterShapeSize = [Tunables.beamSheathRadius * 2,
                              Tunables.beamHeight,
                              Tunables.beamSheathRadius * 2]
        e.birthLocation = .volume
        e.mainEmitter.birthRate = Tunables.moteBirthRate
        e.mainEmitter.size = 0.0045
        e.mainEmitter.sizeVariation = 0.003
        e.mainEmitter.lifeSpan = 2.6
        e.mainEmitter.lifeSpanVariation = 0.8
        e.mainEmitter.acceleration = [0, 0.10, 0]
        e.mainEmitter.noiseStrength = 0.18
        e.mainEmitter.noiseScale = 1.4
        e.mainEmitter.opacityCurve = .gradualFadeInOut
        e.mainEmitter.blendMode = .additive
        e.mainEmitter.sortOrder = .unsorted
        e.mainEmitter.color = .constant(.single(tint.color))
        if let sprite = GradientTextures.mote { e.mainEmitter.image = sprite }
        return e
    }

    /// The halo: a torus of particles orbiting the item. `vortexStrength` does
    /// the circling, so no per-frame work is needed on our side.
    private static func orbitingHalo(radius: Float, tint: Tint) -> ParticleEmitterComponent {
        var e = ParticleEmitterComponent()
        e.emitterShape = .torus
        e.emitterShapeSize = [radius, radius, radius]
        e.torusInnerRadius = radius * 0.18
        e.birthLocation = .surface
        e.mainEmitter.birthRate = Tunables.haloBirthRate
        e.mainEmitter.size = 0.0035
        e.mainEmitter.sizeVariation = 0.0018
        e.mainEmitter.lifeSpan = 1.1
        e.mainEmitter.lifeSpanVariation = 0.35
        e.mainEmitter.vortexStrength = 2.4
        e.mainEmitter.vortexDirection = [0, 1, 0]
        e.mainEmitter.acceleration = [0, 0.012, 0]
        e.mainEmitter.noiseStrength = 0.06
        e.mainEmitter.opacityCurve = .gradualFadeInOut
        e.mainEmitter.blendMode = .additive
        e.mainEmitter.sortOrder = .unsorted
        e.mainEmitter.color = .evolving(start: .single(tint.color),
                                        end: .single(tint.color.withAlphaComponent(0.35)))
        if let sprite = GradientTextures.mote { e.mainEmitter.image = sprite }
        return e
    }

    // MARK: - Placement

    /// Park the beacon on a target. `footprint` sizes the halo so it hugs the
    /// item instead of being a fixed circle.
    func place(at transform: simd_float4x4, footprint: SIMD2<Float>) {
        root.transform = Transform(matrix: transform)

        let radius = max(footprint.x, footprint.y) * Tunables.haloFootprintScale
        haloRing.model?.mesh = .generatePlane(width: radius * 2, depth: radius * 2)
        haloParticles.components.set(Self.orbitingHalo(radius: radius, tint: tint))
    }

    // MARK: - Mode

    func set(_ newMode: Mode, animated: Bool = true) {
        guard newMode != mode else { return }
        let previous = mode
        mode = newMode

        if newMode == .far && previous != .far {
            startLocatorAudio()
        } else if previous == .far && newMode != .far {
            stopLocatorAudio()
        }

        switch newMode {
        case .hidden:
            setEnabled(column: false, pool: false, halo: false)

        case .far:
            setEnabled(column: true, pool: true, halo: false)
            // Grow up out of the tray rather than appearing at full height.
            let target = Transform(scale: .one)
            if animated && previous == .hidden {
                column.transform = Transform(scale: [1, 0.04, 1])
                column.move(to: target, relativeTo: root,
                            duration: Tunables.beamRiseDuration,
                            timingFunction: .easeOut)
            } else {
                column.transform = target
            }
            pool.scale = .one

        case .near:
            setEnabled(column: true, pool: true, halo: true)
            // The column does not cut out — it retracts into the halo while
            // the pool expands to meet it. One continuous movement.
            let collapsed = Transform(scale: [1, 0.001, 1])
            if animated {
                column.move(to: collapsed, relativeTo: root,
                            duration: Tunables.retractDuration,
                            timingFunction: .easeInOut)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Tunables.retractDuration))
                    guard let self, self.mode == .near else { return }
                    self.column.isEnabled = false
                }
            } else {
                column.transform = collapsed
                column.isEnabled = false
            }
        }
    }

    private func setEnabled(column columnOn: Bool, pool poolOn: Bool, halo haloOn: Bool) {
        column.isEnabled = columnOn
        pool.isEnabled = poolOn
        haloRing.isEnabled = haloOn
        haloParticles.isEnabled = haloOn
    }
}
