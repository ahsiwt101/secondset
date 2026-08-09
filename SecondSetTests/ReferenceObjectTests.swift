import Testing
import ARKit
import Foundation
@testable import SecondSet

// `ReferenceObject.init(from:)` does NOT fail safely on the visionOS
// Simulator — confirmed empirically, not documented anywhere: it hits a
// native `ar_reference_object_load_from_url failed` fatalError and takes the
// whole process down with it. `try?`/`try`/`catch` cannot intercept a
// fatalError; only a crash log can. That is a materially different failure
// mode from everything else in this codebase, which was built around every
// perception input degrading gracefully (SPEC §17) — this one specific call
// cannot be made to do that, on Simulator, no matter how it's wrapped.
//
// Practical upshot: these tests are useful ONLY on a real device, and this
// file is quarantined behind `ObjectTrackingProvider.isSupported` (false on
// Simulator, true on hardware) rather than actually attempting the load —
// so `xcodebuild test` on the Simulator now records a clean skip instead of
// crashing the whole test run, which is what happened before this guard was
// added: 27 tests reported "passed" while this suite silently took the test
// process down four times, once per @Test.
//
// The corollary matters more than the workaround: a malformed or
// incompatible .referenceobject bundled into a release build is a hard
// device crash on launch, not a degraded Tier 3. Test loading on the actual
// headset as soon as a fresh export exists — don't wait for demo day to find
// out a training run produced something ARKit refuses to open.
@Suite("Reference objects", .enabled(if: ObjectTrackingProvider.isSupported))
struct ReferenceObjectTests {

    static func bundledURLs() -> [URL] {
        Bundle.main.urls(forResourcesWithExtension: "referenceobject", subdirectory: nil) ?? []
    }

    @Test("At least one reference object is bundled")
    func atLeastOneBundled() {
        #expect(!Self.bundledURLs().isEmpty, "no .referenceobject files found in the app bundle")
    }

    /// The load-bearing check. `PerceptionEngine` maps a live `ObjectAnchor`
    /// back to a manifest slot purely by matching
    /// `referenceObject.name == slot.referenceObjectName`. If ARKit's
    /// runtime `.name` doesn't match what a manifest author would naturally
    /// write as an instrumentID, every object lock silently fails to map to
    /// anything and Tier 3 never activates — with no error, just permanent
    /// silent fallback to Tier 1. Run this on device and read the name from
    /// the test output; that string is what `referenceObjectName` in the
    /// manifest must equal, exactly.
    @Test("Reference object names, for manifest authoring")
    func printNames() async throws {
        for url in Self.bundledURLs() {
            let object = try await ReferenceObject(from: url)
            Issue.record(Comment(rawValue:
                "FILE: \(url.lastPathComponent)  RUNTIME NAME: \"\(object.name)\""))
        }
    }
}
