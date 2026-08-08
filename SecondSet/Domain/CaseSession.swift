import Foundation
import Observation
import QuartzCore
import RealityKit
import simd

// SPEC §15. All mutable session state lives on the main actor. Engines
// compute, hop to main, and hand over a Sendable value. There is no shared
// mutable state across actors anywhere in this app.

@MainActor
@Observable
final class CaseSession {

    // MARK: - Observable state

    private(set) var manifests: [TrayManifest] = []
    private(set) var trays: [String: Tray] = [:]
    private(set) var guidance: GuidanceState = .idle
    private(set) var markedInPlay: [SlotRef] = []
    private(set) var health = PerceptionHealth()
    private(set) var lastError: String?

    /// Shown only in the debug panel. Never rendered in the immersive view —
    /// the nurse does not need to see what the recogniser thought it heard.
    private(set) var lastHeard: String = ""

    /// A request that has been heard and resolved but not yet accepted. The
    /// wearer taps "Find instrument" to act on it. See `PendingRequest`.
    private(set) var pending: PendingRequest?
    private var pendingExpiry: Date?

    /// True once the wearer has finished setup and started the case.
    var flow: AppFlow = .setup(.welcome)

    var phase: CasePhase = .setup {
        didSet { Task { await rebuildResolver() } }
    }

    /// Root of the preallocated entity pool. SPEC §14 — nothing is created or
    /// destroyed in response to a request.
    let rootEntity = Entity()

    var isRunning: Bool { perception != nil }
    var boundTrays: [Tray] { trays.values.filter(\.isBound).sorted { $0.id < $1.id } }
    var unboundTrays: [Tray] { trays.values.filter { !$0.isBound }.sorted { $0.id < $1.id } }

    // MARK: - Collaborators

    private var perception: (any PerceptionProvider)?
    private var voice: (any VoiceProvider)?
    private var renderer: GuidanceRenderer?
    private var tasks: [Task<Void, Never>] = []

    /// Tier 3 fusion state. SPEC §10.6 — hysteresis in both directions, or the
    /// highlight flickers between representations and looks broken.
    private var objectLocks: [String: ObjectLock] = [:]
    private var objectLockHits: [String: Int] = [:]

    private var guidanceExpiry: Date?
    /// Stack, not a single value: "back" should undo the most recent pass.
    private var passOrder: [SlotRef] = []

    // MARK: - Lifecycle

    func configure(perception: any PerceptionProvider, voice: any VoiceProvider) {
        self.perception = perception
        self.voice = voice
    }

    private var isPrepared = false
    private var enginesRunning = false

    /// Content and entity pool. Safe to call from the plain window, and it has
    /// to be: ARKit needs the immersive space, but the tray list in the control
    /// window does not, and showing an empty list until someone opens the
    /// theatre view reads as a broken app.
    func prepare() async {
        guard !isPrepared else { return }
        isPrepared = true

        manifests = ManifestStore.loadBundled()
        if manifests.isEmpty {
            lastError = "No tray manifests found in the bundle."
            Log.session.error("No manifests bundled — check Resources is in Copy Bundle Resources")
        }
        trays = Dictionary(uniqueKeysWithValues: manifests.map { ($0.trayID, Tray(manifest: $0)) })

        let renderer = GuidanceRenderer(root: rootEntity)
        renderer.preallocate(for: manifests)
        self.renderer = renderer

        await rebuildResolver()
    }

    /// Engines and streams. Only valid once an ImmersiveSpace is open —
    /// world-sensing providers deliver nothing without one. SPEC §5.
    func startEngines() async {
        await prepare()
        guard !enginesRunning else { return }
        enginesRunning = true

        do {
            try await perception?.start()
            try await voice?.start()
        } catch {
            lastError = error.localizedDescription
            Log.session.error("Engine start failed: \(error.localizedDescription)")
        }

        consumeStreams()
        startTickLoop()
    }

