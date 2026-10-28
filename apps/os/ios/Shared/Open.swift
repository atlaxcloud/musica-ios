// Where Atlax can be opened at: one name per place, shared by the app (tabs,
// atlax://<section> links, icon quick actions), the widgets (widgetURL / Link)
// and the Control Center controls (OpenAtlaxIntent, compiled in both the app
// and the widget extension so the system runs it inside the app).
import AppIntents
import Foundation

enum AtlaxSection: String, AppEnum {
    case home, mail, chat, agenda, files, share, more, machines, settings, desktop, screen

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Sezione di Atlax"
    static var caseDisplayRepresentations: [AtlaxSection: DisplayRepresentation] = [
        .home: "Home",
        .mail: "Posta",
        .chat: "Agente",
        .agenda: "Calendario",
        .machines: "Macchine",
        .files: "File",
        .share: "Condividi file",
        .more: "Altro",
        .settings: "Impostazioni",
        .desktop: "Desktop",
        .screen: "Trasmetti schermo",
    ]

    var url: URL { URL(string: "atlax://\(rawValue)")! }
}

/// Set by the app at launch; in the extensions it stays a no-op.
enum AtlaxLinks {
    static var open: (AtlaxSection) -> Void = { _ in }
}

struct OpenAtlaxIntent: AppIntent {
    static var title: LocalizedStringResource = "Apri Atlax"
    static var description = IntentDescription("Apre Atlax su una sezione: posta, calendario, agente, file, schermo, desktop.")
    static var openAppWhenRun = true

    @Parameter(title: "Sezione")
    var section: AtlaxSection

    init() {}
    init(_ s: AtlaxSection) { section = s }

    @MainActor
    func perform() async throws -> some IntentResult {
        AtlaxLinks.open(section)
        return .result()
    }
}
