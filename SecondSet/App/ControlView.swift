import SwiftUI

struct ControlView: View {

    let providers: ProviderSet
    @Environment(CaseSession.self) private var session
    @Environment(\.openImmersiveSpace) private var openImmersive
    @Environment(\.dismissImmersiveSpace) private var dismissImmersive

    @State private var immersiveOpen = false

    var body: some View {
        @Bindable var session = session

        NavigationStack {
            List {
                statusSection
                caseSection(session: $session)
                traySection
                markedSection
                if providers.isMocked { DebugPanel(providers: providers) }
            }
            .navigationTitle("Second Set")
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            LabeledContent("Perception", value: session.health.summary)
            if providers.isMocked {
                Label("Mock providers — no real tracking", systemImage: "ladybug")
                    .foregroundStyle(.orange)
            }
            if let error = session.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Toggle("Theatre view", isOn: Binding(
                get: { immersiveOpen },
                set: { wanted in
                    Task {
                        if wanted {
                            if case .opened = await openImmersive(id: "theatre") { immersiveOpen = true }
                        } else {
                            await dismissImmersive()
                            immersiveOpen = false
                        }
                    }
                }))
        } header: {
            Text("Status")
        } footer: {
            Text("ARKit only delivers world-sensing data while the theatre view is open.")
        }
    }

    // MARK: - Case

    private func caseSection(session: Bindable<CaseSession>) -> some View {
        Section("Case") {
            Picker("Phase", selection: session.phase) {
                ForEach(CasePhase.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            Button {
                self.session.beginListening()
            } label: {
                Label("Find instrument", systemImage: "waveform")
            }
            .disabled(self.session.boundTrays.isEmpty)

            if !self.session.lastHeard.isEmpty {
                LabeledContent("Heard", value: self.session.lastHeard)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Trays

    private var traySection: some View {
        Section {
            ForEach(session.boundTrays) { tray in
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text(tray.displayName)
                        Text("\(tray.manifest.slots.count) items · \(tray.surface.displayName)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if tray.boundManually {
                        Text("manual").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(session.unboundTrays) { tray in
                HStack {
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                    Text(tray.displayName)
                    Spacer()
                    Button("Bind") { session.bindManually(trayID: tray.id) }
                        .buttonStyle(.bordered)
                }
            }
        } header: {
            Text("Trays")
        } footer: {
            // SPEC §8. Ten seconds of work that turns a total demo failure
            // into a minor one.
            Text("Bind places the tray a metre ahead at table height. Use it when a marker will not detect.")
        }
    }

    // MARK: - Marked in play

    private var markedSection: some View {
        Section {
            if session.markedInPlay.isEmpty {
                Text("Nothing marked").foregroundStyle(.secondary)
            }
            ForEach(session.markedInPlay, id: \.self) { ref in
                HStack {
                    Text(session.describe(ref)?.displayName ?? "—")
                    Spacer()
                    Button("Back") { session.markReturned(ref) }
                        .buttonStyle(.bordered)
                }
            }
        } header: {
            Text("Marked in play")
        } footer: {
            // SPEC §4 Phase 5. This wording is load-bearing: without full CV
            // this state is asserted by the nurse and never observed by the
            // system, and it is what keeps a reference aid from being mistaken
            // for a count device.
            Text("Asserted by the wearer, not observed by the system. This is not a count.")
        }
    }
}

// MARK: - Debug panel (SPEC §18)

private struct DebugPanel: View {

    let providers: ProviderSet
    @Environment(CaseSession.self) private var session
    @State private var distance: Float = 3.0

    var body: some View {
        Section {
            Button("Register all trays") { providers.mockPerception?.registerAll() }

            VStack(alignment: .leading) {
                Text("Simulated distance: \(distance, specifier: "%.1f") m")
                    .font(.caption)
                Slider(value: $distance, in: 0.3...5.0) { _ in
                    providers.mockPerception?.walk(to: distance)
                }
            }

            if let voice = providers.mockVoice {
                Text("Say").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 8) {
                    ForEach(voice.vocabulary.prefix(24), id: \.self) { term in
                        Button(term) { voice.say(term) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                HStack {
                    Button("Ambiguous") { voice.say("scissors") }
                    Button("Off field") { voice.say("iris") }
                    Button("Garbage") { voice.injectGarbage() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let perception = providers.mockPerception,
               let first = session.boundTrays.first {
                HStack {
                    Button("Tray moved") { perception.injectTrayMoved(trayID: first.id) }
                    Button("Lock on") {
                        if let ref = session.guidance.activeSlot,
                           let id = session.instrumentID(for: ref),
                           let pose = session.asPackedTransform(for: ref) {
                            // Offset so a confirmed lock is visibly distinct
                            // from the as-packed quad — if they render in the
                            // same place you cannot tell the tiers apart.
                            perception.emitObjectLock(
                                instrumentID: id,
                                at: pose.translation + SIMD3(0.04, 0.02, 0.03))
                        }
                    }
                    Button("Lock lost") {
                        if let ref = session.guidance.activeSlot,
                           let id = session.instrumentID(for: ref) {
                            perception.injectLockLoss(instrumentID: id)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } header: {
            Text("Debug")
        } footer: {
            Text("Exercises the paths that are impossible to trigger on demand with real hardware.")
        }
    }
}
