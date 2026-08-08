import SwiftUI

/// The screen the scrub nurse actually lives in during a case.
///
/// Only ever shows one of four things: listening, a suggestion awaiting
/// confirmation, active guidance, or a browse list. Between requests it is
/// almost empty — SPEC §14, the interface budget here is close to zero.
struct OperatingView: View {

    @Environment(CaseSession.self) private var session
    let providers: ProviderSet

    @State private var showBrowse = false
    @State private var showDebug = false

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    if let pending = session.pending {
                        SuggestionCard(pending: pending)
                    } else if session.guidance.isGuiding {
                        GuidanceCard()
                    } else if case .notOnField(let name) = session.guidance {
                        notOnFieldCard(name)
                    } else {
                        idleCard
                    }

                    if !session.markedInPlay.isEmpty { markedInPlaySection }
                    if showBrowse { browseSection }
                    if showDebug, providers.isMocked { MockControls(providers: providers) }
                }
                .padding(20)
            }
        }
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.green)
                .frame(width: 9, height: 9)
                .opacity(session.pending == nil ? 1 : 0.35)
            Text("Listening")
                .font(.subheadline.weight(.medium))

            Text("·").foregroundStyle(.secondary)
            Text("\(session.boundTrays.count) trays")
                .font(.subheadline).foregroundStyle(.secondary)

            Spacer()

            Button { showBrowse.toggle() } label: {
                Label("Browse", systemImage: "list.bullet")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Menu {
                Button("Set up trays again") { session.flow = .setup(.registerTrays) }
                Picker("Phase", selection: Binding(
                    get: { session.phase }, set: { session.phase = $0 })) {
                    ForEach(CasePhase.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if providers.isMocked {
                    Toggle("Debug controls", isOn: $showDebug)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Cards

    private var idleCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .padding(.top, 22)
            Text("Say an instrument name")
                .font(.title3.weight(.medium))
            Text("It will appear here for you to accept.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 20))
    }

    private func notOnFieldCard(_ name: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 32)).foregroundStyle(.orange)
                .padding(.top, 20)
            Text(name).font(.title3.weight(.semibold))
            Text("Not on the field — ask the circulator.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Sections

    private var markedInPlaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Marked in play")
                .font(.headline)
            ForEach(session.markedInPlay, id: \.self) { ref in
                HStack {
                    Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                    Text(session.describe(ref)?.displayName ?? "—")
                    Spacer()
                    Button("Back") { session.markReturned(ref) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(12)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            }
            // SPEC §4 Phase 5 — this wording is what keeps a reference aid from
            // being mistaken for a count device.
            Text("Asserted by you, not observed by the system. This is not a count.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On the field").font(.headline)
            ForEach(session.browsableItems, id: \.ref) { item in
                Button {
                    session.confirmFind(item.ref)
                    showBrowse = false
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).foregroundStyle(.primary)
                            Text(item.tray).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "location").foregroundStyle(.tint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(12)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

// MARK: - Suggestion

/// The step the wearer asked for: a heard request, shown as an option, acted on
/// only when they say so.
private struct SuggestionCard: View {

    @Environment(CaseSession.self) private var session
    let pending: PendingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Heard \u{201C}\(pending.heard)\u{201D}", systemImage: "ear")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { session.dismissPending() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }

            if pending.isAmbiguous {
                Text("Which one?")
                    .font(.title3.weight(.semibold))
                ForEach(pending.options, id: \.self) { ref in
                    optionButton(ref, prominent: false)
                }
            } else if let ref = pending.single, let d = session.describe(ref) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(d.displayName)
                        .font(.title2.weight(.semibold))
                    Text(d.trayName)
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button {
                    session.confirmFind(ref)
                } label: {
                    Label("Find instrument", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(20)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 20))
    }

    private func optionButton(_ ref: SlotRef, prominent: Bool) -> some View {
        Button {
            session.confirmFind(ref)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.describe(ref)?.displayName ?? "—")
                    Text(session.describe(ref)?.trayName ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "location")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Active guidance

private struct GuidanceCard: View {

    @Environment(CaseSession.self) private var session

    var body: some View {
        let ref = session.guidance.activeSlot
        let described = ref.flatMap { session.describe($0) }

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: isNear ? "scope" : "location.fill")
                    .foregroundStyle(.tint)
                Text(isNear ? "At the tray" : "Head to the tray")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isConfirmed {
                    Label("Confirmed", systemImage: "eye.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(described?.displayName ?? "—")
                    .font(.title2.weight(.semibold))
                Text(described?.trayName ?? "")
                    .font(.callout).foregroundStyle(.secondary)
                if isNear, let label = described?.positionLabel, !label.isEmpty {
                    // The hedge lives in the string. Slot position is true at
                    // open and degrades as the case proceeds — SPEC §1.1.
                    Text(isConfirmed ? label : "as packed · \(label)")
                        .font(.callout)
                        .foregroundStyle(isConfirmed ? .primary : .secondary)
                }
            }

            HStack {
                Button {
                    if let ref { session.markPassed(ref) }
                } label: {
                    Label("Passed", systemImage: "hand.raised")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button("Done") { session.stopGuiding() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 20))
    }

    private var isNear: Bool {
        if case .guidingNear = session.guidance { return true }
        return false
    }

    private var isConfirmed: Bool {
        if case .guidingNear(_, let tier) = session.guidance { return tier == .confirmed }
        return false
    }
}

// MARK: - Debug (mock providers only)

private struct MockControls: View {

    let providers: ProviderSet
    @Environment(CaseSession.self) private var session
    @State private var distance: Float = 3.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Debug").font(.headline)

            Button("Register all trays") { providers.mockPerception?.registerAll() }
                .buttonStyle(.bordered)

            VStack(alignment: .leading) {
                Text("Simulated distance: \(distance, specifier: "%.1f") m").font(.caption)
                Slider(value: $distance, in: 0.3...5.0) { _ in
                    providers.mockPerception?.walk(to: distance)
                }
            }

            if let voice = providers.mockVoice {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 8) {
                    ForEach(voice.vocabulary.prefix(18), id: \.self) { term in
                        Button(term) { voice.say(term) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                HStack {
                    Button("Ambiguous") { voice.say("scissors") }
                    Button("Off field") { voice.say("iris") }
                    Button("Garbage") { voice.injectGarbage() }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }

            if let perception = providers.mockPerception {
                HStack {
                    Button("Lock on") {
                        if let ref = session.guidance.activeSlot,
                           let id = session.instrumentID(for: ref),
                           let pose = session.asPackedTransform(for: ref) {
                            perception.emitObjectLock(instrumentID: id,
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
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
    }
}
