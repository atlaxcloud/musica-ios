// The App Group every Atlax target shares (app, broadcast, share, files,
// widget, autofill): one UserDefaults suite and one container directory.
// The app writes the pairing and reads what the extensions drop; the
// extensions read the pairing and write status / inbox items.
import Foundation

enum Group {
    static let id = "group.cloud.atlax"
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }

    /// The shared container (falls back to this target's own Documents when the
    /// group is missing, e.g. a signer that dropped the entitlement).
    static var dir: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func sub(_ name: String) -> URL {
        let u = dir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var inbox: URL { sub("Inbox") } // Share extension -> app
    static var files: URL { sub("Files") } // File Provider domain root

    static var pairing: Pairing? {
        get { defaults.data(forKey: "pairing").flatMap { try? JSONDecoder().decode(Pairing.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "pairing") }
    }

    /// Broadcast extension status, shown by the app and the widget.
    static func setStatus(_ s: String) {
        defaults.set(s, forKey: "screen.status")
        defaults.set(Date().timeIntervalSince1970, forKey: "screen.at")
    }
    static var status: String { defaults.string(forKey: "screen.status") ?? "idle" }
}
