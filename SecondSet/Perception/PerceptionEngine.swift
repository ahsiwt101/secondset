import Foundation
import ARKit
import QuartzCore
import simd

// SPEC §7. The only file in the app that touches ARKit. If an API name here is
// wrong for the target visionOS release, this is the single file to fix —
// everything downstream talks to `PerceptionProvider`, not to ARKit.

@MainActor
final class PerceptionEngine: PerceptionProvider {

    let trayPoses: AsyncStream<TrayPose>
    let objectLocks: AsyncStream<ObjectLock>
    let labelLocks: AsyncStream<LabelLock>
    private(set) var surfaces: [SurfaceAnchor] = []

    private let poseC: AsyncStream<TrayPose>.Continuation
    private let objectC: AsyncStream<ObjectLock>.Continuation
    private let labelC: AsyncStream<LabelLock>.Continuation

    private let session = ARKitSession()
    private let world = WorldTrackingProvider()
    private let planes = PlaneDetectionProvider(alignments: [.horizontal])
    private var images: ImageTrackingProvider?
    private var objects: ObjectTrackingProvider?

    private var manifests: [TrayManifest] = []
    /// referenceImageName → trayID, and → consumableID for Tier 2 labels.
    private var markerToTray: [String: String] = [:]
    private var labelToConsumable: [String: String] = [:]

    /// Anchor persistence is split-brain by design: ARKit persists the anchor,
    /// we persist the semantics. On relaunch world anchors arrive carrying only
    /// UUIDs, and without this table the room is a set of anonymous points.
    /// SPEC §7.2.
    private let anchorStore = AnchorStore()
    private var worldAnchorToTray: [UUID: String] = [:]

    /// Detections are only promoted after N consecutive stable observations.
    private var pendingDetections: [String: (count: Int, transform: simd_float4x4)] = [:]
    private var promoted: [String: simd_float4x4] = [:]

    var onHealthChange: ((PerceptionHealth) -> Void)?
    private var health = PerceptionHealth() {
        didSet { if health != oldValue { onHealthChange?(health) } }
    }

    init() {
        (trayPoses, poseC)     = AsyncStream.makeStream()
        (objectLocks, objectC) = AsyncStream.makeStream()
        (labelLocks, labelC)   = AsyncStream.makeStream()
    }

    // MARK: - Lifecycle

    func start() async throws {
        manifests = ManifestStore.loadBundled()
        for m in manifests {
            markerToTray[m.markerImageName] = m.trayID
            for c in m.consumables { labelToConsumable[c.referenceImageName] = c.consumableID }
        }
        // Persistence deliberately off for now: registering the tray is part
        // of the demo, not overhead to skip. Loading past bindings here would
        // make a previously-seen tray promote itself the instant ARKit
        // resurfaces its WorldAnchor, before the marker is ever back in view.
        // `anchorStore.save` below is left in place — flip this back to
        // `anchorStore.load()` to restore cross-launch memory later.
        worldAnchorToTray = [:]

        // Tier 1 + Tier 2 both ride ImageTrackingProvider: tray markers and
        // printed packet labels are the same mechanism. SPEC §9.
        let referenceImages = ReferenceImage.loadReferenceImages(inGroupNamed: "Markers")
        if referenceImages.isEmpty {
            Log.perception.warning("No reference images in asset group \"Markers\" — marker binding disabled, manual bind only")
        } else {
            images = ImageTrackingProvider(referenceImages: referenceImages)
        }

        // Tier 3 is optional by design. Reference objects take hours to train
        // and may legitimately not exist yet; absence must never break startup.
        if ObjectTrackingProvider.isSupported {
            let refs = await loadReferenceObjects()
            if refs.isEmpty {
                Log.perception.info("No .referenceobject files bundled — running Tier 1/2 only")
            } else {
                var tracking = ObjectTrackingProvider.TrackingConfiguration()
                // The demo beat is picking an instrument up and watching the
                // highlight follow it, so favour tracking rate over breadth.
                tracking.maximumTrackableInstances = max(refs.count, 1)
                tracking.maximumInstancesPerReferenceObject = 1
                objects = ObjectTrackingProvider(referenceObjects: refs,
                                                 trackingConfiguration: tracking)
                Log.perception.info("Loaded \(refs.count) reference objects: \(refs.map(\.name).joined(separator: ", "))")
            }
        } else {
            Log.perception.info("Object tracking unsupported on this device")
        }

        let auth = await session.requestAuthorization(for: [.worldSensing])
        guard auth[.worldSensing] == .allowed else { throw PerceptionError.authorizationDenied }

        var providers: [any DataProvider] = [world, planes]
        if let images { providers.append(images) }
        if let objects { providers.append(objects) }
        try await session.run(providers)

        health.worldTracking = true
        health.planeDetection = true
        health.imageTracking = images != nil
        health.objectTracking = objects != nil

        // One Task per provider. Never serialise them behind a single loop, or
        // a slow handler on one stalls all the others. SPEC §7.2.
        Task { [weak self] in
            guard let s = self, let images = s.images else { return }
            for await update in images.anchorUpdates { s.handle(image: update) }
        }
        Task { [weak self] in
            guard let s = self, let objects = s.objects else { return }
            for await update in objects.anchorUpdates { s.handle(object: update) }
        }
        Task { [weak self] in
            guard let s = self else { return }
            for await update in s.world.anchorUpdates { s.handle(world: update) }
        }
        Task { [weak self] in
            guard let s = self else { return }
            for await update in s.planes.anchorUpdates { s.handle(plane: update) }
        }
        Task { [weak self] in
            guard let s = self else { return }
            for await event in s.session.events { s.handle(event: event) }
        }
    }

