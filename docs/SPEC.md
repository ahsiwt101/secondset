# Second Set — Build Spec

**Spatial instrument memory for the operating theatre · Apple Vision Pro · visionOS 2.0+**
**Hackathon proof of concept · 48 hours · 3 people**
**Version:** 2.0 — supersedes `nightingale-PRD.md` and `nightingale-SPEC.md`. Delete both.
**Updated:** 2026-08-08

One document. Product intent, perception architecture, CV training pipeline, build order, demo script. Nothing else supersedes it.

> **Name.** *Second Set* — a second set of eyes. It is exactly what the product is: the senior nurse standing over your shoulder, permanently, for every nurse. Avoids "Project Nightingale" (Google/Ascension health-data scandal, 2019 — anyone in health IT has that association) and "Copilot" (Microsoft).

---

## ⚠️ Read before writing any code

**1. Every API signature here is illustrative and may be wrong.** Written from memory of the SDK, not from the SDK. `ObjectTrackingProvider`, `ReferenceObject`, `SpeechAnalyzer`/`SpeechTranscriber`, `BillboardComponent`, and `RealityView` attachments all shift between releases. **Verify each against Xcode before building on it.** The math, the data formats, the architecture and the training pipeline are durable. The call signatures are not.

**2. Three hour-zero gates must be run by a human with the headset and a Mac.** They cannot be coded around and each can change the product. See §2.

**3. Object-tracking training takes hours of wall-clock time.** It must be kicked off in hour 0–2 or it will not be ready. This is the single most schedule-critical fact in the document. See §10.

**4. The visionOS Simulator supports none of this** — no world tracking, no image tracking, no object tracking, no planes, no real mic. One device, three developers: the mock layer (§18) is what makes the build parallel. Build it in hour one.

---

## 1. Positioning

### What it is, in one line

**Second Set puts the senior scrub nurse's spatial memory into the room, so a new or rotating nurse can find any instrument on their first day instead of their fiftieth.**

### The claim ladder — say these in this order

| Level | Claim | Confidence |
|---|---|---|
| **Primary** | Reduces time-to-proficiency for new and rotating scrub nurses | Strong. This is the pitch. |
| **Secondary** | Reduces retrieval time and repeated searching during a case | Strong for unfamiliar trays, weaker for an experienced scrub on a familiar set. Say so. |
| **Tertiary** | Improves situational awareness of what has left the tray | True, and carefully worded (§4, Phase 5) |
| **Never claimed** | Counts. Diagnoses. Guarantees anything. | See non-goals |

The primary claim is the one that survives a nurse in the audience. Lead with it.

### Users

**Primary — the new or rotating scrub nurse.** Month one on an unfamiliar service line. Knows the instruments in the abstract, does not know *this room's* trays. Gowned and gloved from Phase 3 onward; cannot touch the headset. Success metric: does not have to ask the senior nurse.

**Secondary — the circulating nurse.** Not sterile, can touch the device, does tray setup, fetches from the core. If sterility or battery becomes the blocking objection in Q&A, **the circulator is the better v1 wearer and you should say so out loud** — it dissolves both objections. Have that answer loaded.

**Not a user — the surgeon.** Never wears it, never interacts with it, never changes behaviour. Their speech is at most an input. Any design requiring the surgeon to do anything is dead on arrival.

### Non-goals — state these before you are asked

- **Not a surgical count device.** Does not replace, augment, or advise the manual instrument/sponge/needle count. That is a two-person verbal-and-visual protocol and Second Set sits entirely outside it.
- **Not a medical device.** No diagnostic claim, no safety claim, no FDA/HSA pathway. Regulatory posture of a laminated tray card.
- **Not autonomous.** It shows where a thing is. The human decides what to hand over.
- **No patient data.** No PHI ever touches the device. The app does not know whose case it is.
- **Slot-level position is "as packed," not "as observed."** See §1.1 — this is the most important honesty in the deck.

### 1.1 The honesty that makes the pitch survive an OR nurse

A sterile tray is packed to a standardised count sheet. On open, every instrument is where the sheet says. That is genuinely true, and it is what makes the manifest approach work.

It stops being true as the case proceeds. Instruments come off stringers, get laid out on the Mayo, come back wet and get put down somewhere else.

So the claim is tiered, and the UI wording is tiered with it:

| Layer | Durability | UI language |
|---|---|---|
| **Which tray** | Whole case | "Ortho Tray B · back table" — stated as fact |
| **Where in the tray** | Accurate at open, degrades | "As packed: row 2, position 4" — hedged in the string itself |
| **Visually confirmed** | Live, when the object tracker has a lock | Solid outline on the actual object. Only this layer is "observed." |

Three tiers of confidence, three visual treatments (§14). A nurse who sees you make this distinction unprompted will trust everything else you say.

---

## 2. Hour-zero gates

Three experiments. All three before the first line of feature code. Each has a defined pivot.

### 2.1 — Kick off object-tracking training (hour 0, blocking)

**This is first because it is the only thing on the critical path measured in hours of wall clock rather than hours of work.** Capture three hero objects, start Create ML training, let it bake while you build everything else. Full procedure in §10. If you have not started training by hour 2, cut CV and ship the geometry-only path.

### 2.2 — Mic viability (hour 0–2)

Vision Pro's mic array is beamformed toward the wearer with active suppression of other talkers. Capturing a masked surgeon two metres away and off-axis works directly against the hardware's tuning.

Test: teammate speaks instrument names from 2 m while the wearer faces 90° away. Measure recognition accuracy over 20 utterances.

```swift
// Ask for minimally-processed input. `.measurement` disables AGC and
// noise suppression where the platform honours it.
try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
```

**The pivot is already the default.** Primary interaction is **nurse-initiated** (pinch-to-find, plus wake phrase) — matches your workflow, matches the training pitch, and does not depend on this test. If the test passes, ambient surgeon capture becomes a bonus beat in the demo. If it fails, nothing changes. Run the test to know which slide to show, not to decide what to build.

### 2.3 — Provider co-existence and thermals (hour 2–4)

Run `WorldTrackingProvider` + `ImageTrackingProvider` + `ObjectTrackingProvider` + `PlaneDetectionProvider` in one `ARKitSession` and confirm all four deliver updates simultaneously. Then leave it running 20 minutes and watch `ProcessInfo.thermalState`.

If any combination is rejected or throttles: drop `PlaneDetectionProvider` after setup (it is only needed for surface labels, §7.3) and reduce object-tracking frequency. Know this at hour 4, not hour 40.

---

## 3. The perception stack — the core architectural idea

Everything else in this document follows from one decision: **three independent tiers of perception, layered so that failure degrades gracefully instead of going dark.**

```
┌────────────────────────────────────────────────────────────────────┐
│  TIER 3 — OBJECT       ObjectTrackingProvider                      │
│  "That exact item, right there."                                   │
│  Create ML reference objects · 3–5 hero instruments                │
│  Live 6DoF. Survives the item being picked up and moved.           │
│  ↓ if no lock                                                      │
├────────────────────────────────────────────────────────────────────┤
│  TIER 2 — LABEL        ImageTrackingProvider (packet labels)       │
│  "That suture packet."                                             │
│  Printed consumable labels used directly as reference images.      │
│  Zero training. Rock solid. Covers the consumables half of the HMW.│
│  ↓ if not present                                                  │
├────────────────────────────────────────────────────────────────────┤
│  TIER 1 — GEOMETRY     ImageTracking → WorldAnchor + manifest      │
│  "Ortho Tray B, back table, row 2 position 4 as packed."           │
│  Always available. Never blinks out. This is the render floor.     │
└────────────────────────────────────────────────────────────────────┘
```

**Why this is the right architecture and not a hedge:**

