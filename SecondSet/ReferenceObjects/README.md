# Reference objects go here

Drop a trained `.referenceobject` file directly in this folder. Xcode's
`referenceobjectc` build tool picks it up automatically — no project file
edit needed, `xcodegen generate` is enough.

`.referenceobject` files are gitignored (see root `.gitignore`) — they're
multi-MB trained artifacts regenerable from the USDZ + Create ML project, not
source. Each teammate keeps their own local copy.

**Before dropping one in:**

1. Confirm the source USDZ was rescaled to the object's true physical size
   with `Tools/rescale-usdz.sh` before training. Object tracking matches on
   real-world dimensions — a model trained on an unscaled capture will not
   detect the real object, and this exact mistake already cost one full
   training run on the Panadol proxy (trained at 18.7 × 43.8 × 15.8 cm
   against a real box a fraction of that size).
2. Name the reference object to match the `instrumentID` it represents in the
   manifest, as closely as Create ML's naming allows — `PerceptionEngine`
   maps a live lock back to a slot by exact string match against
   `referenceObjectName`.
3. **Test loading on a real device immediately after export, before it ships
   in any build others run.** `ReferenceObject.init(from:)` does not fail
   safely — a malformed or version-incompatible file hits a native
   `fatalError` that crashes the whole app on launch, not a catchable Swift
   error. This cannot be coded around; it can only be caught early. See the
   comment on `PerceptionEngine.loadReferenceObjects()` for the full story,
   and `SecondSetTests/ReferenceObjectTests.swift` — run those tests on
   device (they skip on Simulator, which crashes on this API too) to read
   back the exact runtime name to put in the manifest.
