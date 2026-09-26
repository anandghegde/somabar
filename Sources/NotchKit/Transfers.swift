import Foundation

// MARK: - Which files count

/// How a browser marks a download that is still in progress.
public enum TransferMarker: String, Equatable, Sendable {
    /// Safari: a `name.ext.download` bundle with an Info.plist that holds the progress.
    case safari
    /// Chrome, Edge, Brave, Arc, Vivaldi: `name.ext.crdownload`.
    case chromium
    /// Firefox: `name.ext.part`, beside an empty `name.ext` placeholder.
    case firefox
    /// Opera: `name.ext.opdownload`.
    case opera

    /// The extension each browser adds while downloading.
    public var fileExtension: String {
        switch self {
        case .safari: "download"
        case .chromium: "crdownload"
        case .firefox: "part"
        case .opera: "opdownload"
        }
    }
}

/// Which files in Downloads are transfers, and what they will be called. Pure.
public enum TransferFiles {
    /// The marker a file name carries, nil for any other file.
    public static func marker(forFileName name: String) -> TransferMarker? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...].lowercased()
        return [TransferMarker.safari, .chromium, .firefox, .opera].first { $0.fileExtension == ext }
    }

    /// The name the file gets when it is done: "report.pdf.download" is "report.pdf". Nil for a
    /// file without a marker, and for Chrome's "Unconfirmed 123.crdownload", which is renamed
    /// before it finishes.
    public static func finalName(forFileName name: String) -> String? {
        guard let marker = marker(forFileName: name) else { return nil }
        let base = String(name.dropLast(marker.fileExtension.count + 1))
        guard !base.isEmpty else { return nil }
        if marker == .chromium, base.hasPrefix("Unconfirmed ") { return nil }
        return base
    }

    /// Files that are never transfers: hidden files and Finder's bookkeeping.
    public static func isIgnored(fileName name: String) -> Bool {
        name.hasPrefix(".") || name == "Icon\r"
    }
}

// MARK: - Observations

/// One file in Downloads as the watcher saw it.
public struct TransferSample: Equatable, Sendable {
    /// The file's name in Downloads; stable while it downloads.
    public var id: String
    public var marker: TransferMarker?
    /// Some app publishes an `NSProgress` for this file.
    public var isPublished: Bool
    /// The published progress can be cancelled from here.
    public var isCancellable: Bool
    /// Bytes on disk, or the published or Info.plist count when there is one.
    public var bytes: Int64
    /// The expected size; nil when nobody says.
    public var total: Int64?
    /// Last modified, in seconds on the same clock as the observation time.
    public var modifiedAt: Double

    public init(
        id: String, marker: TransferMarker? = nil, isPublished: Bool = false, isCancellable: Bool = false,
        bytes: Int64, total: Int64? = nil, modifiedAt: Double
    ) {
        self.id = id
        self.marker = marker
        self.isPublished = isPublished
        self.isCancellable = isCancellable
        self.bytes = bytes
        self.total = total
        self.modifiedAt = modifiedAt
    }

    /// A browser marker or a published progress: a transfer from the first sighting.
    public var isMarked: Bool { marker != nil || isPublished }
}

/// A download in progress.
public struct Transfer: Equatable, Sendable, Identifiable {
    public var id: String
    /// What the file will be called; nil when not known yet.
    public var name: String?
    public var marker: TransferMarker?
    public var isPublished: Bool
    public var bytes: Int64
    public var total: Int64?
    public var startedAt: Double
    /// When the byte count last went up, or the file was last written.
    public var lastActivityAt: Double
    /// The byte count at `startedAt`, so the rate counts only what arrived while watched.
    public var bytesAtStart: Int64 = 0
    /// Its published progress can be cancelled (Safari, the Finder); browsers' files cannot.
    public var isCancellable = false

    /// Seconds of watching before the rate, and so the time left, is trusted.
    public static let rateSeconds = 3.0