- **Tier 1 alone is a complete, working product.** If both CV tiers fail on stage, the demo still runs and still lands. That is the definition of demo insurance.
- **Tier 3 is what makes the demo undeniable.** The killer beat is: *pick up the instrument and move it — the highlight follows it.* No amount of polish on Tier 1 can fake that, and every judge instantly understands that you are actually seeing the object.
- **Position is identity.** You do not need to recognise 10,000 instruments that differ by millimetres if you know where they are. That is the actual insight of this product. CV confirms; geometry guarantees.

**Say this in the pitch:** *"We don't try to visually identify ten thousand near-identical instruments — that's a research problem. We make position the identity, and use vision to confirm it."* That reframes the absence of a giant trained model from a limitation into a design decision, which is what it is.

### Why there is no bespoke camera-frame CV model

Direct main-camera frame access on visionOS is behind Apple's **Enterprise APIs** and a managed entitlement you cannot obtain for a hackathon. **No model you could train would have pixels to run on.** `ImageTrackingProvider` and `ObjectTrackingProvider` need no entitlement and give you tracked 6DoF poses rather than a one-shot classification, which is strictly better here.

Verify current status at hour 0, but plan on gated. If a judge asks "why not just train a YOLO?", the answer is one sentence and it is a platform fact, not an excuse.

---

## 4. Core flow

Five phases. 1–2 happen once per room. 3 happens once per case, hands free. 4–5 are hands-free by absolute necessity.

### Phase 1 — Onboard the tray (off-device, before the case)

The catalogue step. A tray type is photographed from directly overhead, slot coordinates are read off in any image editor, and a JSON manifest is authored (§11). Hero instruments get a reference object trained (§10). Done once per tray type, ever — then every hospital using that tray type inherits it.

*This is the slide where you say "hospitals already maintain these as count sheets. We are digitising an artefact that already exists."*

### Phase 2 — Anchor the room

Nurse enters, dons the headset, taps **New Case**. Places labelled anchors on the surfaces in use: **Back Table**, **Mayo Stand**, **Ring Stand**, **Prep Table**. Gaze, pinch, pick a label.

Anchors persist as `WorldAnchor`s tied to the room. Re-entering OR 4 next week restores the skeleton — **the room is scanned once, not once per case.**

*Acceptance: anchors survive relaunch and re-don in the same room. Drift < 5 cm over 30 min.*

### Phase 3 — Register the trays

Circulator opens trays. Nurse looks at each one. Marker detection resolves a tray ID → loads the manifest → binds to a world anchor (§7.1). A translucent panel blooms above each tray: name, item count, and a small confidence chip.

*Acceptance: 3 trays registered and bound in under 60 seconds.*

### Phase 4 — Ask and guide ← the demo

Surgeon says something. Nurse triggers a find — **pinch**, or wake phrase *"Second Set, mosquito."* Both always available.

Then the guidance is **two-stage by distance**, which is exactly your workflow steps 6 and 7:

**FAR (> 1.5 m from the target tray) — "which tray and where"**
- Target tray gets a soft cyan glow on its rim
- Peripheral chevron at the FOV edge if the tray is out of view
- Callout, billboarded, at the tray edge:

```
┌─────────────────────────────────────┐
│  MOSQUITO FORCEPS  ·  curved 5"     │
│  Ortho Tray B  ·  back table        │
│  ↖  2.4 m                           │
└─────────────────────────────────────┘
```

**NEAR (< 1.5 m) — "which object"**
- Tray glow fades out. Slot highlight fades in.
- **Tier 3 lock:** solid outline hugging the actual tracked object. Follows it if moved.
- **Tier 1 only:** soft quad on the as-packed slot footprint, plus the string *"as packed · row 2 · pos 4"*
- Callout collapses to two lines: name and position.

The crossfade between modes is the single most "designed" moment in the app. Spend twenty minutes on it (§14).

**Ambiguity** — weak match, or a phrase that maps to several items ("scissors"): ranked 2–3 item card in amber. Gaze-and-pinch or say the number. **Never silently guess.**

**Not on the field** — requested item is in no registered manifest: *"Not on the field — ask circulator."* Five minutes of work, genuinely useful, and it makes the system look like it understands the room rather than just its own database. Build it.

**Dismiss** — auto-clear after 6 s, or on mark-passed.

### Phase 5 — Marked state

Pinch or say *"passed"* to mark an item in play; its slot renders as a dimmed ghost. *"Back"* restores it. A small **Marked In Play** panel lists what is off-tray.

> **Wording is load-bearing.** Without full-tray CV this state is *asserted by the nurse, never observed by the system*. A missed pinch means the model silently diverges from reality with no reconciliation path. The panel reads **"Marked in play"** — never "in play," never a number, never anything resembling a count. This one word is what keeps a reference aid from being mistaken for a count device.

---

## 5. Project skeleton

**ARKit world-sensing providers only deliver data while an `ImmersiveSpace` is open.** A windowed-only app gets nothing. Losing an hour to this on day one is a rite of passage you can skip.

```swift
@main
struct SecondSetApp: App {
    @State private var session = CaseSession()

    var body: some Scene {
        // 2D control surface: setup, tray list, debug panel, mock injection.
        WindowGroup {
            ControlView().environment(session)
        }
        .windowResizability(.contentSize)

        // Everything world-locked. Must stay open for the whole case.
        ImmersiveSpace(id: "theatre") {
            TheatreView().environment(session)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

struct TheatreView: View {
    @Environment(CaseSession.self) private var session

    var body: some View {
        RealityView { content in
            content.add(session.rootEntity)   // preallocated pool lives under here
        } update: { content in
            // Keep this cheap. Toggle isEnabled, set transforms. Nothing else.
        }
        .task { try? await session.startEngines() }
    }
}
```

**Info.plist** — a missing key is a launch-time crash, not a graceful degradation:

```
NSWorldSensingUsageDescription
NSMicrophoneUsageDescription
NSSpeechRecognitionUsageDescription
```

---

## 6. Module contracts

Define these in hour one and **never change them**. Three developers and one headset — these protocols are the only reason the work parallelises.

```swift
// ── Perception ──────────────────────────────────────────────────
protocol PerceptionProvider: AnyObject {
    /// Tray poses, from marker → promoted world anchor.
    var trayPoses: AsyncStream<TrayPose> { get }
    /// Live object locks. Tier 3. Empty stream is a valid state.
    var objectLocks: AsyncStream<ObjectLock> { get }
    /// Live consumable-label locks. Tier 2.
    var labelLocks: AsyncStream<LabelLock> { get }
    /// Tier 1 fallback: manifest geometry resolved to world space.
    func worldTransform(for slot: SlotRef) -> simd_float4x4?
    var surfaces: [SurfaceAnchor] { get }
    func start() async throws
}

// ── Voice ───────────────────────────────────────────────────────
protocol VoiceProvider: AnyObject {
    /// Emits resolved-or-ambiguous requests. Never emits raw text.
    var requests: AsyncStream<VoiceRequest> { get }
    /// Rebuild the constrained vocabulary. Called on every tray register.
    func setVocabulary(_ terms: [VocabTerm]) async
    func start() async throws
}

// ── Domain — owns all state ─────────────────────────────────────
@MainActor @Observable
final class CaseSession {
    private(set) var trays: [Tray]
    private(set) var guidance: GuidanceState     // .idle / .far / .near / .ambiguous
    private(set) var markedInPlay: Set<SlotRef>
    func register(trayID: String, at pose: TrayPose)
    func handle(_ request: VoiceRequest)
    func markPassed(_ slot: SlotRef)
    func markReturned(_ slot: SlotRef)
}

// ── Sendable payloads — value types only ────────────────────────
struct ObjectLock: Sendable {
    let referenceObjectName: String     // maps to instrumentID
    let originFromObject: simd_float4x4
    let boundingBox: BoundingBox
    let isTracked: Bool
    let timestamp: TimeInterval
}
```

Both providers ship with mocks from hour zero (§18). **Every engine returns `Sendable` value types. `Entity` never crosses an actor boundary.**

---

## 7. Spatial: coordinate systems and anchoring

