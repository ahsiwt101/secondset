import Foundation

/// What the wearer is doing right now. The app has exactly two modes and one
/// of them is a guided setup — there is no state in which the user is expected
/// to already know what to press.
enum AppFlow: Equatable {
    case setup(SetupStep)
    case operating

    var isSetup: Bool { if case .setup = self { return true }; return false }
}

enum SetupStep: Int, CaseIterable, Equatable {
    case welcome        // what this is, in two sentences
    case enableSensing  // opens the immersive space, triggers all permissions
    case registerTrays  // marker scan, or place by hand
    case ready          // confirm and begin

    var title: String {
        switch self {
        case .welcome:       return "Second Set"
        case .enableSensing: return "Let it see the room"
        case .registerTrays: return "Find your trays"
        case .ready:         return "Ready"
        }
    }

    var stepLabel: String { "Step \(rawValue + 1) of \(SetupStep.allCases.count)" }

    var next: SetupStep? { SetupStep(rawValue: rawValue + 1) }
    var previous: SetupStep? { SetupStep(rawValue: rawValue - 1) }
}

/// An instrument request that has been heard and resolved, but **not yet acted
/// on**. The wearer confirms before anything is highlighted.
///
/// This deliberately sits between recognition and guidance. Firing a highlight
/// the instant the recogniser is confident means every stray phrase that
/// happens to match yanks the display around mid-procedure; a request that
/// waits to be accepted is something the wearer stays in charge of.
struct PendingRequest: Equatable {
    let heard: String
    /// One entry when resolved cleanly, two or three when ambiguous.
    let options: [SlotRef]
    let raisedAt: Date

    var isAmbiguous: Bool { options.count > 1 }
    var single: SlotRef? { options.count == 1 ? options[0] : nil }
}
