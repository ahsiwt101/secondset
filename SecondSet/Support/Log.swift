import Foundation
import OSLog

// One subsystem, one category per module. `log stream --predicate
// 'subsystem == "com.secondset.app"'` in Terminal gives a live feed off
// the headset, which is the only debugging you get inside an ImmersiveSpace.

enum Log {
    private static let subsystem = "com.secondset.app"

    static let perception = Logger(subsystem: subsystem, category: "perception")
    static let voice      = Logger(subsystem: subsystem, category: "voice")
    static let resolve    = Logger(subsystem: subsystem, category: "resolve")
    static let render     = Logger(subsystem: subsystem, category: "render")
    static let session    = Logger(subsystem: subsystem, category: "session")
}