```
world ──── originFromMarker ────▶ marker
                                   │  markerFromTray   (measured constant per tray type)
                                   ▼
                                 tray
                                   │  trayFromSlot     (from manifest geometry)
                                   ▼
                                 slot

world ──── originFromObject ────▶ object     (Tier 3 — independent path, no chain)
```

| Space | Origin |
|---|---|
| `world` | ARKit session origin, gravity-aligned, +Y up |
| `marker` | Centre of the printed reference image, +Z out of the image plane |
| `tray` | Tray's near-left interior corner, +X width, +Z length, +Y up |
| `slot` | Centre of an instrument's resting position |
| `object` | Reference object's own origin, from the trained USDZ |

**Write these first.** `simd_float4x4(translation:)` and `.xyz` on `SIMD4` are not standard library, and both are used everywhere:

```swift
extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t, 1)
    }
    init(yaw radians: Float) {
        self = simd_float4x4(simd_quatf(angle: radians, axis: [0, 1, 0]))
    }
    var translation: SIMD3<Float> { columns.3.xyz }
}
extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
```

Composing tray pose from a detected marker:

```swift
func originFromTray(marker: ImageAnchor, geometry: TrayGeometry) -> simd_float4x4 {
    let markerFromTray = simd_float4x4(translation: geometry.trayOriginInMarkerSpace)
                       * simd_float4x4(yaw: geometry.trayYawInMarkerSpace)
    return marker.originFromAnchorTransform * markerFromTray
}
```

Resolving a slot (Tier 1):

```swift
func worldTransform(for slot: SlotRef) -> simd_float4x4? {
    guard let tray = trays[slot.trayID],
          let originFromTray = tray.cachedOriginFromTray else { return nil }

    let g = tray.manifest.geometry
    let s = g.slots[slot.index]

    // Manifest stores slot positions normalized [0,1] over the interior footprint.
    let local = SIMD3<Float>(s.u * g.interiorSize.x,
                             g.slotHeight,
                             s.v * g.interiorSize.z)
    return originFromTray * simd_float4x4(translation: local)
}
```

`markerFromTray` is a **physical measurement**, not a guess. Measure once per tray type with a tape. Getting it wrong shifts every highlight on that tray by a constant offset — which is also the easiest bug in the build to spot and fix.

### 7.1 Critical: promote image anchors to world anchors

**This is the single most important spatial decision in the build.**

`ImageTrackingProvider` reports pose *only while the marker is visible*. The nurse faces away from the trays half the time. A naive implementation loses every tray pose constantly and highlights blink out at exactly the moment they are needed.

1. On first stable detection — N consecutive updates, low pose variance — compute `originFromTray`.
2. Immediately create a `WorldAnchor` at that transform and add it to `WorldTrackingProvider`.
3. Persist `worldAnchorID → trayID` in app storage.
4. **From then on, render against the world anchor, never the image anchor.** World anchors survive occlusion and persist across launches.
5. Keep image tracking as a *correction* signal only: if the marker reappears and disagrees by > 3 cm or > 5°, the tray was moved — re-anchor silently and log.

**Anchor persistence is split-brain by design.** ARKit persists the anchor; you persist the semantics. On relaunch, world anchors arrive as `.added` carrying only UUIDs. Without your own `[UUID: TrayBinding]` table, the room is a set of anonymous points.

### 7.2 ARKit session lifecycle

```swift
@MainActor
final class PerceptionEngine: PerceptionProvider {
    private let session = ARKitSession()
    private let world   = WorldTrackingProvider()
    private let planes  = PlaneDetectionProvider(alignments: [.horizontal])
    private var images: ImageTrackingProvider!
    private var objects: ObjectTrackingProvider?

    func start() async throws {
        let refImages = try await ReferenceImage.loadReferenceImages(inGroupNamed: "Markers")
        images = ImageTrackingProvider(referenceImages: refImages)

        // Tier 3 is optional by design — absence must not break startup.
        if ObjectTrackingProvider.isSupported,
           let refObjects = try? await ReferenceObject.loadReferenceObjects(
                                    inGroupNamed: "Instruments"),
           !refObjects.isEmpty {
            objects = ObjectTrackingProvider(referenceObjects: refObjects)
        }

        let auth = await session.requestAuthorization(for: [.worldSensing])
        guard auth[.worldSensing] == .allowed else { throw PerceptionError.denied }

        var providers: [any DataProvider] = [world, planes, images]
        if let objects { providers.append(objects) }
        try await session.run(providers)

        // One Task per provider. Never serialise them behind a single loop —
        // a slow handler on one stalls all the others.
        Task { for await u in images.anchorUpdates  { await handleImage(u) } }
        Task { for await u in world.anchorUpdates   { await handleWorld(u) } }
        Task { for await u in planes.anchorUpdates  { await handlePlane(u) } }
        if let objects {
            Task { for await u in objects.anchorUpdates { await handleObject(u) } }
        }
        Task { for await e in session.events { await handleEvent(e) } }
    }
}
```

Providers can independently transition to `.stopped` — authorisation revoked, thermal, internal error. Watch `session.events` for `dataProviderStateChanged` and enter a defined degraded mode (§17) rather than rendering stale poses.

### 7.3 Surface binding

Surface labels come from `PlaneDetectionProvider` horizontal planes: take the plane whose extent contains the tray origin's XZ projection and whose Y is nearest below.

**Display and filtering only.** The render path never depends on it, so a wrong guess degrades a label, not a highlight. Drop the provider entirely after setup if thermals bite.

---

## 8. Tier 1 — tray markers

`ReferenceImage` needs each marker's **true physical size in metres**. Wrong size means wrong depth, and wrong depth means the highlight floats.

| Property | Spec | Why |
|---|---|---|
| Physical size | ≥ 10 × 10 cm | Detection range and pose stability scale with apparent size |
| Feature density | High, non-repeating, aperiodic | Repeating patterns cause pose flips |
| Rotational symmetry | **None** | Symmetric markers are orientation-ambiguous → tray renders rotated |
| Contrast | High, **matte** | Theatre lighting is bright and direct; gloss blows out features |
| Substrate | Matte laminate or adhesive label on rigid backing | Sterile wrap is semi-reflective and wrinkles. Never print on it. |
| Mounting | Flat rigid surface — tray handle or a stiff card clipped to the rim | Flexible mounts deform and break pose estimation |

Use high-entropy noise-like art, **not logos or text** — text is low-feature and periodic. Run every candidate through Xcode's asset-catalog reference-image quality check and reject anything not rated high.

> **Demo trick worth 30 seconds of setup:** your deck says "register via QR code," and a reference image can be *any* high-entropy image — **including something that looks exactly like a QR code**. You get the "scan the tray" read the audience expects, with ARKit image tracking underneath and zero entitlement risk. Do this.

**Backup identity path (non-negotiable, §19 hour 30):** print a human-readable short code beside each marker — `ORT-01`, `ORT-02`. Manual bind = pinch the tray, pick the code from a list. Ten seconds of work that turns a total demo failure into a minor one.

---

## 9. Tier 2 — consumable labels

**This tier is nearly free and it covers the "consumables" half of your problem statement, which nothing else in the build touches.**

Suture packets, blade packets and sponge packaging carry large, flat, high-contrast **printed labels**. Those labels are, without modification, excellent ARKit reference images: high feature density, aperiodic, matte, asymmetric, and already glued to the item. They are the single easiest thing to track in the entire theatre — the exact opposite of polished steel.

**Procedure:**
1. Photograph each packet label flat, straight-on, evenly lit, high resolution.
2. Crop to the label, add to the `Markers` asset catalog group, set the **true physical width in metres** (measure it — a Vicryl packet label is around 6–9 cm wide).
3. Check the quality rating. Reject anything not high. Dense drug-style labels with lots of small type and a barcode rate very well.
4. Map `referenceImageName → consumableID` in the manifest.