    func stop() async {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        await perception?.stop()
        await voice?.stop()
        enginesRunning = false
        guidance = .idle
        renderer?.clear()
    }

    private func consumeStreams() {
        guard let perception, let voice else { return }

        // One Task per stream. Never serialise them behind a single loop —
        // a slow handler on one stalls all the others. SPEC §7.2.
        tasks.append(Task { [weak self] in
            for await pose in perception.trayPoses { self?.apply(pose) }
        })
        tasks.append(Task { [weak self] in
            for await lock in perception.objectLocks { self?.apply(lock) }
        })
        tasks.append(Task { [weak self] in
            for await lock in perception.labelLocks { self?.apply(lock) }
        })
        tasks.append(Task { [weak self] in
            for await request in voice.requests { self?.handle(request) }
        })
    }

    /// 30 Hz is plenty for distance-based state: the crossfade itself is
    /// animated by RealityKit, not stepped here.
    private func startTickLoop() {
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                self?.tick()
            }
        })
    }

    // MARK: - Perception intake

    private func apply(_ pose: TrayPose) {
        guard var tray = trays[pose.trayID] else {
            Log.perception.debug("Pose for unknown tray \(pose.trayID)")
            return
        }
        tray.originFromTray = pose.originFromTray
        tray.worldAnchorID = pose.worldAnchorID
        trays[pose.trayID] = tray

        health.boundTrayCount = trays.values.count(where: \.isBound)
        renderer?.updateTray(tray, manifest: tray.manifest)
        Task { await rebuildResolver() }
    }

    private func apply(_ lock: ObjectLock) {
        if lock.isTracked {
            objectLocks[lock.instrumentID] = lock
            objectLockHits[lock.instrumentID, default: 0] += 1
        } else {
            objectLocks[lock.instrumentID] = nil
            objectLockHits[lock.instrumentID] = 0
        }
    }

    private func apply(_ lock: LabelLock) {
        // Tier 2 rides the same fusion path as Tier 3; a packet label is just
        // a reference object we did not have to train.
        let asObject = ObjectLock(instrumentID: lock.consumableID,
                                  originFromObject: lock.originFromLabel,
                                  extents: SIMD3(0.05, 0.005, 0.08),
                                  isTracked: lock.isTracked,
                                  timestamp: lock.timestamp)
        apply(asObject)
    }

    func reportError(_ message: String?) {
        lastError = message
        if let message { Log.session.error("\(message, privacy: .public)") }
    }

    func updateHealth(_ new: PerceptionHealth) {
        var h = new
        h.boundTrayCount = trays.values.count(where: \.isBound)
        health = h
    }

    // MARK: - Voice intake

    func handle(_ request: VoiceRequest) {
        switch request {
        case .resolved(let ref, let heard):
            lastHeard = heard
            raise(PendingRequest(heard: heard, options: [ref], raisedAt: Date()))

        case .ambiguous(let refs, let heard):
            lastHeard = heard
            raise(PendingRequest(heard: heard, options: Array(refs.prefix(3)), raisedAt: Date()))

        case .notOnField(let name, let heard):
            lastHeard = heard
            guidance = .notOnField(displayName: name)
            guidanceExpiry = Date().addingTimeInterval(Tunables.guidanceTimeout)
            renderer?.clear()

        case .markPassed:
            if let ref = guidance.activeSlot { markPassed(ref) }

        case .markReturned:
            if let ref = passOrder.last { markReturned(ref) }

        case .silent(let heard):
            // Fail invisibly. A wrong highlight costs trust permanently; a
            // silent miss costs a second. SPEC §14.
            lastHeard = heard
            Log.resolve.debug("Silent miss on: \(heard, privacy: .public)")
        }
    }

    // MARK: - Pending requests

    /// Surface a heard request for confirmation. Replaces any earlier pending
    /// request — the most recent thing the surgeon said is the one that matters.
    private func raise(_ request: PendingRequest) {
        pending = request
        // Long enough that a nurse mid-task can still act on it, short enough
        // that a stale request does not sit there implying it is current.
        pendingExpiry = Date().addingTimeInterval(30)
    }

    /// The wearer accepted the request. This is the only path into guidance.
    func confirmFind(_ ref: SlotRef? = nil) {
        guard let target = ref ?? pending?.single else { return }
        pending = nil
        pendingExpiry = nil
        show(target)
    }

    func dismissPending() {
        pending = nil
        pendingExpiry = nil
    }

    func show(_ ref: SlotRef) {
        // Long budget: this covers the walk to the tray, not the dwell once
        // there. See Tunables.travelTimeout.
        guidanceExpiry = Date().addingTimeInterval(Tunables.travelTimeout)
        // The tick loop immediately promotes this to far or near by distance.
        guidance = .guidingFar(ref)
        tick()
    }

    /// Debug-only: hold whatever guidance is currently showing open for a long
    /// while, bypassing both the travel and dwell timers. `simctl screenshot`
    /// round-trips run multiple seconds each and the real dwell window is 6s,
    /// which made verifying near-mode rendering from outside the headset a
    /// coin flip. Only ever called from the `-autodemo` path.
    func pinGuidanceForDebugging(seconds: TimeInterval = 120) {
        guidanceExpiry = Date().addingTimeInterval(seconds)
    }

    func stopGuiding() {
        guidance = .idle
        guidanceExpiry = nil
        renderer?.clear()
    }

    /// Every item on every registered tray, for the browse-and-tap fallback.
    /// Voice is the fast path, not the only path — a recogniser that will not
    /// cooperate must never leave the wearer with no way to find anything.
    var browsableItems: [(ref: SlotRef, name: String, tray: String)] {
        boundTrays.flatMap { tray in
            tray.manifest.slots.map { slot in
                (SlotRef.instrument(tray.id, slot.index), slot.displayName, tray.displayName)
            }
        }
        .sorted { $0.1 < $1.1 }
    }

    func beginListening() {
        guidance = .listening
        guidanceExpiry = Date().addingTimeInterval(Tunables.listenWindow)
        voice?.beginListening()
    }

    // MARK: - Marked state (SPEC §4 Phase 5)

    func markPassed(_ ref: SlotRef) {
        guard !markedInPlay.contains(ref) else { return }
        markedInPlay.append(ref)
        passOrder.append(ref)
        guidance = .idle
        renderer?.clear()
        renderer?.setGhost(ref, on: true, session: self)
        Task { await rebuildResolver() }
    }

    func markReturned(_ ref: SlotRef) {
        markedInPlay.removeAll { $0 == ref }
        passOrder.removeAll { $0 == ref }
        renderer?.setGhost(ref, on: false, session: self)
        Task { await rebuildResolver() }
    }

    // MARK: - Manual bind fallback (SPEC §8)

    func bindManually(trayID: String) {
        perception?.bindManually(trayID: trayID)
        if var tray = trays[trayID] {
            tray.boundManually = true
            trays[trayID] = tray
        }
    }

    // MARK: - Geometry

    /// Tier 1. Manifest geometry resolved through the tray's world anchor.
    func asPackedTransform(for ref: SlotRef) -> simd_float4x4? {
        guard let tray = trays[ref.trayID],
              let originFromTray = tray.originFromTray else { return nil }

        let g = tray.manifest.geometry

        if let ci = ref.consumableIndex {
            // Consumables are not slotted; park the marker at tray centre
            // until a Tier 2 label lock supplies a real pose.
            _ = ci
            return originFromTray * simd_float4x4(
                translation: SIMD3(g.interior.x * 0.5, g.slotHeight, g.interior.z * 0.5))
        }

        guard let slot = tray.manifest.slots.first(where: { $0.index == ref.index }) else { return nil }
        return originFromTray * slot.trayFromSlot(g)
    }

    /// The fusion rule, SPEC §10.6. Deliberately dead simple: a live lock wins
    /// if it is fresh and has been seen twice; otherwise geometry.
    func resolvedPose(for ref: SlotRef) -> (transform: simd_float4x4, tier: ConfidenceTier)? {
        if let id = instrumentID(for: ref),
           let lock = objectLocks[id],
           lock.isTracked,
           (objectLockHits[id] ?? 0) >= Tunables.objectLockRequiredHits,
           CACurrentMediaTime() - lock.timestamp < Tunables.objectLockStaleAfter {
            return (lock.originFromObject, .confirmed)
        }
        if let t = asPackedTransform(for: ref) { return (t, .asPacked) }
        return nil
    }

    func instrumentID(for ref: SlotRef) -> String? {
        guard let m = trays[ref.trayID]?.manifest else { return nil }
        if let ci = ref.consumableIndex {
            return ci < m.consumables.count ? m.consumables[ci].consumableID : nil
        }
        return m.slots.first { $0.index == ref.index }?.instrumentID
    }

    func describe(_ ref: SlotRef) -> (displayName: String, positionLabel: String, trayName: String)? {
        ManifestStore.describe(ref, in: manifests)
    }

    func footprint(for ref: SlotRef) -> SIMD2<Float> {
        guard let m = trays[ref.trayID]?.manifest,
              let slot = m.slots.first(where: { $0.index == ref.index })
        else { return SIMD2(0.06, 0.10) }
        return slot.footprintSize
    }

    // MARK: - Tick: far/near crossfade (SPEC §14)

    func tick() {
        if let expiry = pendingExpiry, Date() >= expiry {
            pending = nil
            pendingExpiry = nil
        }

        if let expiry = guidanceExpiry, Date() >= expiry {
            guidanceExpiry = nil
            guidance = .idle
            renderer?.clear()
            return
        }

        guard let ref = guidance.activeSlot,
              let perception,
              let pose = resolvedPose(for: ref) else { return }

        guard let device = perception.deviceTransform() else { return }
        let distance = simd_distance(device.translation, pose.transform.translation)

        // Hysteresis, or the state oscillates when the nurse stands at the
        // boundary and the highlight strobes between representations.
        let goingNear = Tunables.nearThreshold - Tunables.nearHysteresis
        let goingFar  = Tunables.nearThreshold + Tunables.nearHysteresis

        switch guidance {
        case .guidingFar where distance < goingNear:
            guidance = .guidingNear(ref, tier: pose.tier)
            // Arrival. Swap the long travel budget for the short dwell one —
            // the walk is over, so "ignored for 6s" becomes the right question
            // to ask instead of "still walking?". This is the ONLY place the
            // timer switches from travel to dwell; there is no other correct
            // moment to do it.
            guidanceExpiry = Date().addingTimeInterval(Tunables.guidanceTimeout)
        case .guidingNear where distance > goingFar:
            // Stepped back. Restore the long budget — they are travelling
            // again, not idling at the tray.
            guidance = .guidingFar(ref)
            guidanceExpiry = Date().addingTimeInterval(Tunables.travelTimeout)
        case .guidingNear(let s, let tier) where tier != pose.tier:
            // Tier flipped under us (lock acquired or lost) — re-render so the
            // callout wording and the outline style follow. Not an arrival
            // event, so the dwell timer is left alone.
            guidance = .guidingNear(s, tier: pose.tier)
        default:
            break
        }

        renderer?.render(guidance, session: self, deviceTransform: device)
    }

    // MARK: - Resolver

    /// Rebuilt on every tray register, pass, and phase change — the vocabulary
    /// is only ever what is actually on the field. SPEC §12.3.
    private func rebuildResolver() async {
        let boundIDs = Set(trays.values.filter(\.isBound).map(\.id))
        let onFieldManifests = manifests.filter { boundIDs.contains($0.trayID) }

        let resolver = Resolver(
            onField: ManifestStore.candidates(from: onFieldManifests),
            catalogue: ManifestStore.candidates(from: manifests),
            phase: phase,
            markedInPlay: Set(markedInPlay))

        voice?.setResolver(resolver)
    }
}
