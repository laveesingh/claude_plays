import Foundation

/// Generic per-feature persistence helper. Reads/writes a `Codable` value to a
/// named JSON file in the app's Documents directory using an atomic write, and
/// tolerates a missing or corrupt file by returning a supplied default.
///
/// This is the persistence pattern future Sapiod features adopt. It is
/// deliberately separate from the coach's `AppStore`/`lifecoach-state.json`,
/// which stays untouched.
struct FileStore<T: Codable> {
    let filename: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(filename: String,
         encoder: JSONEncoder = FileStore.makeEncoder(),
         decoder: JSONDecoder = JSONDecoder()) {
        self.filename = filename
        self.encoder = encoder
        self.decoder = decoder
    }

    private var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(filename)
    }

    /// Returns the decoded value, or `fallback` if the file is missing or corrupt.
    func load(default fallback: T) -> T {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode(T.self, from: data) else {
            return fallback
        }
        return decoded
    }

    /// Atomically writes the value. Silently no-ops on encode/write failure to
    /// match the coach store's best-effort persistence semantics.
    func save(_ value: T) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