    /// 0...1 when the size is known.
    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(bytes) / Double(total)))
    }

    /// Bytes a second since it was first seen; nil for the first few seconds or with no growth.
    public func rate(at time: Double) -> Double? {
        let elapsed = time - startedAt
        guard elapsed >= Self.rateSeconds, bytes > bytesAtStart else { return nil }
        return Double(bytes - bytesAtStart) / elapsed
    }

    /// Seconds until done at the rate so far; nil without a size or a rate.
    public func secondsLeft(at time: Double) -> Double? {
        guard let total, total > bytes, let rate = rate(at: time) else { return nil }
        return Double(total - bytes) / rate
    }

    var isMarked: Bool { marker != nil || isPublished }
}

/// A transfer that completed; `name` is nil when it cannot be told.
public struct TransferFinish: Equatable, Sendable {
    public var id: String
    public var name: String?

    public init(id: String, name: String?) {
        self.id = id
        self.name = name
    }
}

// MARK: - Tracking

/// Turns a sequence of looks at Downloads into live transfers and finishes. Pure.
///
/// A marked file (browser extension or published progress) is a transfer at once, and finishes
/// when it goes away and its final name appears (or it had reached its size). A plain file
/// counts only once it has been seen growing after its first sighting, and finishes when it has
/// not grown for `settleSeconds`. Files present at the first look are never plain transfers.
/// A transfer that makes no progress for `stallSeconds` (a paused or failed Safari download
/// left behind) is kept but not live.
public struct TransferTracker: Equatable, Sendable {
    public static let settleSeconds = 3.0
    public static let stallSeconds = 30.0

    /// Everything being tracked, oldest first.
    public private(set) var transfers: [Transfer] = []
    /// Plain files seen since the first look that might yet grow: id to (bytes, first seen).
    private var candidates: [String: Candidate] = [:]
    private var previousIDs: Set<String> = []
    private var hasSeeded = false

    private struct Candidate: Equatable, Sendable {
        var bytes: Int64
        var seenAt: Double
    }

    public init() {}

    /// The transfers making progress, oldest first.
    public func live(at time: Double) -> [Transfer] {
        transfers.filter { time - $0.lastActivityAt < Self.stallSeconds }
    }

    /// Whether the watcher should look again in a second: something is live or may be growing.
    public func needsRefresh(at time: Double) -> Bool {
        !candidates.isEmpty || !live(at: time).isEmpty
    }

    /// Feeds one look at the folder: every file in it (the ones not modified lately may be left
    /// out, but then their names only count through `otherIDs`). Returns what finished.
    public mutating func observe(_ samples: [TransferSample], otherIDs: Set<String> = [], at time: Double) -> [TransferFinish] {
        let byID = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let present = otherIDs.union(byID.keys)
        let appeared = present.subtracting(previousIDs)
        defer {
            previousIDs = present
            hasSeeded = true
        }
        var finishes: [TransferFinish] = []
        var kept: [Transfer] = []
        for var transfer in transfers {
            if let sample = byID[transfer.id], sample.isMarked || !transfer.isMarked {
                update(&transfer, with: sample, at: time)
                if !transfer.isMarked, time - transfer.lastActivityAt >= Self.settleSeconds {
                    finishes.append(TransferFinish(id: transfer.id, name: transfer.name))
                } else {
                    kept.append(transfer)
                }
            } else if let finish = finish(transfer, present: present, appeared: appeared) {
                finishes.append(finish)
            }
        }
        transfers = kept
        let tracked = Set(transfers.map(\.id)).union(finishes.map(\.id))
        for sample in samples where !tracked.contains(sample.id) {
            if sample.isMarked {
                transfers.append(start(sample, at: time))
            } else if hasSeeded {
                considerPlain(sample, isNew: appeared.contains(sample.id), at: time)
            }
        }
        candidates = candidates.filter { id, candidate in
            present.contains(id) && time - candidate.seenAt < Self.settleSeconds && !transfers.contains { $0.id == id }
        }
        return finishes
    }

