import Foundation
import RealityKit
import UIKit
import simd

// SPEC §14. Entity pooling: nothing is created or destroyed in response to a
// request. One gold beacon for the answer, three cyan ones for the case where
// there is no single answer, ghosts per slot, one callout. All allocated at
// register time; a request toggles visibility and sets transforms.

@MainActor
final class GuidanceRenderer {

    private let root: Entity

    /// The answer. There is only ever one — a second gold beacon would mean
    /// the system was claiming two things at once.
    private let primary = Beacon(tint: .gold, enablesAudio: true)

    /// Candidates when a phrase maps to several items. Multiplicity is what
    /// communicates "choose", which is why these are the same shape as the
    /// answer rather than a different colour. SPEC §14.
    private let candidates: [Beacon] = (0..<3).map { _ in Beacon(tint: .cyan) }

    private var ghosts: [SlotRef: ModelEntity] = [:]

    private let callout = Entity()
    private var calloutText = ModelEntity()
    private var lastCalloutString = ""

    /// One-shot confirmation when a tray first registers — deliberately not
    /// another beacon. Preallocated like everything else here (SPEC §14);
    /// only its transform and the fact that `playAudio` gets called move.
    private let registrationAnnounce = Entity()
    private var registrationChime: AudioResource?

    init(root: Entity) {
        self.root = root

        root.addChild(primary.root)
        candidates.forEach { root.addChild($0.root) }

        callout.isEnabled = false
        callout.addChild(calloutText)
        root.addChild(callout)

        registrationAnnounce.spatialAudio = SpatialAudioComponent(gain: -4, distanceAttenuation: .default)
        root.addChild(registrationAnnounce)
    }

    // MARK: - Preallocation

    func preallocate(for manifests: [TrayManifest]) {
        for m in manifests {
            for slot in m.slots {
                let fp = slot.footprintSize
                let ghost = ModelEntity(
                    mesh: .generatePlane(width: fp.x, depth: fp.y, cornerRadius: 0.006),
                    materials: [Palette.ghostSlot])
                ghost.isEnabled = false
                root.addChild(ghost)
                ghosts[.instrument(m.trayID, slot.index)] = ghost
            }
        }
        Log.render.info("Preallocated \(self.ghosts.count) ghosts, 4 beacons")
    }

