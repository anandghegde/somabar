import Foundation

/// One earlier state of the document, kept for one-click restore (M16).
public struct HistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public var date: Date
    public var reason: String
    public var document: SomabarDocument

    public var id: Date { date }

    public init(date: Date, reason: String, document: SomabarDocument) {
        self.date = date
        self.reason = reason
        self.document = document
    }
}

/// Reads and writes the `.somabar` file and its history.
///
/// Every save that changes the document first pushes the previous version into `history/`.
/// The newest 20 are kept.
public struct DocumentStore: Sendable {
    public static let historyLimit = 20
    public static let fileName = "layout.somabar"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/Somabar`, or `$SOMABAR_DOCUMENT_DIR` when set, so a test
    /// run can use its own layout file.
    public static func defaultDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["SOMABAR_DOCUMENT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Somabar", isDirectory: true)
    }

    public var documentURL: URL {
        directory.appendingPathComponent(Self.fileName)
    }

    public var historyDirectory: URL {
        directory.appendingPathComponent("history", isDirectory: true)
    }

    /// nil when no document has been saved yet.
    public func load() throws -> SomabarDocument? {
        guard FileManager.default.fileExists(atPath: documentURL.path) else { return nil }
        let data = try Data(contentsOf: documentURL)
        return try SomabarDocument.decode(data)
    }

    /// Writes atomically. When a different document was on disk, it is pushed into history.
    public func save(_ document: SomabarDocument, reason: String, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let previous = try? load(), previous != document {
            try push(previous, reason: reason, date: now)
        }
        try document.encoded().write(to: documentURL, options: .atomic)
    }

    /// Newest first.
    public func history() throws -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: historyDirectory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: historyDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [HistoryEntry] = []
        for url in urls {
            if let entry = try? decoder.decode(HistoryEntry.self, from: Data(contentsOf: url)) {
                entries.append(entry)
            }
        }
        return entries.sorted { $0.date > $1.date }
    }

    public func clearHistory() throws {
        if FileManager.default.fileExists(atPath: historyDirectory.path) {
            try FileManager.default.removeItem(at: historyDirectory)
        }
    }

    private func push(_ document: SomabarDocument, reason: String, date: Date) throws {
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let entry = HistoryEntry(date: date, reason: reason, document: document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entry).write(to: historyDirectory.appendingPathComponent(Self.fileName(for: date)), options: .atomic)
        try prune()
    }

    private func prune() throws {
        let entries = try history()
        guard entries.count > Self.historyLimit else { return }
        for entry in entries[Self.historyLimit...] {
            try? FileManager.default.removeItem(at: historyDirectory.appendingPathComponent(Self.fileName(for: entry.date)))
        }
    }

    /// Milliseconds since 1970, zero-padded so names sort in time order.
    static func fileName(for date: Date) -> String {
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        return String(format: "%015lld.json", millis)
    }
}