    private func start(_ sample: TransferSample, at time: Double) -> Transfer {
        let name = sample.marker == nil ? sample.id : TransferFiles.finalName(forFileName: sample.id)
        return Transfer(
            id: sample.id, name: name, marker: sample.marker, isPublished: sample.isPublished, bytes: sample.bytes,
            // A published progress is live by definition; a leftover bundle from last week is not.
            total: sample.total, startedAt: time, lastActivityAt: sample.isPublished ? time : min(sample.modifiedAt, time),
            bytesAtStart: sample.bytes, isCancellable: sample.isCancellable)
    }

    private func update(_ transfer: inout Transfer, with sample: TransferSample, at time: Double) {
        if sample.bytes > transfer.bytes || (sample.isMarked && sample.modifiedAt > transfer.lastActivityAt) {
            transfer.lastActivityAt = sample.bytes > transfer.bytes ? time : min(sample.modifiedAt, time)
        }
        transfer.bytes = sample.bytes
        transfer.total = sample.total ?? transfer.total
        transfer.isPublished = transfer.isPublished || sample.isPublished
        transfer.isCancellable = sample.isCancellable
    }

    /// A marked transfer whose file went away: finished when its final file is there, or a new
    /// file appeared for a Chrome download whose name was not known, or it had all its bytes.
    private func finish(_ transfer: Transfer, present: Set<String>, appeared: Set<String>) -> TransferFinish? {
        guard transfer.isMarked else { return nil }
        if let name = transfer.name, transfer.marker != nil, present.contains(name) {
            return TransferFinish(id: transfer.id, name: name)
        }
        if transfer.name == nil, appeared.count == 1, let name = appeared.first, TransferFiles.marker(forFileName: name) == nil {
            return TransferFinish(id: transfer.id, name: name)
        }
        if transfer.marker == nil, present.contains(transfer.id) {
            return TransferFinish(id: transfer.id, name: transfer.name)
        }
        if let fraction = transfer.fraction, fraction >= 1 {
            return TransferFinish(id: transfer.id, name: transfer.name)
        }
        return nil
    }

    private mutating func considerPlain(_ sample: TransferSample, isNew: Bool, at time: Double) {
        if let candidate = candidates[sample.id] {
            guard sample.bytes > candidate.bytes else { return }
            var transfer = start(sample, at: candidate.seenAt)
            transfer.lastActivityAt = time
            transfer.bytesAtStart = candidate.bytes
            transfers.append(transfer)
            candidates[sample.id] = nil
        } else if isNew {
            candidates[sample.id] = Candidate(bytes: sample.bytes, seenAt: time)
        }
    }
}

// MARK: - Summary and words

/// What Compact and the Expanded row show of the live transfers.
public struct TransferSummary: Equatable, Sendable {
    public var count: Int
    public var bytes: Int64
    /// Known only when every live transfer's size is.
    public var total: Int64?

    public init(_ transfers: [Transfer]) {
        count = transfers.count
        bytes = transfers.reduce(0) { $0 + $1.bytes }
        let totals = transfers.compactMap(\.total)
        total = totals.count == transfers.count && !totals.isEmpty ? totals.reduce(0, +) : nil
    }

    /// 0...1 over all of them when every size is known.
    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(bytes) / Double(total)))
    }
}

/// The words the Transfers activity uses. Pure so the formats are tested.
public enum TransferText {
    /// "42 %", rounded down and held at 99 % until the file is done.
    public static func percent(_ fraction: Double) -> String {
        let whole = Int((min(1, max(0, fraction)) * 100).rounded(.down))
        return "\(fraction < 1 ? min(whole, 99) : 100) %"
    }

