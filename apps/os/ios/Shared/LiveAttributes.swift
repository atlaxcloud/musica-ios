// Live Activities (Dynamic Island + Lock Screen): the three things worth a
// glance while they happen. The app starts and updates them (no APNs on the
// free profile: updates come from the app in foreground or from its background
// time); the widget extension draws them (Widget/LiveViews.swift).
#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// The agent writing an answer: phase + the tail of the text as it streams.
@available(iOS 16.2, *)
struct LiveAgent: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "thinking" | "writing" | "done" | "failed"
        var phase: String
        var preview: String
        var chars: Int
    }
    var title: String
    var chat: String
}

/// The screen going to an Atlax receiver.
@available(iOS 16.2, *)
struct LiveScreen: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var live: Bool
        var target: String
    }
    var started: Date
}

/// The next agenda event, with a countdown to its start.
@available(iOS 16.2, *)
struct LiveEvent: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var start: Date
        var end: Date
        var location: String
    }
    var id: String
    var title: String
}
#endif