**What this buys you:**
- Real visual identification of a real item, with **zero training time**, working from hour 4.
- Sutures are among the highest-frequency and most error-prone verbal requests in surgery — "2-0 Vicryl on a CT-1" — and the packets look identical to a novice. This is a genuinely strong use case, not a filler feature.
- **A demo beat: pick up the packet and it stays outlined in your hand.** Same "wow" as object tracking, available on day one.

Keep the total reference-image count modest (markers + labels under ~10 combined) and verify the simultaneous-tracking ceiling at hour 2.

---

## 10. Tier 3 — training a CV model on your own items

**This is the section you asked for. It answers: how do I train recognition on my personal set of objects?**

The answer is `ObjectTrackingProvider` (visionOS 2.0+) with **reference objects trained in Create ML**. First-party, no camera entitlement, no server, no PyTorch, no labelled dataset. You give it a 3D model of your object; it gives you live 6DoF tracking of that object in the room.

### 10.1 The pipeline

```
  Physical object
        │
        │  ① CAPTURE — photogrammetry (iPhone) or an existing CAD/print mesh
        ▼
   textured USDZ  (real-world scale, realistic texture)
        │
        │  ② TRAIN — Create ML ▸ Spatial ▸ Object Tracking
        │            Apple Silicon Mac. HOURS. Start this at hour 0.
        ▼
   Foo.referenceobject
        │
        │  ③ BUNDLE — asset group "Instruments" in the app bundle
        ▼
   ObjectTrackingProvider(referenceObjects:) ──▶ ObjectAnchor, live 6DoF
```

### 10.2 ① Capture — getting the USDZ

Three routes, best first.

**Route A — you already have the mesh (best).** If any hero item is 3D printed, you have its exact geometry. Zero photogrammetry error, and matte PLA is non-specular, which is ideal. Print in a light, matte, non-white colour with visible surface texture. If the venue or your uni has a printer, print 3–4 chunky instrument replicas overnight — this is the highest-quality path by a distance.

**Route B — iPhone Object Capture.** Apple's Object Capture (Reality Composer app on iOS, or Apple's sample scanning app; Polycam and Scaniverse also export USDZ). LiDAR-equipped iPhone Pro strongly preferred.

Capture discipline — this determines everything downstream:
- Matte, plain, **non-reflective** background. A grey or mid-tone cloth.
- Diffuse even lighting. No hard shadows, no specular hotspots, no window behind.
- Turntable if you have one. 60–120 photos, orbiting in 2–3 rings of elevation.
- Capture the underside separately if the object will ever be seen from below.
- **Verify real-world scale in the exported USDZ.** A mis-scaled model trains a tracker that will never find your object.

**Route C — Mac photogrammetry.** RealityKit's `PhotogrammetrySession` on macOS from a folder of photos. Same capture discipline, more control, more setup time.

### 10.3 Object suitability — read this before you choose your items

Object tracking is very good at some objects and hopeless at others. Choosing badly here wastes your entire CV budget, and you will not find out until training finishes.

| Works | Fails |
|---|---|
| Rigid | **Deformable** — plushies, cloth, anything that squashes |
| Opaque, matte | **Specular** — polished steel, chrome, mirror finishes |
| Textured or geometrically distinctive | Featureless, uniform, glossy |
| Asymmetric | **Rotationally symmetric** — plain bottles, cylinders, spheres |
| Roughly 10–60 cm, chunky | Thin, flat, tiny — thin scissors and needle holders track poorly |
| Mostly stationary | Fast motion |

**Note what this rules out: polished surgical steel is close to the worst-case object for this technology.** Thin, specular, symmetric. That is not a limitation you can engineer around in 48 hours.

### 10.4 The consequence: demo on an orthopaedic tray

**Recommended pivot, and I'd make it the plan.** Orthopaedic instruments — mallets, rasps, broaches, reamers, drills, chunky retractors, box osteotomes — are large, geometrically distinctive, often part-matte or part-polymer, and asymmetric. **They are the one class of real surgical instrument that this tracker handles well.**

It also makes the deck stronger, not weaker:
- Your own trends slide already names orthopaedic volume and sterile-processing capacity as the pressure point.
- Ortho is where the tray-count problem is genuinely worst — an ortho case can open a dozen trays.
- Ortho is heavily specialised, so the rotating-nurse unfamiliarity story is sharpest there.

**If you cannot source ortho instruments, use hardware.** Ortho instruments look like hardware-store tools, which means hardware-store tools look like ortho instruments. A cordless drill, a rubber mallet, a chunky pipe wrench, a socket set — all matte, chunky, asymmetric, and *all track beautifully*. Wrapped on a blue drape with printed tray markers, in a headset, with the callouts naming them as ortho instruments, this reads far better than plushies and takes the same afternoon.

**Do not use:** plushies (deformable), clear or plain bottles (symmetric, transparent), anything chrome.

### 10.5 ② Train — Create ML

Requirements: **Apple Silicon Mac**, recent macOS, Create ML (ships with Xcode — `Xcode ▸ Open Developer Tool ▸ Create ML`).

1. New project → **Spatial** → **Object Tracking**.
2. Drop in the USDZ.
3. Set the **viewing angles** the object will be seen from. "All angles" is the safe default for an item on a tray that may be picked up; constraining to upright/front trains faster and tracks more reliably if the object genuinely only sits one way. For tray items that will be lifted: all angles.
4. Confirm the bounding box and real-world scale look right in the preview. **If scale is wrong, fix the USDZ — do not train.**
5. Train. Export `.referenceobject`.

**Wall-clock cost is the whole story.** Expect **hours per object** on M-series silicon. Apple's own guidance is a few hours; treat 3–5 h as your planning number and verify with your first run.

**Therefore, the schedule is non-negotiable:**

| Hour | Action |
|---|---|
| 0–1 | Capture 3 hero objects |
| 1–2 | Verify USDZ scale and texture, queue all three in Create ML |
| 2–~14 | **Training runs unattended while you build everything else** |
| ~14 | Reference objects land, drop into the bundle, wire up Tier 3 |

If you have more than one Apple Silicon Mac, train in parallel — one object per machine. **Three hero objects is the target. Five is a stretch. Do not attempt twenty.**

Verify the runtime ceiling on simultaneously loaded reference objects (believed around 10) at hour 2.

### 10.6 ③ Runtime

```swift
let refObjects = try await ReferenceObject.loadReferenceObjects(inGroupNamed: "Instruments")
let objects = ObjectTrackingProvider(referenceObjects: refObjects)
try await session.run([objects])

for await update in objects.anchorUpdates {
    let a = update.anchor                       // ObjectAnchor
    guard a.isTracked else { continue }         // drop stale locks immediately
    await session.apply(ObjectLock(
        referenceObjectName: a.referenceObject.name,   // == instrumentID
        originFromObject:    a.originFromAnchorTransform,
        boundingBox:         a.boundingBox,
        isTracked:           a.isTracked,
        timestamp:           CACurrentMediaTime()))
}
```

**Name the reference object exactly the `instrumentID` from the manifest.** That one convention removes an entire mapping layer.

**Fusion rule — keep it dead simple:**

```
if a Tier 3 lock exists for the requested instrumentID
   and it was updated within 500 ms
   and isTracked == true
      → render the outline at the object pose, label it "confirmed"
else
      → render the Tier 1 slot quad, label it "as packed"
```

Hysteresis: require two consecutive tracked updates before switching to Tier 3, and 500 ms of loss before falling back to Tier 1. Without this the highlight flickers between the two representations and looks broken.

### 10.7 If Tier 3 is not ready in time

Ship Tiers 1 and 2. The demo still works, the pitch is unchanged, and the packet-tracking beat (§9) covers the "it's really seeing things" moment. Say "object-level tracking is trained per instrument and takes hours per item — here are three; the pipeline scales offline." That is true and it sounds like engineering maturity, because it is.

### 10.8 Plan C — the classification route, and why not to take it

