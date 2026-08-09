import SwiftUI

@main
struct SecondSetApp: App {

    @State private var session = CaseSession()
    @State private var providers = ProviderSet.forCurrentEnvironment()

    var body: some Scene {
        // 2D control surface: setup, tray list, marked-in-play, debug panel.
        WindowGroup {
            ControlView(providers: providers)
                .environment(session)
                // Bumped for pitch/demo legibility: this window gets mirrored
                // to a Mac for judges to watch, and body-sized text that's
                // perfectly readable worn on-device reads small once
                // AirPlay-mirrored and viewed from normal laptop distance.
                // One dynamicTypeSize scales every font AND the window
                // itself (.contentSize below fits to it), rather than
                // hand-tuning each .font() call individually.
                .dynamicTypeSize(.accessibility2)
                .task {
                    session.configure(perception: providers.perception,
                                      voice: providers.voice)
                    await session.prepare()
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 620, height: 780)

        // Everything world-locked. ARKit world-sensing providers only deliver
        // data while an ImmersiveSpace is open — a windowed-only app gets
        // nothing, which is a confusing hour to lose on day one. SPEC §5.
        ImmersiveSpace(id: "theatre") {
            TheatreView()
                .environment(session)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

/// Which pair of engines the app is wired to. The Simulator supports none of
/// the perception stack, so it is always mocked there — and the mock is
/// selectable on device too, because it is how the guidance UI gets iterated
/// on while someone else is wearing the headset. SPEC §18.
@Observable
final class ProviderSet {
    let perception: any PerceptionProvider
    let voice: any VoiceProvider
    let isMocked: Bool

    private init(perception: any PerceptionProvider, voice: any VoiceProvider, isMocked: Bool) {
        self.perception = perception
        self.voice = voice
        self.isMocked = isMocked
    }

    @MainActor
    static func forCurrentEnvironment() -> ProviderSet {
        #if targetEnvironment(simulator)
        return mocked()
        #else
        if ProcessInfo.processInfo.arguments.contains("-mock") { return mocked() }
        return ProviderSet(perception: PerceptionEngine(), voice: VoiceEngine(), isMocked: false)
        #endif
    }

    @MainActor
    static func mocked() -> ProviderSet {
        ProviderSet(perception: MockPerceptionProvider(), voice: MockVoiceProvider(), isMocked: true)
    }

    var mockPerception: MockPerceptionProvider? { perception as? MockPerceptionProvider }
    var mockVoice: MockVoiceProvider? { voice as? MockVoiceProvider }
}
