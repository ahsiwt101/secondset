import SwiftUI

/// The guided walkthrough. Every prerequisite the app has — permissions, the
/// immersive space, at least one bound tray — is satisfied by walking forward
/// through this. Nothing is assumed to be already known.
struct SetupView: View {

    @Environment(CaseSession.self) private var session
    @Environment(\.openImmersiveSpace) private var openImmersive

    let providers: ProviderSet
    let step: SetupStep

    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { content.padding(28) }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(spacing: 6) {
            Text(step.stepLabel)
                .font(.caption).foregroundStyle(.secondary)
            Text(step.title)
                .font(.largeTitle.weight(.semibold))
            ProgressView(value: Double(step.rawValue + 1),
                         total: Double(SetupStep.allCases.count))
                .frame(maxWidth: 260)
                .padding(.top, 4)
        }
        .padding(.vertical, 22)
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if let previous = step.previous {
                Button("Back") { session.flow = .setup(previous) }
                    .buttonStyle(.bordered)
            }
            Spacer()
            primaryButton
        }
        .padding(20)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .welcome:
            Button("Get started") { session.flow = .setup(.enableSensing) }
                .buttonStyle(.borderedProminent)

        case .enableSensing:
            Button(busy ? "Starting…" : "Enable and continue") { Task { await enableSensing() } }
                .buttonStyle(.borderedProminent)
                .disabled(busy)

        case .registerTrays:
            Button("Continue") { session.flow = .setup(.ready) }
                .buttonStyle(.borderedProminent)
                .disabled(session.boundTrays.isEmpty)

        case .ready:
            Button("Start case") { session.flow = .operating }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:       welcomeStep
        case .enableSensing: enableStep
        case .registerTrays: trayStep
        case .ready:         readyStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("When the surgeon asks for an instrument, Second Set shows you where it is.")
                .font(.title3)

            explainer(icon: "ear", title: "It listens",
                      body: "Instrument names spoken nearby appear here as a suggestion. Nothing is recorded.")
            explainer(icon: "hand.tap", title: "You decide",
                      body: "Tap Find instrument. It never highlights anything on its own.")
            explainer(icon: "sparkles", title: "It points",
                      body: "The right tray glows. Walk over, and the exact position lights up.")

            Label("Not a count. Not a medical device. A reference aid.",
                  systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    private var enableStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Second Set needs to see the room and hear instrument names.")
                .font(.title3)

            explainer(icon: "cube.transparent", title: "Room sensing",
                      body: "To know where your trays are and keep them in place as you move.")
            explainer(icon: "mic", title: "Microphone and speech",
                      body: "Recognised entirely on this device against a fixed list of instruments. Audio is never stored.")

            Text("You will see system permission prompts. All three are required.")
                .font(.footnote).foregroundStyle(.secondary)

            if let error = session.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
        }
    }

    private var trayStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Look at the printed marker on each tray. It will tick itself off.")
                .font(.title3)

            Text("No markers? Stand in front of a tray and tap **Place here** instead.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach(session.boundTrays) { tray in
                    trayRow(tray.displayName,
                            detail: "\(tray.manifest.slots.count) instruments",
                            bound: true, action: nil)
                }
                ForEach(session.unboundTrays) { tray in
                    trayRow(tray.displayName,
                            detail: "\(tray.manifest.slots.count) instruments",
                            bound: false) { session.bindManually(trayID: tray.id) }
                }
            }

            if session.boundTrays.isEmpty {
                Label("At least one tray is needed to continue.",
                      systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Label("\(session.boundTrays.count) ready. Add more, or continue.",
                      systemImage: "checkmark.circle")
                    .font(.footnote).foregroundStyle(.green)
            }
        }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("\(session.boundTrays.count) tray\(session.boundTrays.count == 1 ? "" : "s") on the field, \(instrumentCount) instruments.")
                .font(.title3)

            explainer(icon: "waveform", title: "Say an instrument name",
                      body: "\"Mosquito.\" \"Mallet.\" It appears as a suggestion you can accept.")
            explainer(icon: "list.bullet", title: "Or browse",
                      body: "Every instrument on the field is one tap away if you would rather not speak.")
            explainer(icon: "gearshape", title: "Change anything later",
                      body: "Setup is always reachable from the case screen.")
        }
    }

    private var instrumentCount: Int {
        session.boundTrays.reduce(0) { $0 + $1.manifest.slots.count }
    }

    // MARK: - Pieces

    private func explainer(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 34)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(body).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func trayRow(_ name: String,
                         detail: String,
                         bound: Bool,
                         action: (() -> Void)?) -> some View {
        HStack {
            Image(systemName: bound ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(bound ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let action {
                Button("Place here", action: action).buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Actions

    /// Opening the immersive space is what actually starts ARKit, so the
    /// permission prompts and the spatial session come up together rather than
    /// leaving the wearer to discover a toggle.
    private func enableSensing() async {
        busy = true
        defer { busy = false }

        if case .opened = await openImmersive(id: "theatre") {
            // Give the providers a beat to come up and any markers already in
            // view a chance to bind before we show an empty tray list.
            try? await Task.sleep(for: .milliseconds(900))
            session.flow = .setup(.registerTrays)
        } else {
            session.reportError("Could not open the spatial view. Close other immersive apps and try again.")
        }
    }
}