If you specifically need *classification* rather than 6DoF pose, the conventional path is Create ML **Object Detection**: 50–100 annotated photos per class, trains in under an hour, exports a Core ML model.

**But it has nowhere to run.** visionOS will not give your app camera frames. You would need a companion iPhone pointed at the tray, streaming detections to the headset over the local network — a second device, a networking layer, and a coordinate-frame registration problem between the phone's camera and the headset's world origin, all in 48 hours.

**Do not do this.** It is strictly worse than §10.5 on every axis that matters here. Listed only so you can answer it in Q&A in one sentence.

---

## 11. Manifest format

```json
{
  "trayID": "ORT-01",
  "displayName": "Ortho Basic Tray",
  "procedure": "total_knee",
  "markerImageName": "marker_ort_01",
  "geometry": {
    "_units": "metres",
    "interiorSize": [0.46, 0.05, 0.28],

    "_note": "Pose of the TRAY origin in MARKER space. Split into translation + yaw so it is hand-measurable; markers mount flat so roll and pitch are zero.",
    "trayOriginInMarkerSpace": [0.23, 0.0, -0.02],
    "trayYawInMarkerSpaceDegrees": 0.0,

    "slotHeight": 0.012
  },
  "slots": [
    {
      "index": 0,
      "instrumentID": "mallet_ortho_1lb",
      "displayName": "Orthopaedic Mallet 1 lb",
      "aliases": ["mallet", "hammer", "the mallet"],
      "u": 0.14, "v": 0.22,
      "footprint": [0.09, 0.28],
      "label": "row 2 · pos 4",
      "referenceObjectName": "mallet_ortho_1lb",
      "usagePhase": "exposure"
    },
    {
      "index": 1,
      "instrumentID": "mosquito_curved_5in",
      "displayName": "Mosquito Forceps, curved 5\"",
      "aliases": ["mosquito", "snap", "small clamp"],
      "u": 0.31, "v": 0.55,
      "footprint": [0.03, 0.13],
      "label": "row 3 · pos 1",
      "referenceObjectName": null,
      "usagePhase": "any"
    }
  ],
  "consumables": [
    {
      "consumableID": "vicryl_2_0_ct1",
      "displayName": "2-0 Vicryl · CT-1",
      "aliases": ["two oh vicryl", "2-0 vicryl", "vicryl", "two oh"],
      "referenceImageName": "label_vicryl_2_0_ct1"
    }
  ]
}
```

- `u`, `v` are normalised `[0,1]` over the interior footprint — so a layout can be authored from an overhead photograph with no metric measurement.
- `footprint` sizes the highlight quad to hug the item rather than being a fixed dot. This matters more than it sounds.
- `label` is the human string, decoupled from geometry, so it can match the hospital's actual count sheet wording.
- `referenceObjectName: null` means Tier 1 only for that slot. Most slots will be null. That is fine and expected.
- `usagePhase` feeds the resolver prior (§13).

**Authoring:** photograph the tray from directly overhead, read normalised coordinates off in any image editor. ~5 minutes per tray.

**Scope: 3 trays × 12–20 items.** Not one tray — with one tray "which tray" is not a question and half your demo evaporates. Not five trays — nobody is grading manifest breadth.

> **Do not build a slot editor.** It is the most seductive way to lose a hackathon day. Author the JSON by hand.

---

## 12. Voice pipeline

The vocabulary is the product. Three trays ≈ 50 items ≈ ~70 distinct spoken forms. That is a **closed-set match**, not open-vocabulary recognition, and it is the entire reason this works.

### 12.1 Trigger model

**Primary — nurse-initiated. Two paths, both always live:**
- **Pinch-to-find** — pinch opens a 3 s listening window. Deterministic, works in noise, and it is what your workflow step 5 describes.
- **Wake phrase** — *"Second Set, mosquito."* Hands fully committed.

**Stretch — ambient capture.** If §2.2 passes, add a toggle that listens continuously for instrument names without a wake word. Demo it as a bonus beat. Never make the demo depend on it.

Rationale worth stating in Q&A: *the nurse already heard the surgeon.* The system does not need to hear the request — it needs the nurse to be able to ask "where" without hands. Nurse-initiated is more reliable, more honest, and loses almost nothing.

### 12.2 Recogniser

Two options. Pick one by hour 3 and stop looking.

**`SpeechAnalyzer` / `SpeechTranscriber`** (the modern streaming stack) — better designed for continuous streaming, better timing, better volatile-result semantics.

```swift
// Verify shapes against the SDK — this is a sketch.
let transcriber = SpeechTranscriber(
    locale: Locale(identifier: "en-US"),
    reportingOptions: [.volatileResults],
    attributeOptions: [.audioTimeRange])

let analyzer = SpeechAnalyzer(modules: [transcriber])
try await analyzer.start(inputSequence: micStream)

for try await result in transcriber.results {
    let text = String(result.text.characters)
    result.isFinal ? onFinal(text) : onPartial(text)
}
```
Also handle the locale-asset install request — the model may need downloading on first run. Do this at app launch, not mid-demo.

**`SFSpeechRecognizer`** (the guaranteed-works fallback):

```swift
let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
let request = SFSpeechAudioBufferRecognitionRequest()

request.requiresOnDeviceRecognition = true    // hard requirement: no theatre audio leaves the device
request.shouldReportPartialResults  = true    // required for early commit
request.taskHint                    = .search // short, keyword-like utterances
request.contextualStrings           = vocabulary
```

**Decision rule: whichever one exposes contextual biasing in your target release wins.** Biasing the recogniser toward ~70 surgical terms is worth far more than streaming elegance. If `SpeechAnalyzer` has no contextual-strings equivalent, use `SFSpeechRecognizer` and move on.

### 12.3 Two gotchas that shape the design

1. **`contextualStrings` has a practical ceiling** — historically ~100 phrases, with effectiveness degrading well before any hard limit. Submit **only aliases for currently-registered trays, ranked by expected frequency, capped ~80**. Rebuild the list on every tray register. This is exactly why constrained vocabulary is the strategy.

2. **Do not trust ASR confidence.** On-device recognition frequently reports `0.0` on correct final results and never populates it on partials. **Score matches yourself** (§13). If you discover confidence *is* populated in your release, add it as a fifth signal — never depend on it.

### 12.4 Latency and early commit

| Stage | Budget |
|---|---|
| Mic capture buffer | 20–50 ms |
| ASR partial emission | 100–300 ms |
| **Silence-based endpointing** | **300–500 ms ← dominates** |
| Resolution (§13) | < 5 ms |
| Render at next frame | ≤ 11.1 ms |
| **Total, waiting for final** | ~450–870 ms |

**Early commit removes the silence window.** Utterances are short and the set is closed, so evaluate every partial and commit the moment one uniquely resolves:

```swift
func onPartial(_ text: String) {
    let ranked = resolver.rank(text)
    guard let top = ranked.first else { return }
    let margin = top.score - (ranked.dropFirst().first?.score ?? 0)

    if top.score >= 0.80 && margin >= 0.25 {
        commit(top.slot)          // ~250–400 ms end to end
    }
    // Otherwise let the utterance finish and decide on the final.
}
```

**Target: under 500 ms** from end of speech to guidance. That is the line between "predictive" and "lookup." Past ~1.5 s the nurse has already turned around.

**Thrash guard:** after committing, suppress further commits for **800 ms**. Partials mutate as recognition refines; without a lock, one utterance fires two highlights. *800, not 1200 — your demo script fires three requests in quick succession and a 1200 ms lock will silently swallow one. Rehearse the pacing.*

**Nothing is recorded or persisted.** Rolling buffer, discarded. Put it on the privacy slide; someone will ask.

---

## 13. Resolution algorithm

ASR confidence is unusable, so score directly. **The scoring is normalised so that every signal can actually influence the outcome** — a naive weighted sum makes phonetic matching mathematically incapable of clearing the commit threshold, which silently kills the entire mishearing-recovery path.

