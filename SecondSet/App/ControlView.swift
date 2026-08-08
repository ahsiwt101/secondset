import SwiftUI

/// Routes between the guided walkthrough and the case screen. There is no
/// third state and no bare settings panel — anything the wearer needs to
/// change is reachable from one of these two.
struct ControlView: View {

    let providers: ProviderSet
    @Environment(CaseSession.self) private var session
    @Environment(\.openImmersiveSpace) private var openImmersive

    var body: some View {
        Group {
            switch session.flow {
            case .setup(let step):
                SetupView(providers: providers, step: step)
            case .operating:
                OperatingView(providers: providers)
            }
        }
        .animation(.snappy(duration: 0.25), value: session.flow)
        .onAppear { startAutoDemoIfRequested() }
    }

    /// `-autodemo` skips setup, registers the mock trays and fires a request.
    /// Purely a development affordance: iterating on the beam and halo means
    /// getting to a guided state dozens of times, and clicking through setup
    /// each time is how you stop bothering to check. Mock providers only.
    ///
    /// Deliberately NOT a `.task` modifier. The sequence sets
    /// `session.flow = .operating` partway through, which swaps the `switch`
    /// branch this view renders from `SetupView` to `OperatingView` — SwiftUI
    /// then rebuilds the owning view, and a `.task`-attached child is
    /// cancelled the instant its own view identity changes. The Task was
    /// cancelling itself the moment it did its job. A plain detached Task
    /// started from `onAppear`, guarded so it only fires once, has no such
    /// lifecycle tie and runs to completion regardless of what `body` does.
    @State private var autoDemoStarted = false

    private func startAutoDemoIfRequested() {
        guard providers.isMocked,
              ProcessInfo.processInfo.arguments.contains("-autodemo"),
              !autoDemoStarted else { return }
        autoDemoStarted = true
        Task { await runAutoDemo() }
    }

    private func runAutoDemo() async {
        guard providers.isMocked,
              ProcessInfo.processInfo.arguments.contains("-autodemo") else { return }

        Log.session.info("autodemo: opening immersive space")
        let result = await openImmersive(id: "theatre")
        Log.session.info("autodemo: openImmersiveSpace returned \(String(describing: result))")
        try? await Task.sleep(for: .milliseconds(700))

        providers.mockPerception?.registerAll()
        session.flow = .operating
        Log.session.info("autodemo: registered trays, flow=operating")
        try? await Task.sleep(for: .milliseconds(500))

        providers.mockVoice?.say("mosquito")
        try? await Task.sleep(for: .milliseconds(300))
        session.confirmFind()
        Log.session.info("autodemo: confirmed find, guidance=\(String(describing: session.guidance))")

        try? await Task.sleep(for: .seconds(4))
        providers.mockPerception?.walk(to: 0.8)
        Log.session.info("autodemo: walked in, guidance=\(String(describing: session.guidance))")
        try? await Task.sleep(for: .milliseconds(400))
        if let ref = session.guidance.activeSlot,
           let pose = session.resolvedPose(for: ref) {
            providers.mockPerception?.look(at: pose.transform.translation)
            session.pinGuidanceForDebugging()
            Log.session.info("autodemo: looked at \(String(describing: pose.transform.translation))")
        } else {
            Log.session.error("autodemo: no active slot to look at, guidance=\(String(describing: session.guidance))")
        }
        Log.session.info("autodemo: sequence complete, final guidance=\(String(describing: session.guidance))")
    }
}
