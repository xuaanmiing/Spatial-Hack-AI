import Foundation

/// Persists finished `SessionReport` records to a JSON file inside the app's
/// Documents directory so the report view can render a longitudinal trend.
///
/// The store is intentionally minimal: append-only writes, capped to the last
/// `maxRetainedSessions` entries so the file never grows unbounded.
@MainActor
final class SessionHistory {

    static let shared = SessionHistory()

    /// Maximum number of most-recent sessions to keep on disk.
    private let maxRetainedSessions = 20

    /// In-memory cache of the stored sessions (most-recent last).
    private(set) var sessions: [SessionReport] = []

    private let fileName = "session-history.json"

    init() {
        load()
    }

    // MARK: - Public API

    /// Appends a finished session and trims the history to `maxRetainedSessions`.
    func append(_ session: SessionReport) {
        // Guard against duplicate ids (e.g. accidental double-submit).
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
        } else {
            sessions.append(session)
        }
        if sessions.count > maxRetainedSessions {
            sessions.removeFirst(sessions.count - maxRetainedSessions)
        }
        save()
    }

    /// Returns the last N sessions in chronological order (oldest first).
    func recent(_ n: Int = 10) -> [SessionReport] {
        Array(sessions.suffix(n))
    }

    /// Removes every persisted session (used only from debug menus).
    func clearAll() {
        sessions.removeAll()
        save()
    }

    // MARK: - Persistence

    private var fileURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(fileName)
    }

    private func load() {
        guard let url = fileURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sessions = try decoder.decode([SessionReport].self, from: data)
        } catch {
            // Corrupt or schema-mismatched file — start fresh but don't crash.
            sessions = []
        }
    }

    private func save() {
        guard let url = fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(sessions)
            try data.write(to: url, options: .atomic)
        } catch {
            // Silently ignore — persistence is best-effort for the demo.
        }
    }
}