    func stop() async {
        session.stop()
        poseC.finish(); objectC.finish(); labelC.finish()
    }

    /// There is no asset-group loader for reference objects — unlike reference
    /// images, they load one at a time from a URL. Scanning the bundle rather
    /// than hard-coding names means a freshly trained object is picked up by
    /// dropping the file in, with no code change. Given training runs for hours
    /// and lands at unpredictable times, that matters.
    ///
    /// ⚠️ The `do/catch` below is real protection against a THROWN error, but
    /// it cannot protect against everything. Confirmed empirically: a
    /// malformed or version-incompatible `.referenceobject` makes
    /// `ReferenceObject(from:)` hit a native fatalError
    /// ("ar_reference_object_load_from_url failed") that takes the whole
    /// process down, not a Swift error this catches. Every other perception
    /// input in this file degrades gracefully by design (SPEC §17) — this is
    /// the one exception, and no amount of wrapping fixes it, because Swift
    /// cannot catch a fatalError. The only real mitigation is discipline: test
    /// a freshly exported reference object on device immediately, before it
    /// ships in a build anyone else runs.
    private func loadReferenceObjects() async -> [ReferenceObject] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "referenceobject",
                                    subdirectory: nil) ?? []
        var loaded: [ReferenceObject] = []
        for url in urls {
            do {
                if #available(visionOS 27.0, *) {
                    var config = ReferenceObject.Configuration()
                    // The instrument gets picked up and moved; that is the
                    // whole point of Tier 3.
                    config.highFrameRateTrackingEnabled = true
                    loaded.append(try await ReferenceObject(from: url, configuration: config))
                } else {
                    loaded.append(try await ReferenceObject(from: url))
                }
            } catch {
                Log.perception.error("Could not load \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return loaded
    }

    func deviceTransform() -> simd_float4x4? {
        world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())?.originFromAnchorTransform
    }

    // MARK: - Tier 1 / Tier 2: image anchors

    private func handle(image update: AnchorUpdate<ImageAnchor>) {
        let anchor = update.anchor
        let name = anchor.referenceImage.name ?? ""
        guard anchor.isTracked else { return }

        // Tier 2: a packet label. Streams straight through as a live lock —
        // no promotion, because a consumable is meant to be picked up.
        if let consumableID = labelToConsumable[name] {
            labelC.yield(LabelLock(consumableID: consumableID,
                                   originFromLabel: anchor.originFromAnchorTransform,
                                   isTracked: true,
                                   timestamp: CACurrentMediaTime()))
            return
        }

        // Tier 1: a tray marker.
        guard let trayID = markerToTray[name],
              let manifest = manifests.first(where: { $0.trayID == trayID }) else { return }

        let originFromTray = anchor.originFromAnchorTransform * manifest.geometry.markerFromTray

        // Already promoted: the marker is now a correction signal only. If it
        // disagrees materially the tray was physically moved — re-anchor.
        if let existing = promoted[trayID] {
            let moved = positionalDelta(existing, originFromTray) > Tunables.trayMovedPositionThreshold
                     || angularDelta(existing, originFromTray) > Tunables.trayMovedAngleThreshold
            if moved {
                Log.perception.info("Tray \(trayID) moved — re-anchoring")
                promote(trayID: trayID, originFromTray: originFromTray)
            }
            return
        }

        // Not yet promoted: require N consecutive stable observations so a
        // single bad pose estimate never becomes the anchor for the case.
        var pending = pendingDetections[trayID] ?? (0, originFromTray)
        let jitter = positionalDelta(pending.transform, originFromTray)
        pending.count = jitter < 0.02 ? pending.count + 1 : 1
        pending.transform = originFromTray
        pendingDetections[trayID] = pending

        if pending.count >= Tunables.stableDetectionCount {
            promote(trayID: trayID, originFromTray: originFromTray)
            pendingDetections[trayID] = nil
        }
    }

    /// SPEC §7.1 — the single most important spatial decision in the build.
    /// ImageTrackingProvider reports pose only while the marker is visible, and
    /// the nurse faces away from the trays half the time. Promote to a world
    /// anchor once, then render against that forever.
    private func promote(trayID: String, originFromTray: simd_float4x4) {
        promoted[trayID] = originFromTray

        let anchor = WorldAnchor(originFromAnchorTransform: originFromTray)
        worldAnchorToTray[anchor.id] = trayID
        anchorStore.save(worldAnchorToTray)

        Task { [weak self] in
            guard let self else { return }
            do { try await self.world.addAnchor(anchor) }
            catch { Log.perception.error("addAnchor failed: \(error.localizedDescription)") }
        }

        poseC.yield(TrayPose(trayID: trayID,
                             originFromTray: originFromTray,
                             worldAnchorID: anchor.id,
                             timestamp: CACurrentMediaTime()))
        health.boundTrayCount = promoted.count
        Log.perception.info("Promoted \(trayID) to world anchor \(anchor.id)")
    }

    // MARK: - Tier 3: object anchors

    private func handle(object update: AnchorUpdate<ObjectAnchor>) {
        let anchor = update.anchor
        let name = anchor.referenceObject.name
        objectC.yield(ObjectLock(instrumentID: name,
                                 originFromObject: anchor.originFromAnchorTransform,
                                 extents: anchor.boundingBox.extent,
                                 isTracked: anchor.isTracked && update.event != .removed,
                                 timestamp: CACurrentMediaTime()))
    }

    // MARK: - World anchors

    private func handle(world update: AnchorUpdate<WorldAnchor>) {
        let anchor = update.anchor
        guard let trayID = worldAnchorToTray[anchor.id] else {
            // An anchor from a previous room or a previous build. Harmless.
            return
        }
        switch update.event {
        case .added, .updated:
            guard anchor.isTracked else { return }
            promoted[trayID] = anchor.originFromAnchorTransform
            poseC.yield(TrayPose(trayID: trayID,
                                 originFromTray: anchor.originFromAnchorTransform,
                                 worldAnchorID: anchor.id,
                                 timestamp: CACurrentMediaTime()))
        case .removed:
            promoted[trayID] = nil
            worldAnchorToTray[anchor.id] = nil
            anchorStore.save(worldAnchorToTray)
        @unknown default:
            break
        }
        health.boundTrayCount = promoted.count
    }

    // MARK: - Planes (display and filtering only, SPEC §7.3)

    private func handle(plane update: AnchorUpdate<PlaneAnchor>) {
        let a = update.anchor
        guard a.alignment == .horizontal else { return }

        let surface = SurfaceAnchor(
            id: a.id,
            kind: Self.classify(a),
            originFromAnchor: a.originFromAnchorTransform,
            extent: SIMD2(a.geometry.extent.width, a.geometry.extent.height))

        switch update.event {
        case .added, .updated:
            if let i = surfaces.firstIndex(where: { $0.id == a.id }) { surfaces[i] = surface }
            else { surfaces.append(surface) }
        case .removed:
            surfaces.removeAll { $0.id == a.id }
        @unknown default:
            break
        }
    }

    /// A guess, and deliberately so: the render path never depends on this, so
    /// a wrong label degrades a caption and nothing else.
    private static func classify(_ plane: PlaneAnchor) -> SurfaceKind {
        let area = plane.geometry.extent.width * plane.geometry.extent.height
        let height = plane.originFromAnchorTransform.translation.y
        if area > 0.8 { return .backTable }
        if height > 1.0 { return .mayoStand }
        if area > 0.2 { return .prepTable }
        return .unknown
    }

    // MARK: - Session events

    private func handle(event: ARKitSession.Event) {
        switch event {
        case .dataProviderStateChanged(let providers, let newState, let error):
            let names = providers.map { String(describing: type(of: $0)) }.joined(separator: ", ")
            Log.perception.info("Provider state \(names) → \(String(describing: newState))")
            if let error { Log.perception.error("Provider error: \(error.localizedDescription)") }
            if newState == .stopped {
                health.worldTracking = false
            }
        case .authorizationChanged(let type, let status):
            Log.perception.info("Authorization \(String(describing: type)) → \(String(describing: status))")
        @unknown default:
            break
        }
    }

    // MARK: - Manual bind (SPEC §8)

    /// Places the tray one metre in front of the wearer at table height. Not
    /// accurate — but "roughly the right tray glowing" beats "nothing at all"
    /// by an enormous margin when a marker refuses to detect on stage.
    func bindManually(trayID: String) {
        guard let device = deviceTransform() else { return }
        let forward = -device.columns.2.xyz
        var position = device.translation + forward * 1.0
        position.y = 0.92
        promote(trayID: trayID, originFromTray: simd_float4x4(translation: position))
        Log.perception.info("Manually bound \(trayID)")
    }
}

// MARK: - Anchor semantics persistence

/// SPEC §17. ARKit persists the anchor; the app persists what it means.
struct AnchorStore {
    private var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "anchor-bindings.json")
    }

    func load() -> [UUID: String] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    func save(_ bindings: [UUID: String]) {
        let raw = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
