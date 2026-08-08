import Foundation

enum ManifestStore {

    /// Every manifest shipped in the bundle. Hand-authored JSON, read-only.
    /// SPEC §11 — do not build a slot editor.
    static func loadBundled(bundle: Bundle = .main) -> [TrayManifest] {
        // Depending on whether the build phase flattens Resources/ or copies it
        // as a folder reference, the JSON lands in one place or the other.
        // Check both rather than depending on a build setting nobody will
        // remember to preserve.
        let flat = bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        let nested = bundle.urls(forResourcesWithExtension: "json", subdirectory: "Manifests") ?? []
        return load(urls: Array(Set(flat + nested)))
    }

    static func load(urls: [URL]) -> [TrayManifest] {
        var out: [TrayManifest] = []
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                out.append(try JSONDecoder().decode(TrayManifest.self, from: data))
            } catch is DecodingError {
                // A JSON file in the bundle that is not a manifest is normal.
                // A malformed manifest is not — log loudly, never crash.
                Log.session.debug("Skipped non-manifest JSON: \(url.lastPathComponent)")
            } catch {
                Log.session.error("Unreadable \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return out.sorted { $0.trayID < $1.trayID }
    }

    /// Flatten manifests into the searchable candidate set the resolver wants.
    /// Instruments and consumables share one address space (§SlotRef) so the
    /// resolver never has to branch on kind.
    static func candidates(from manifests: [TrayManifest]) -> [Candidate] {
        manifests.flatMap { manifest -> [Candidate] in
            let instruments = manifest.slots.map { slot in
                Candidate(slot: .instrument(manifest.trayID, slot.index),
                          displayName: slot.displayName,
                          aliases: slot.aliases,
                          usagePhase: slot.usagePhase.flatMap(CasePhase.init(rawValue:)))
            }
            let consumables = manifest.consumables.enumerated().map { i, c in
                Candidate(slot: .consumable(manifest.trayID, i),
                          displayName: c.displayName,
                          aliases: c.aliases,
                          usagePhase: nil)
            }
            return instruments + consumables
        }
    }

    /// Human-readable label for any ref, for callouts and the debug panel.
    static func describe(_ ref: SlotRef, in manifests: [TrayManifest])
        -> (displayName: String, positionLabel: String, trayName: String)? {

        guard let m = manifests.first(where: { $0.trayID == ref.trayID }) else { return nil }

        if let ci = ref.consumableIndex {
            guard ci < m.consumables.count else { return nil }
            return (m.consumables[ci].displayName, "", m.displayName)
        }
        guard let slot = m.slots.first(where: { $0.index == ref.index }) else { return nil }
        return (slot.displayName, slot.label, m.displayName)
    }
}