```swift
struct Match { let slot: SlotRef; let score: Double }

func rank(_ heard: String) -> [Match] {
    let norm = heard.lowercased()
                    .trimmingCharacters(in: .punctuationCharacters)

    return candidates.map { c in

        // ── Lexical score, normalised to [0, 1]. One signal, three tiers. ──
        let lexical: Double
        if c.aliases.contains(norm) {
            lexical = 1.00                                   // exact alias
        } else if c.aliases.contains(where: { $0.hasPrefix(norm) || norm.hasPrefix($0) }) {
            lexical = 0.85                                   // clean prefix — "metz" vs "metzenbaum"
        } else {
            // ASR errors are acoustic, not typographic: "metz" mishears as
            // "mets"/"maids", not as a random edit. Double Metaphone codes,
            // compared by normalised Levenshtein. Capped below prefix tier.
            lexical = min(0.80, c.aliases.map { phoneticSimilarity(norm, $0) }.max() ?? 0)
        }

        // ── Prior: usage frequency at this phase of the case, [0, 1]. ──
        let prior = usagePrior(c, phase: session.phase)

        // ── Recency penalty: already marked in play → less likely. ──
        let recency = session.markedInPlay.contains(c.slot) ? -0.15 : 0.0

        return Match(slot: c.slot, score: 0.85 * lexical + 0.15 * prior + recency)
    }
    .sorted { $0.score > $1.score }
}
```

**Reachability check — do this arithmetic for any weights you change:**

| Case | Max score | Clears? |
|---|---|---|
| Exact alias, zero prior | 0.85 | ✅ commits |
| Prefix match, zero prior | 0.72 | ✅ commits |
| Strong phonetic (0.75), zero prior | 0.64 | → disambiguation |
| Weak phonetic (0.50) | 0.43 | → silent |

Every tier is reachable. That was not true of the previous version, where nothing below an exact match could ever clear the 0.55 floor and phonetic matching was dead code.

**Decision policy** — a partial is provisional and may still mutate, so committing on one clears a higher bar:

| Result | Condition | Action |
|---|---|---|
| Partial | `top ≥ 0.80` and `margin ≥ 0.25` | Commit early — guide now |
| Partial | anything else | Wait for the final |
| Final | `top ≥ 0.65` and `margin ≥ 0.15` | Commit |
| Final | `top ≥ 0.50` | Disambiguation card, top 3, amber |
| Final | `top < 0.50` | **Do nothing. Render no UI at all.** |
| Any | matches nothing in any registered manifest | *"Not on the field — ask circulator"* |

That penultimate row is a product decision expressed in code: **a wrong highlight costs trust permanently; a silent miss costs one second.**

**Tune against a recorded corpus, not intuition.** Around hour 4, record 100 utterances of your demo vocabulary in a noisy room. That corpus is your regression set — re-run it every single time the resolver changes.

### Alias table (seed — extend to your actual items)

| Spoken | Resolves to |
|---|---|
| mosquito, snap, small clamp | Halstead mosquito forceps |
| mallet, hammer | Orthopaedic mallet |
| kelly, clamp | Kelly hemostat |
| metz, metzenbaum, tissue scissors | Metzenbaum scissors |
| mayo, heavy scissors | Mayo scissors |
| ten blade, 10 blade, knife | #10 scalpel on #3 handle |
| adson, pickups, forceps | Adson tissue forceps |
| needle driver, needle holder, driver | Mayo-Hegar needle holder |
| bovie, cautery, buzz | Electrosurgical pencil |
| rongeur, biters | Bone rongeur |
| osteotome, chisel | Box osteotome |
| army navy, richardson, deaver | Retractors — deliberate disambiguation set |
| two oh vicryl, 2-0 vicryl | 2-0 Vicryl CT-1 |

Keep at least one deliberately ambiguous term ("scissors", "retractor") in the demo set. The disambiguation card is a feature and you want to show it.

---

## 14. Rendering and spatial UX

### Entity pooling

**Never create or destroy entities in response to a request.** Material compilation and entity insertion cause frame hitches, and a hitch on the key interaction is unacceptable.

**Preallocate at register time:** per tray, one rim-glow entity + one slot quad + one object outline + one callout attachment, all `isEnabled = false`. A request toggles visibility and sets transforms. Nothing else.

### The three visual treatments — one per confidence tier

| Tier | Treatment | Reads as |
|---|---|---|
| **Confirmed** (object/label lock) | Solid cyan outline hugging the tracked bounding box. Follows the object. | "That one." |
| **As packed** (manifest geometry) | Soft cyan emissive quad on the slot footprint, ~40% opacity, gentle pulse. | "Should be here." |
| **Ambiguous** | Amber. Two or three candidates, each dimmer than a committed highlight. | "Pick one." |

**Build the glow as an unlit emissive quad with additive blending**, sized from the slot `footprint`, laid flat on the tray. Cheapest option, reads well in bright rooms, no custom shaders. Do not start with an inverted-hull outline shell — it looks best and needs per-instrument meshes you do not have.

### Far/near crossfade

The distance-driven transition from "which tray" to "which object" is the most designed moment in the app and the thing that will make it feel like a product rather than a demo.

- Threshold at **1.5 m**, with **20 cm of hysteresis** so it does not oscillate when the nurse stands at the boundary.
- Crossfade over **250 ms**: tray rim glow fades out, slot highlight fades in, callout collapses from three lines to two.
- Everything eases. A quad that pops in reads as a bug; 150 ms ease-in with a subtle pulse reads as intentional. **Twenty minutes of work for a disproportionate share of perceived quality.**

### Callout panel

SwiftUI view attached to a RealityKit entity. Must be **billboarded toward the wearer** — `BillboardComponent` if available in your release, otherwise manual per-frame rotation. Un-billboarded text viewed obliquely is illegible. Offset ~8 cm above the tray plane to avoid z-fighting and occlusion by the tray rim.

### Peripheral chevron

Project the tray's world position into view space, clamp to the viewport border:

```swift
let viewFromWorld = camera.transform.matrix.inverse
let posInView     = (viewFromWorld * SIMD4(trayWorldPos, 1)).xyz
let onScreen      = posInView.z < 0    // negative Z is in front in view space
```

**First thing on the cut list.** Highest effort, lowest demo value.

### UX principles

The nurse is doing surgery-adjacent work. The interface budget is close to zero.

1. **Periphery, never centre.** Nothing renders over the sterile field or over her hands.
2. **One target at a time.** A new request replaces the old. No stacking.
3. **Light does the work, not labels.** Text is secondary confirmation.
4. **One meaning per colour.** Cyan = requested. Amber = ambiguous. Dim ghost = marked in play. **No red anywhere** — red in a theatre means something else entirely.
5. **Silence is the default state.** Between requests the display is essentially empty.
6. **Fail invisibly.** On a miss, show nothing.
7. **Never block.** No modal requiring interaction to clear. Everything times out.

---

## 15. Concurrency

Swift 6 strict concurrency will reject the naive version. Fix the actor topology up front.

```
┌──────────────────────────────────────────────────────────┐
│  @MainActor                                              │
│    CaseSession (@Observable)  ← single source of truth   │
│    RealityKit entity mutation ← must be MainActor        │
│    SwiftUI views                                         │
└────────────────▲─────────────────────▲───────────────────┘
                 │ await               │ await
    ┌────────────┴──────┐   ┌──────────┴─────────┐
    │ PerceptionEngine  │   │ VoiceEngine        │
    │ actor             │   │ actor              │
    │ ARKit AsyncSeqs   │   │ AVAudioEngine tap  │
    └───────────────────┘   └────────────────────┘
```

- **All mutable session state lives on `@MainActor`.** Engines compute, hop to main, hand over a value. No shared mutable state across actors, ever.
- **Every cross-actor payload is `Sendable`** — value types only. `simd_float4x4` and your model structs qualify. `Entity` does not. Never pass an entity off the main actor.
- **The audio tap callback is real-time.** No allocation, no locking, no `await`. Copy the buffer into the recognition request and return.

