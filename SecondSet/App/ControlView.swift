import SwiftUI

/// Routes between the guided walkthrough and the case screen. There is no
/// third state and no bare settings panel — anything the wearer needs to
/// change is reachable from one of these two.
struct ControlView: View {

    let providers: ProviderSet
    @Environment(CaseSession.self) private var session

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
    }
}
