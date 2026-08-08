# Second Set

Spatial instrument memory for the operating theatre. Apple Vision Pro, visionOS 26+.

Built against **Xcode 27 / visionOS 27 SDK**. Builds clean, 27 tests passing.
The full product spec lives in `~/Downloads/secondset-SPEC.md`.

---

## Quick start

Xcode beta is in `~/Downloads` and is not the selected toolchain. Two options:

**Option A — make it the default** (needs your password, so run it yourself):

```bash
sudo mv ~/Downloads/Xcode-beta.app /Applications/ && sudo xcode-select -s /Applications/Xcode-beta.app
```

**Option B — leave it where it is** and prefix commands:

```bash
export DEVELOPER_DIR=~/Downloads/Xcode-beta.app/Contents/Developer
```

Then:

```bash
xcodegen generate && open SecondSet.xcodeproj
```

`SecondSet.xcodeproj` is **generated** — do not edit it, and do not commit it.
Change `project.yml` and re-run `xcodegen generate`. Three people, one project
file, no merge conflicts.

Run tests:

```bash
xcodebuild test -project SecondSet.xcodeproj -scheme SecondSet -destination 'platform=visionOS Simulator,name=Apple Vision Pro'
```

---

## Running it

The Simulator supports **none** of the perception stack — no world tracking, no
image tracking, no object tracking, no planes, no mic. So:

- **On Simulator** → mock providers, automatically. Everything except real
  perception works: resolver, guidance state machine, far/near crossfade,
  marked-in-play, rendering.
- **On device** → real engines. Pass `-mock` as a launch argument to force mocks
  on device too, which is how you iterate on guidance UI while someone else is
  wearing the headset.

Open the app, flip **Theatre view** on (ARKit delivers nothing without an open
ImmersiveSpace), then use the **Debug** section: register all trays, drag the
distance slider across 1.5 m to watch the crossfade, tap a vocabulary term to
fire a request.

---

## Layout

```
SecondSet/
  App/          SecondSetApp · ControlView (+ debug panel) · TheatreView
  Domain/       CaseSession — single source of truth, @MainActor
                Models · Manifest · ManifestStore
  Resolve/      Resolver · Phonetics — pure logic, fully unit tested
  Perception/   PerceptionProvider (protocol) · PerceptionEngine (ARKit)
                MockPerceptionProvider · AnchorStore
  Voice/        VoiceProvider (protocol) · VoiceEngine (Speech)
                MockVoiceProvider
  Render/       GuidanceRenderer — pooled entities · Palette
  Support/      Math (simd extensions) · Log
  Resources/    4 tray manifests (JSON)
  Assets.xcassets/Markers.arresourcegroup/   4 printable markers @ 15 cm
Tools/
  GenerateMarkers.swift   regenerates the markers, deterministically
Markers/                  print these
```

**The protocol boundary is the whole point.** `PerceptionProvider` and
`VoiceProvider` were defined first and must not change — they are what let three
people work against one headset. Everything above them is testable on a Mac.

---

## The three perception tiers

| Tier | Mechanism | Training cost | Status |
|---|---|---|---|
| 3 · object | `ObjectTrackingProvider` + `.referenceobject` | hours each | wired, waiting on your Create ML runs |
| 2 · label | `ImageTrackingProvider` on printed packet labels | none | wired, needs label photos |
| 1 · geometry | marker → `WorldAnchor` → manifest slot | none | done |

Tier 1 always renders. The upper tiers override it when they have a live lock,
with hysteresis in both directions. If Tier 3 never lands, the demo still runs.

---

## Adding a trained reference object

There is **no asset-group loader** for reference objects — the app scans the
bundle for `*.referenceobject` at launch. So:

1. Train in Create ML (**Spatial → Object Tracking**), name it **exactly** the
   `instrumentID` from the manifest.
2. Drag the `.referenceobject` into the Xcode project, target SecondSet.
3. Set `referenceObjectName` on that slot in the manifest to the same string.
4. Run. No code change.

A test enforces `referenceObjectName == instrumentID`, so a mismatch fails the
build rather than silently never tracking.

Object suitability, before you spend hours training: **rigid, opaque, matte,
asymmetric, chunky.** Not deformable, not specular, not rotationally symmetric,
not thin. See SPEC §10.3.

---

## Markers

Four are generated and ready in `Markers/`. To regenerate:

```bash
swift Tools/GenerateMarkers.swift Markers/
```

Deterministic — a reprint is byte-identical to what is in the bundle. Multi-scale
blob structure (pixel noise does not survive printing), ~45% ink coverage,
asymmetric corner wedge so a tray can never bind rotated.

**Print at exactly 15 × 15 cm, matte, "actual size" not "fit to page".** Mount
flat on rigid backing, never on sterile wrap. The declared physical size in the
asset catalog is `0.15` and must match reality — wrong size means wrong depth,
and the highlight floats.

---

## Manifests

Hand-authored JSON in `Resources/Manifests`. Slot coordinates are normalised
`u,v` over the tray interior, so a layout can be read off an overhead photograph
with no metric measurement. About five minutes per tray.

`DEMO-01.json` is bench scaffolding for the household proxies — **delete it
before the demo.**

The one thing you must measure with a tape is `trayOriginInMarkerSpace`. Get it
wrong and every highlight on that tray shifts by a constant offset — which is
also the easiest bug in the build to spot.

Content tests enforce: normalised coordinates, unique indices, no *undeclared*
alias collisions, and that at least one deliberately ambiguous term exists (the
demo depends on saying "scissors" and getting the disambiguation card).

**Do not build a slot editor.** It is the most seductive way to lose a day.

---

## What is not built yet

- **Peripheral chevron** — first on the cut list, deliberately skipped.
- **Callout via RealityView attachments** — currently `MeshResource.generateText`,
  which is guaranteed to compile but plain. Upgrade to a SwiftUI attachment once
  verified on device.
- **Tier 2 label images** — mechanism is wired; needs photos of real packet
  labels added to the `Markers` asset group.
- **Surface classification** is a crude heuristic. Display only; the render path
  never depends on it, so a wrong guess costs a caption.

## Verified on the real SDK

Checked against XROS 27, not assumed:

- `ReferenceImage.loadReferenceImages(inGroupNamed:bundle:)` — as specced ✓
- `ReferenceObject` — **spec was wrong**: no group loader, loads per-URL, and
  `Configuration` (visionOS 27) gates `highFrameRateTrackingEnabled`, which is
  enabled here because the demo beat is picking an instrument up and moving it
- `ObjectTrackingProvider(referenceObjects:trackingConfiguration:)`
- `ObjectAnchor.boundingBox.extent`
- Swift 6 strict concurrency, zero warnings

Still unverified — needs the headset:

- Whether four providers co-exist in one session, and thermals over 20 min
- Mic viability for a non-wearer talker at 2 m
- Marker detection range and angle under bright direct lighting
- World anchor persistence across full app termination
