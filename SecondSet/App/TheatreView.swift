import SwiftUI
import RealityKit

struct TheatreView: View {

    @Environment(CaseSession.self) private var session

    var body: some View {
        RealityView { content in
            content.add(session.rootEntity)
        } update: { _ in
            // Deliberately empty. Everything world-locked is driven by the
            // renderer mutating pooled entities directly; doing work here runs
            // it on every SwiftUI invalidation, which is the wrong cadence and
            // the easiest way to lose the 11.1 ms frame budget. SPEC §17.
        }
        .task {
            await session.startEngines()
        }
        // Pinch anywhere to ask. Deterministic, works in noise, and needs no
        // wake word — the primary trigger. SPEC §12.1.
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { _ in session.beginListening() }
        )
        .onDisappear {
            Task { await session.stop() }
        }
    }
}