---

## 16. State machine

```
                 ┌─────────┐
                 │  IDLE   │◀──────────── timeout (6s)
                 └────┬────┘                    │
   pinch / wake       │                         │
                      ▼                         │
              ┌───────────────┐                 │
              │  LISTENING    │                 │
              └───────┬───────┘                 │
                      ▼                         │
              ┌───────────────┐                 │
              │  RESOLVING    │                 │
              └──┬────┬────┬──┘                 │
       <0.50     │    │    │  ≥0.65             │
                 ▼    │    ▼                    │
            (silent)  │  ┌──────────────┐       │
                      │  │ GUIDING_FAR  │       │
        0.50–0.65     │  └──────┬───────┘       │
                 ▼    │         │ <1.5m ⇄ >1.7m │
          ┌───────────▼──┐      ▼               │
          │  DISAMBIG    │  ┌──────────────┐    │
          └───────┬──────┘  │ GUIDING_NEAR ├────┘
                  │         └──────┬───────┘
                  └─ selection ───▶│ pinch / "passed"
                                   ▼
                            ┌──────────────┐
                            │ MARKED_IN_   │── "back" ──▶ available
                            │ PLAY         │
                            └──────────────┘
```

Per-instrument state is separate: `available → markedInPlay → available`, plus terminal `offField` for dropped or contaminated.

---

## 17. Persistence, degraded states, performance

| Data | Store | Lifetime |
|---|---|---|
| World anchors | ARKit, system-managed | Per room, across launches |
| `anchorUUID → trayID` | App storage — JSON in Application Support | Across launches |
| Tray manifests | Bundled JSON, read-only | Ships with app |
| Reference objects / images | App bundle, read-only | Ships with app |
| Session events | In-memory only | Discarded at case end |
| Audio | **Never persisted** | Rolling buffer |

Prune bindings whose anchors do not reappear within 30 s of session start — handles trays removed between cases without accumulating garbage.

**Every degraded state needs defined behaviour. Undefined behaviour in front of judges looks like a crash even when it isn't.**

| Condition | Detection | Behaviour |
|---|---|---|
| World tracking relocalising | `session.events` | Dim highlights, "relocalising" chip, keep last poses |
| Provider stopped | `dataProviderStateChanged` | Banner, one restart attempt, then manual bind |
| Marker never detected | 15 s timeout after register starts | Auto-offer the manual bind list |
| Marker moved mid-case | Image pose vs world anchor > 3 cm | Re-anchor silently, log |
| **Object tracking unsupported / no ref objects** | `isSupported`, empty load | **Tier 1 only. Never surfaced to the user.** |
| **Object lock lost** | `isTracked == false`, or >500 ms stale | Crossfade to Tier 1 "as packed" over 250 ms |
| Recogniser unavailable | `isAvailable == false` | Disable voice, show gaze-and-pinch item list |
| Mic interrupted | `AVAudioSession` interruption | Pause, auto-resume |
| Immersive space dismissed | Scene phase change | Pause providers, preserve state, resume on reopen |
| Thermal throttle | `ProcessInfo.thermalState` | Drop plane detection, reduce animation, halve object-tracking rate |

**Never crash on a missing tray or a missing lock.** Every lookup returns an optional; every optional has a defined UI for `nil`.

### Performance budget

90 fps = **11.1 ms/frame**. Missing it drops to a reprojection path, and the visible result is judder on world-locked content — exactly the content that has to look solid.

| Item | Budget |
|---|---|
| Highlight entities | ≤ 200, pooled, mostly disabled |
| Unique materials | ≤ 10 — material compilation is the hitch source |
| Per-frame allocations | **0** |
| ASR audio thread | ≤ 2 ms per buffer |
| Manifest lookup | O(1) — prebuild `[instrumentID: SlotRef]` at register |
| Loaded reference objects | ≤ 5 (verify the platform ceiling) |

**Thermals are real.** Four ARKit providers plus continuous ASR plus rendering is heavy sustained load, and object tracking is the most expensive of the four. A device warm from 40 minutes behaves differently from a cold one. **Rehearse warm.** Keep the battery tethered to power throughout.

---

## 18. Developing without a headset

The Simulator supports none of this. One device, three developers — **the mock layer is what makes the build parallel, so build it in hour one.**

```swift
final class MockPerceptionProvider: PerceptionProvider {
    // Places 3 trays in a fixed arrangement 1.2 m in front of the origin,
    // or replays a pose sequence recorded on device.
    // Debug injection: tracking loss · drift · tray moved ·
    //                  object lock acquired · object lock lost.
}

final class MockVoiceProvider: VoiceProvider {
    // Debug panel: one button per vocabulary term, plus
    // "inject near-miss" and "inject garbage" to exercise the
    // disambiguation and silent-miss paths.
}
```

**Record everything captured on device.** Pose sequences and audio become the fixtures the mocks replay, which multiplies the value of every minute anyone spends wearing the headset.

**Device time allocation:**

| Window | Owner | Purpose |
|---|---|---|
| 0–2 | Voice | Mic viability (§2.2) |
| 2–4 | Perception | Provider co-existence + thermals (§2.3) |
| 4–8 | Perception | Marker detection range, lighting, pose stability |
| 8–20 | Rotating, 2 h blocks | Integration checks |
| ~14–24 | Perception | Object tracking tuning once reference objects land |
| 24–36 | Perception + render | Highlight and crossfade tuning — inherently on-device |
| 36–48 | All | Integration and rehearsal, device fully committed |

---

## 19. Build order — 48 hours, 3 people

Roles: **P** = perception/spatial, **V** = voice/resolver, **C** = content + deck + demo driver.

| Hours | Who | Deliverable |
|---|---|---|
| **0–1** | **C** | **Capture 3 hero objects. Verify USDZ scale.** Nothing else starts first. |
| **1–2** | **C** | **Queue all three in Create ML. Training runs unattended for ~12 h.** |
| 0–2 | V | Mic viability test (§2.2) |
| 2–4 | P | Provider co-existence + thermals (§2.3) |
| 0–3 | All | Module protocols (§6) + mock layer (§18). **Never change the protocols after hour 3.** |
| 0–4 | C | 3 JSON manifests, alias table, markers printed, packet labels photographed |
| 4–12 | P | Marker → tray → world anchor promotion (§7.1); tray panels rendering |
| 4–12 | V | End to end: utterance → resolver → tray ID. Corpus of 100 recorded utterances by hour 4. |
| 4–10 | C | Tier 2 packet labels into the asset catalog and tracking |
| **12–22** | **All** | **Guidance system: far mode, near mode, crossfade (§14). This is the demo.** |
| ~14–24 | P | Tier 3 wire-up as reference objects land. Fusion + hysteresis (§10.6). |
| 22–28 | All | Marked-in-play, ghost slots, panel |
| 28–32 | All | Disambiguation card, silent-miss path, "not on the field", timeouts |
| **30–34** | **P** | **Manual bind fallback (§8). Non-negotiable. Do it before you think you need it.** |
| 34–38 | C | **Record the backup demo video.** Full successful run, edited, on the laptop. |
| 38–44 | All | Rehearse on actual stage lighting, twice, on a warm device |
| 44–48 | — | Slides, buffer, sleep |

**Cut list, in strict order:** peripheral chevron → marked-in-play → disambiguation card → Tier 3 object tracking → Tier 2 labels.

**Protect absolutely: register → ask → guide.** A flawless three-step loop beats six half-working features, every time, in front of every judge.

---

## 20. Demo script

Rehearse verbatim. Three minutes. **The person driving the demo should not be writing critical-path code after hour 36.**

**1. (20 s) The hook — from the deck.** Find the mosquito: easy slide, cluttered slide, real ortho tray. *"That last one isn't a puzzle. That's the job, forty times a case, in under two seconds, while gowned and facing the other way."*