    /// Decimal units like the Finder: "820 KB", "4.2 MB", "12 MB", "1.3 GB".
    public static func size(_ bytes: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes))
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(Int(value)) bytes" }
        if value < 10 {
            let tenths = (value * 10).rounded() / 10
            if tenths < 10 { return String(format: "%.1f %@", tenths, units[unit]) }
        }
        return "\(Int(value.rounded())) \(units[unit])"
    }

    /// The row's detail: "42 % · 12 of 30 MB", or "12 MB" while the size is unknown.
    public static func detail(_ summary: TransferSummary) -> String {
        guard let total = summary.total, let fraction = summary.fraction else { return size(summary.bytes) }
        return "\(percent(fraction)) · \(size(summary.bytes)) of \(size(total))"
    }

    /// The row's title: the file's name, "Download" when names are hidden, or "3 downloads".
    public static func title(_ transfers: [Transfer], showsNames: Bool) -> String {
        guard transfers.count == 1, let only = transfers.first else { return "\(transfers.count) downloads" }
        return showsNames ? (only.name ?? "Download") : "Download"
    }

    /// The time left, rounded up: "8 s left", "3 min left", "1 h 5 min left".
    public static func timeLeft(seconds: Double) -> String {
        let whole = max(1, Int(seconds.rounded(.up)))
        if whole < 60 { return "\(whole) s left" }
        let minutes = (whole + 59) / 60
        if minutes < 60 { return "\(minutes) min left" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h left" : "\(minutes / 60) h \(rest) min left"
    }

    /// One download's detail: "40 % · 12 MB of 30 MB · 2 min left", without the time left until
    /// the rate is known, and only the bytes while the size is not.
    public static func detail(_ transfer: Transfer, at time: Double) -> String {
        let base = detail(TransferSummary([transfer]))
        guard let seconds = transfer.secondsLeft(at: time) else { return base }
        return "\(base) · \(timeLeft(seconds: seconds))"
    }

    /// The line under the capped list: "and 3 more". Nil for none.
    public static func more(_ count: Int) -> String? {
        count > 0 ? "and \(count) more" : nil
    }

    /// The pulse when downloads finish: "Downloaded · report.pdf", "Downloaded · file" when names
    /// are hidden, "Downloaded · 2 files". Nil for none.
    public static func finished(_ finishes: [TransferFinish], showsNames: Bool) -> String? {
        guard let first = finishes.first else { return nil }
        guard finishes.count == 1 else { return "Downloaded · \(finishes.count) files" }
        let name = showsNames ? (first.name ?? "file") : "file"
        return "Downloaded · \(name)"
    }
}

// MARK: - One line per download

/// One download's line in Expanded, under the summary row.
public struct TransferLine: Equatable, Sendable, Identifiable {
    /// The transfer's id: its file name in Downloads.
    public var id: String
    public var title: String
    public var detail: String
    public var fraction: Double?
    public var canCancel: Bool
}

/// The per-download lines Expanded shows under the Transfers row. Pure.
public enum TransferLines {
    /// More than this many downloads show this many lines and "and N more".
    public static let maxLines = 4

    /// A line per download, oldest first (ties by id, so lines keep their places across looks),
    /// at most `limit` of them, and how many were left out. A single download is the row
    /// itself and gets no lines. With names hidden the titles are "Download 1", "Download 2".
    public static func build(
        _ live: [Transfer], showsNames: Bool, at time: Double, limit: Int = maxLines
    ) -> (lines: [TransferLine], more: Int) {
        guard live.count > 1 else { return ([], 0) }
        let ordered = live.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        let shown = ordered.prefix(max(0, limit))
        let lines = shown.enumerated().map { index, transfer in
            TransferLine(
                id: transfer.id,
                title: showsNames ? (transfer.name ?? "Download") : "Download \(index + 1)",
                detail: TransferText.detail(transfer, at: time),
                fraction: transfer.fraction,
                canCancel: transfer.isCancellable)
        }
        return (lines, ordered.count - shown.count)
    }
}
