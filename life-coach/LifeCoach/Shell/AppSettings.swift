import Foundation

/// Cross-cutting Sapiod settings, persisted to `app.json` via `FileStore`.
///
/// Phase 0 establishes the pattern with a single `schemaVersion` field. Coach
/// state intentionally stays in `lifecoach-state.json`; nothing is migrated here.
struct AppSettings: Codable {
    var schemaVersion: Int = 1

    init() {}
}

/// Loads/saves `AppSettings` and publishes it for the shell.
@MainActor
final class AppSettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { store.save(settings) }
    }

    private let store = FileStore<AppSettings>(filename: "app.json")

    init() {
        settings = FileStore<AppSettings>(filename: "app.json").load(default: AppSettings())
    }
}