**2. (25 s) Register.** Wearer looks at three trays. Panels bloom. *"The room is mapped once. The trays identify themselves in about twenty seconds. Hospitals already maintain these layouts — they're called count sheets. We're just putting them in the room."*

**3. (60 s) The moment. Do not talk over this.**
Teammate plays the surgeon, facing away, does not adjust their speech.
- **"Mosquito."** → Far mode. Tray B glows. Chevron. Callout.
- Wearer walks to the tray → **crossfade** → slot highlight, "as packed · row 3 · pos 1."
- **"Mallet."** → Tray A. Walk over. **Tier 3 outline snaps onto the actual mallet.**
- **Pick the mallet up and move it. The outline follows.** ← *This is the whole demo. Hold the beat. Say nothing.*

**4. (20 s) Consumables.** **"Two-oh Vicryl."** Packet outlines. Pick it up — outline stays on it in the hand. *"Instruments and consumables. The packet labels are the fiducials — they were already there."*

**5. (20 s) It knows when it doesn't know.** Say **"scissors."** Amber card, two candidates. *"When it isn't sure it says so. It never guesses — a wrong highlight costs trust permanently, a silent miss costs a second."*
Then say something not on the field. *"Not on the field — ask circulator."*

**6. (15 s) Marked in play.** Mark two passed, show ghost slots. *"She can see what left the table. This is not a count. It's awareness — and the wording in our UI says exactly that."*

**7. (20 s) Close.** *"Today, a rotating nurse takes months to learn one service line's trays. Expertise lives in one person's head and gets rebuilt from scratch every case. This is the room remembering, for everyone."*
Non-goals slide. Stop talking.

**Cardinal rules:**
- Whoever plays the surgeon **does not look at the trays** and **does not adjust their speech.** The illusion is that the system fits the theatre as it already is.
- **The move-the-object beat is your differentiator.** Everything else could be faked with a hardcoded map and a keyword listener, and a sharp judge knows it. That beat cannot be faked. Build toward it, rehearse it, and give it silence.

### Success criteria

- 3 trays registered in under 60 s, live
- 8 of 10 spoken requests resolve first try
- Under 500 ms from end of speech to guidance
- At least one live object lock, held while the object is moved
- Zero crashes across two full run-throughs

### Two artefacts worth an hour each

**The before/after clip.** A teammate who has never seen the tray, cold, told to find the mosquito — timed. Then with the headset — timed. Twenty seconds of video, and it is the only evidence in your entire deck that the thing actually reduces search time. **More persuasive than the live demo, and it is your insurance if the live run dies.**

**A judge wearing the headset.** If the format allows it at all, hand it over. Someone succeeding at your product beats anyone watching it.

---

## 21. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Object-tracking training not finished in time | **Critical** | Start hour 0. Three objects only. Tiers 1–2 are a complete demo without it. |
| Hero objects unsuitable (specular / thin / symmetric) | **Critical** | §10.3 suitability rules. Ortho or hardware-store proxies, never plushies or bottles. |
| Marker detection fails under stage lighting | High | Manual bind by hour 32. Large matte markers. Rehearse on site. |
| Mic beamforming defeats surgeon capture | Medium | Nurse-initiated is already primary. Ambient capture is a bonus, not the spine. |
| Thermal throttling on a warm device | Medium | Rehearse warm, tethered. Drop plane detection, halve object-tracking rate. |
| Anchor drift over a long case | Medium | §7.1 — markers are ground truth, world anchors are scaffold. |
| "Isn't this a count device?" | Medium | Non-goals slide, verbatim, before it is asked. |
| "Do experienced scrubs actually need this?" | Medium | **They largely don't. Say so.** The product is for new and rotating staff. §1 claim ladder. |

### Genuinely unsolved — raise these yourself before a judge does

- **Battery.** ~2 h against a 4 h case. No software fix. Tethered power or hot-swap is a hardware conversation. *Or: the circulator wears it and swaps.*
- **Sterility.** A headset worn inside the sterile field, untouchable once gloved, is an infection-control question this design does not answer. Hands-free Phases 4–5 are a mitigation, not a solution. *Or: the circulator wears it and the question disappears.*
- **Instrument-level truth.** Outside a Tier 3 lock, the system knows where things *should be* and what was *marked* — never what is actually there. Every UI string respects this (§1.1, §4 Phase 5).
- **Multi-user.** Single device, single map. Sharing needs a sync backend that does not exist here.
- **Evidence.** Your statistics are from literature, not from this system. You have measured nothing about *this* product except your own before/after clip. Say "we haven't validated this — here is the study we'd run" and name the endpoint: time-to-proficiency, novice cohort, conventional vs assisted.

None of these invalidate the PoC. All of them need answers before anyone goes near a patient. **A team that raises its own unsolved problems reads as senior. A team that gets caught reads as junior.**

### Roadmap

**Before surgery: train the person. During surgery: augment the person. After surgery: improve the system.** Your slide 15 is the right frame — keep it.

Concretely: reference objects for a full tray (offline, scales linearly) → multi-user sync between scrub and circulator → surgeon preference cards → instrument-utilisation analytics feeding tray rationalisation, which is where the sterile-processing cost argument lives → count reconciliation, which needs a real regulatory pathway, an IEC 62304 lifecycle, and is an entirely different company.

---

## Appendix A — Shopping and prep list

**Must have working before the clock starts**
- Apple Developer account with device provisioning verified — this eats hours if left to hour 0
- Xcode with the visionOS SDK, building a hello-world **to the device**, not the simulator
- Apple Silicon Mac with Create ML. Two if possible, for parallel training.
- iPhone Pro (LiDAR) for Object Capture

**Props — budget ~SGD 120**
- Orthopaedic-style instruments, or matte chunky hardware-store proxies: mallet, chunky wrench, cordless drill, socket set
- 2–3 stainless instrument trays
- Blue surgical wrap or drape
- Suture packets / blade packets for Tier 2 — real ones if anyone can source them, otherwise any densely-printed medical packaging
- Folding table at back-table height (~90 cm)
- Matte printing for markers + foamcore or clipboards for rigid mounting
- Tape measure or calipers — `markerFromTray` is a measurement, not a guess
- Grey or mid-tone matte cloth for object capture backgrounds

**People**
- **One scrub nurse or OR tech, thirty minutes, on the phone, before you start.** Get one quotable line for the deck. Ask what actually wastes their time. This is the cheapest credibility you will ever buy, and if your premise is wrong it is far better to learn it on Friday than on Sunday.

**Insurance**
- Manual bind mode by hour 32
- Recorded video of a full successful run, on the laptop, by hour 38
- 100-utterance recorded corpus by hour 4

---

## Appendix B — Verify against the SDK before building

Ordered by schedule burned if the assumption is wrong.

1. **Create ML object-tracking training time on your actual Mac** — run one object first and time it before committing to three. Hour 0.
2. **`ObjectTrackingProvider` availability, `isSupported`, and the reference-object count ceiling.** Hour 2.
3. **Can World + Image + Object + Plane providers run in one session simultaneously?** Hour 2.
4. **Whether `SpeechAnalyzer`/`SpeechTranscriber` exposes contextual biasing.** If not, `SFSpeechRecognizer`. Hour 3.
5. **`contextualStrings` effective ceiling** in your target release.
6. **Whether on-device ASR populates confidence.** If yes, add it as a fifth resolver signal. Never depend on it.
7. **`BillboardComponent` availability** and the current `RealityView` attachments API shape.
8. **`ReferenceImage` / `ReferenceObject` asset-group loading API shape** — the loader signature moves between releases.
9. **Marker detection range and angle limits** under bright direct lighting.
10. **World anchor persistence across full app termination**, not just backgrounding.
11. **Main camera / barcode entitlement status.** Assume gated. Confirm so you can answer it in one sentence.