    /// `AudioFileResource` loads async, unlike everything else built at
    /// launch — one extra step, called once from `CaseSession.prepare()`.
    /// The `Data`-based initializer is visionOS 27+ only; writing to a temp
    /// file and loading via `contentsOf:` works back to the deployment
    /// target instead. Failure here is silent-degrade only: the beam and
    /// halo work exactly as before, the wearer just loses the locator ping
    /// and has to visually scan for the beam once it's in view, same as
    /// before this existed.
    func prepareAudio() async {
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("locator-tone-\(UUID().uuidString).wav")
            try LocatorTone.wavData().write(to: url)
            let resource = try await AudioFileResource(
                contentsOf: url,
                configuration: .init(loadingStrategy: .preload, shouldLoop: true))
            primary.setLocatorAudio(resource)
        } catch {
            Log.render.error("Locator tone failed to load: \(error.localizedDescription)")
        }

        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("registration-chime-\(UUID().uuidString).wav")
            try RegistrationChime.wavData().write(to: url)
            registrationChime = try await AudioFileResource(
                contentsOf: url,
                configuration: .init(loadingStrategy: .preload, shouldLoop: false))
        } catch {
            Log.render.error("Registration chime failed to load: \(error.localizedDescription)")
        }
    }

    /// Called once, exactly when a tray moves from unbound to bound —
    /// `CaseSession.apply(_:TrayPose)` guards the transition so this never
    /// repeats on the pose corrections that follow.
    func announceRegistration(at transform: simd_float4x4) {
        guard let registrationChime else { return }
        registrationAnnounce.transform = Transform(matrix: transform)
        registrationAnnounce.playAudio(registrationChime)
    }

    // MARK: - Tray placement

    /// Ghost slots are world-locked to the tray, so they move when it re-anchors.
    func updateTray(_ tray: Tray, manifest: TrayManifest) {
        guard let originFromTray = tray.originFromTray else { return }
        let g = manifest.geometry
        for slot in manifest.slots {
            guard let ghost = ghosts[.instrument(tray.id, slot.index)] else { continue }
            ghost.transform = Transform(matrix: originFromTray * slot.trayFromSlot(g))
        }
    }

    // MARK: - The hot path

    func render(_ state: GuidanceState,
                session: CaseSession,
                deviceTransform: simd_float4x4) {

        switch state {
        case .idle, .listening:
            clear()

        case .guidingFar(let ref):
            hideCandidates()
            guard let pose = session.resolvedPose(for: ref) else { return }
            primary.place(at: pose.transform, footprint: session.footprint(for: ref))
            primary.set(.far)

            let distance = simd_distance(deviceTransform.translation, pose.transform.translation)
            showCallout(farText(for: ref, session: session, distance: distance),
                        at: pose.transform,
                        facing: deviceTransform.translation,
                        heightOffset: Tunables.beamHeight * 0.42)

        case .guidingNear(let ref, let tier):
            hideCandidates()
            guard let pose = session.resolvedPose(for: ref) else { return }
            primary.place(at: pose.transform, footprint: session.footprint(for: ref))
            primary.set(.near)
            showCallout(nearText(for: ref, session: session, tier: tier),
                        at: pose.transform,
                        facing: deviceTransform.translation,
                        heightOffset: Tunables.calloutHeightAboveTray)

        case .ambiguous(let refs):
            primary.set(.hidden)
            showAmbiguous(refs, session: session)
            if let first = refs.first, let pose = session.resolvedPose(for: first) {
                showCallout("WHICH ONE?",
                            at: pose.transform,
                            facing: deviceTransform.translation,
                            heightOffset: Tunables.beamHeight * 0.42)
            }

        case .notOnField(let name):
            primary.set(.hidden)
            hideCandidates()
            // Head-anchored, because by definition there is no tray to anchor to.
            let front = deviceTransform.translation
                      + (deviceTransform.columns.2.xyz * -0.9)
                      + SIMD3(0, -0.15, 0)
            showCallout("\(name.uppercased())\nNOT ON THE FIELD — ASK CIRCULATOR",
                        at: simd_float4x4(translation: front),
                        facing: deviceTransform.translation,
                        heightOffset: 0)
        }
    }

    func showAmbiguous(_ refs: [SlotRef], session: CaseSession) {
        for (i, beacon) in candidates.enumerated() {
            guard i < refs.count, let pose = session.resolvedPose(for: refs[i]) else {
                beacon.set(.hidden)
                continue
            }
            beacon.place(at: pose.transform, footprint: session.footprint(for: refs[i]))
            beacon.set(.far)
        }
    }

    func setGhost(_ ref: SlotRef, on: Bool, session: CaseSession) {
        ghosts[ref]?.isEnabled = on
    }

    func clear() {
        primary.set(.hidden)
        hideCandidates()
        callout.isEnabled = false
    }

    private func hideCandidates() {
        candidates.forEach { $0.set(.hidden) }
    }

    // MARK: - Callout

    private func showCallout(_ string: String,
                             at pose: simd_float4x4,
                             facing viewer: SIMD3<Float>,
                             heightOffset: Float) {
        // Regenerating text allocates, so only when the string actually
        // changes — once per request, never per frame.
        if string != lastCalloutString {
            lastCalloutString = string
            calloutText.model = ModelComponent(
                mesh: .generateText(string,
                                    extrusionDepth: 0.0004,
                                    font: .systemFont(ofSize: CGFloat(Tunables.calloutFontSize), weight: .medium),
                                    containerFrame: .zero,
                                    alignment: .center,
                                    lineBreakMode: .byWordWrapping),
                materials: [Palette.text])
            if let bounds = calloutText.model?.mesh.bounds {
                calloutText.position = [-bounds.extents.x / 2, 0, 0]
            }
        }

        var position = pose.translation
        position.y += heightOffset
        callout.transform = Transform(matrix: billboardTransform(at: position, facing: viewer))
        callout.isEnabled = true
    }

    private func farText(for ref: SlotRef, session: CaseSession, distance: Float) -> String {
        guard let d = session.describe(ref) else { return "" }
        return "\(d.displayName.uppercased())\n\(d.trayName)  ·  \(String(format: "%.1f m", distance))"
    }

    private func nearText(for ref: SlotRef, session: CaseSession, tier: ConfidenceTier) -> String {
        guard let d = session.describe(ref) else { return "" }
        // SPEC §1.1 — the hedge lives inside the string. Slot position is true
        // at open and degrades from there, and the wording says so without
        // anyone having to explain it.
        let position = tier == .confirmed
            ? d.positionLabel
            : (d.positionLabel.isEmpty ? "as packed" : "as packed · \(d.positionLabel)")
        return "\(d.displayName.uppercased())\n\(position)"
    }
}
