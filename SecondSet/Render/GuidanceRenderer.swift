import Foundation
import RealityKit
import UIKit
import simd

// SPEC §14. Entity pooling: nothing is created or destroyed in response to a
// request. Everything is allocated at register time with `isEnabled = false`,
// and a request toggles visibility and sets a transform.

@MainActor
final class GuidanceRenderer {

    private let root: Entity

    // Pools, keyed so a lookup is O(1) on the hot path.
    private var trayRims: [String: ModelEntity] = [:]
    private var slotQuads: [String: ModelEntity] = [:]
    private var objectShells: [String: ModelEntity] = [:]
    private var ghosts: [SlotRef: ModelEntity] = [:]
    private var ambiguousQuads: [ModelEntity] = []

    private let callout = Entity()
    private var calloutText = ModelEntity()
    private var lastCalloutString = ""

    init(root: Entity) {
        self.root = root
        callout.isEnabled = false
        callout.addChild(calloutText)
        root.addChild(callout)
    }

    // MARK: - Preallocation

    func preallocate(for manifests: [TrayManifest]) {
        for m in manifests {
            let g = m.geometry

            let rim = ModelEntity(
                mesh: .generatePlane(width: g.interior.x, depth: g.interior.z, cornerRadius: 0.012),
                materials: [Palette.trayRim])
            rim.isEnabled = false
            root.addChild(rim)
            trayRims[m.trayID] = rim

            let quad = ModelEntity(
                mesh: .generatePlane(width: 0.06, depth: 0.12, cornerRadius: 0.008),
                materials: [Palette.asPacked])
            quad.isEnabled = false
            root.addChild(quad)
            slotQuads[m.trayID] = quad

            // A thin transparent shell rather than a flat quad: a confirmed
            // lock is volumetric, and the difference from the flat as-packed
            // quad is what makes the two tiers legible at a glance.
            let shell = ModelEntity(
                mesh: .generateBox(size: [0.06, 0.04, 0.12], cornerRadius: 0.006),
                materials: [Palette.confirmed])
            shell.isEnabled = false
            root.addChild(shell)
            objectShells[m.trayID] = shell

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

        // Three is the cap on the disambiguation card, so three is the pool.
        for _ in 0..<3 {
            let q = ModelEntity(
                mesh: .generatePlane(width: 0.07, depth: 0.13, cornerRadius: 0.008),
                materials: [Palette.ambiguous])
            q.isEnabled = false
            root.addChild(q)
            ambiguousQuads.append(q)
        }

        Log.render.info("Preallocated \(self.totalEntityCount) entities across \(manifests.count) trays")
    }

    private var totalEntityCount: Int {
        trayRims.count + slotQuads.count + objectShells.count + ghosts.count + ambiguousQuads.count + 1
    }

    // MARK: - Tray placement

    func updateTray(_ tray: Tray, manifest: TrayManifest) {
        guard let originFromTray = tray.originFromTray else { return }
        let g = manifest.geometry

        // Rim sits at the centre of the tray interior, just above the floor.
        if let rim = trayRims[tray.id] {
            let centre = SIMD3<Float>(g.interior.x * 0.5, g.slotHeight * 0.5, g.interior.z * 0.5)
            rim.transform = Transform(matrix: originFromTray * simd_float4x4(translation: centre))
        }

        for slot in manifest.slots {
            let ref = SlotRef.instrument(tray.id, slot.index)
            guard let ghost = ghosts[ref] else { continue }
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
            hideNear()
            showTrayRim(ref.trayID, on: true)
            if let pose = session.resolvedPose(for: ref) {
                let distance = simd_distance(deviceTransform.translation, pose.transform.translation)
                showCallout(farText(for: ref, session: session, distance: distance),
                            at: pose.transform,
                            facing: deviceTransform.translation)
            }

        case .guidingNear(let ref, let tier):
            showTrayRim(ref.trayID, on: false)
            guard let pose = session.resolvedPose(for: ref) else { return }
            showNear(ref, pose: pose.transform, tier: tier, session: session)
            showCallout(nearText(for: ref, session: session, tier: tier),
                        at: pose.transform,
                        facing: deviceTransform.translation)

        case .ambiguous(let refs):
            hideNear()
            showAmbiguous(refs, session: session)
            if let first = refs.first, let pose = session.resolvedPose(for: first) {
                showCallout("WHICH ONE?", at: pose.transform, facing: deviceTransform.translation)
            }

        case .notOnField(let name):
            hideNear()
            hideAllRims()
            // Anchored to the head rather than a tray, because by definition
            // there is no tray to anchor it to.
            let front = deviceTransform.translation
                      + (deviceTransform.columns.2.xyz * -0.9)
                      + SIMD3(0, -0.15, 0)
            showCallout("\(name.uppercased())\nNOT ON THE FIELD — ASK CIRCULATOR",
                        at: simd_float4x4(translation: front),
                        facing: deviceTransform.translation)
        }
    }

    private func showNear(_ ref: SlotRef,
                          pose: simd_float4x4,
                          tier: ConfidenceTier,
                          session: CaseSession) {
        let quad = slotQuads[ref.trayID]
        let shell = objectShells[ref.trayID]

        switch tier {
        case .asPacked:
            shell?.isEnabled = false
            guard let quad else { return }
            let fp = session.footprint(for: ref)
            quad.model?.mesh = .generatePlane(width: fp.x, depth: fp.y, cornerRadius: 0.008)
            quad.transform = Transform(matrix: pose)
            reveal(quad)

        case .confirmed:
            quad?.isEnabled = false
            guard let shell else { return }
            shell.transform = Transform(matrix: pose)
            reveal(shell)
        }
    }

    private func hideNear() {
        slotQuads.values.forEach { $0.isEnabled = false }
        objectShells.values.forEach { $0.isEnabled = false }
        ambiguousQuads.forEach { $0.isEnabled = false }
    }

    private func showTrayRim(_ trayID: String, on: Bool) {
        for (id, rim) in trayRims {
            let shouldShow = on && id == trayID
            if shouldShow && !rim.isEnabled { reveal(rim) } else if !shouldShow { rim.isEnabled = false }
        }
    }

    private func hideAllRims() {
        trayRims.values.forEach { $0.isEnabled = false }
    }

    func showAmbiguous(_ refs: [SlotRef], session: CaseSession) {
        hideNear()
        for (i, ref) in refs.prefix(3).enumerated() {
            guard let pose = session.resolvedPose(for: ref) else { continue }
            let quad = ambiguousQuads[i]
            quad.transform = Transform(matrix: pose.transform)
            reveal(quad)
            showTrayRim(ref.trayID, on: true)
        }
    }

    func setGhost(_ ref: SlotRef, on: Bool, session: CaseSession) {
        guard let ghost = ghosts[ref] else { return }
        ghost.isEnabled = on
    }

    func clear() {
        hideNear()
        hideAllRims()
        callout.isEnabled = false
    }

    // MARK: - Callout

    private func showCallout(_ string: String, at pose: simd_float4x4, facing viewer: SIMD3<Float>) {
        // Regenerating text allocates, so only do it when the string actually
        // changes — that is once per request, never per frame.
        if string != lastCalloutString {
            lastCalloutString = string
            calloutText.model = ModelComponent(
                mesh: .generateText(string,
                                    extrusionDepth: 0.0004,
                                    font: .systemFont(ofSize: 0.022, weight: .medium),
                                    containerFrame: .zero,
                                    alignment: .center,
                                    lineBreakMode: .byWordWrapping),
                materials: [Palette.text])
            // generateText lays out from the origin rightward; centre it.
            if let bounds = calloutText.model?.mesh.bounds {
                calloutText.position = [-bounds.extents.x / 2, 0, 0]
            }
        }

        var position = pose.translation
        position.y += Tunables.calloutHeightAboveTray
        callout.transform = Transform(matrix: billboardTransform(at: position, facing: viewer))
        callout.isEnabled = true
    }

    private func farText(for ref: SlotRef, session: CaseSession, distance: Float) -> String {
        guard let d = session.describe(ref) else { return "" }
        return "\(d.displayName.uppercased())\n\(d.trayName)  ·  \(String(format: "%.1f m", distance))"
    }

    private func nearText(for ref: SlotRef, session: CaseSession, tier: ConfidenceTier) -> String {
        guard let d = session.describe(ref) else { return "" }
        // SPEC §1.1 — the hedge lives inside the string itself. Slot position
        // is true at open and degrades from there, and the wording says so
        // without anyone having to explain it.
        let position = tier == .confirmed
            ? d.positionLabel
            : (d.positionLabel.isEmpty ? "as packed" : "as packed · \(d.positionLabel)")
        return "\(d.displayName.uppercased())\n\(position)"
    }

    // MARK: - Appearance

    /// A quad that pops in reads as a bug; a 150 ms ease-in with a slight
    /// overshoot reads as intentional. Twenty minutes of work for a
    /// disproportionate share of perceived quality. SPEC §14.
    private func reveal(_ entity: ModelEntity) {
        guard !entity.isEnabled else { return }
        let target = entity.transform
        var start = target
        start.scale = target.scale * 0.86
        entity.transform = start
        entity.isEnabled = true
        entity.move(to: target,
                    relativeTo: entity.parent,
                    duration: Tunables.highlightFadeIn,
                    timingFunction: .easeOut)
    }
}
