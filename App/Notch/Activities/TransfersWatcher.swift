import AppKit
import Foundation
import NotchKit
import os

/// N6: downloads in progress in the user's Downloads folder.
///
/// Event-driven: a file-system object source on the folder wakes it when files are added,
/// removed or renamed, and `Progress.addSubscriber(forFileURL:)` wakes it when an app (Safari,
/// Chrome, the Finder, AirDrop) publishes progress for a file there. Each wake-up takes one look
/// at the folder and hands it to `TransferTracker`. Only while a transfer is live, or a new file
/// may still be growing, does it look again every second; at idle it does nothing.
///
/// Progress comes from the published `NSProgress` when there is one, then from a Safari
/// `.download` bundle's Info.plist, then from the size on disk.
@MainActor
final class TransfersWatcher {
    /// The live transfers or their progress changed.
    var onChange: (@MainActor () -> Void)?
    /// Transfers that completed since the last look.
    var onFinish: (@MainActor ([TransferFinish]) -> Void)?

    /// The transfers making progress, oldest first.
    private(set) var live: [Transfer] = []

    private let folder: URL? = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    private var tracker = TransferTracker()
    private var source: DispatchSourceFileSystemObject?
    private var subscriber: Any?
    private let published = PublishedProgress()
    private var tickTask: Task<Void, Never>?
    private var isStarted = false
    private var didLogReadError = false
    private let log = Logger(subsystem: "app.somabar", category: "activities")

    /// Plain files modified longer ago than this are only names to the tracker, not samples.
    static let recentSeconds = 60.0
    /// Safari's progress keys in a `.download` bundle's Info.plist.
    static let safariBytesKey = "DownloadEntryProgressBytesSoFar"
    static let safariTotalKey = "DownloadEntryProgressTotalToLoad"

    private static var clock: Double {
        Date().timeIntervalSinceReferenceDate
    }

    /// The watcher that progress publishers reach from their own queue.
    fileprivate static weak var current: TransfersWatcher?

    // MARK: - Lifecycle

    func start() {
        guard !isStarted, let folder else { return }
        isStarted = true
        Self.current = self
        tracker = TransferTracker()
        watchFolder(folder)
        subscribe(to: folder)
        look()
        log.notice("Transfers: watching \(folder.path, privacy: .private)")
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        source?.cancel()
        source = nil
        if let subscriber {
            Progress.removeSubscriber(subscriber)
        }
        subscriber = nil
        published.removeAll()
        tickTask?.cancel()
        tickTask = nil
        tracker = TransferTracker()
        let hadLive = !live.isEmpty
        live = []
        if Self.current === self {
            Self.current = nil
        }
        if hadLive {
            onChange?()
        }
    }

    /// Selects the live downloads in the Finder, or opens Downloads when there are none.
    func showInFinder() {
        guard let folder else { return }
        let urls = live.map { folder.appendingPathComponent($0.id) }
        if urls.isEmpty {
            NSWorkspace.shared.open(folder)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    /// Selects one download in the Finder.
    func reveal(_ id: String) {
        guard let folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(id)])
    }

    /// Cancels one download through its published progress, which passes it on to the app
    /// that publishes it. Browsers' own files have none and offer no Cancel.
    func cancel(_ id: String) {
        guard published.cancel(name: id) else {
            log.notice("Transfers: nothing to cancel for a download")
            return
        }
        log.notice("Transfers: cancelled a download")
        look()
    }

    // MARK: - Sources

    private func watchFolder(_ folder: URL) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            log.error("Transfers: cannot watch Downloads (errno \(errno))")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .link], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.look() }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    /// Progress published for any file in Downloads. The handlers run on a queue of
    /// Foundation's choosing; the store is locked and the look happens on the main actor.
    /// When the handler runs, the proxy's `fileURL` is still nil (observed on macOS 26); the
    /// URL is already in its user info.
    private func subscribe(to folder: URL) {
        let store = published
        let root = folder.standardizedFileURL.pathComponents
        subscriber = Progress.addSubscriber(forFileURL: folder) { progress in
            let url = progress.fileURL ?? progress.userInfo[.fileURLKey] as? URL
            guard let name = Self.entryName(of: url, under: root) else { return nil }
            let token = store.add(progress, name: name)
            Self.wake()
            return {
                store.remove(token)
                Self.wake()
            }
        }
    }

    /// The name of the entry directly in Downloads that `url` is or is inside of.
    nonisolated private static func entryName(of url: URL?, under root: [String]) -> String? {
        guard let components = url?.standardizedFileURL.pathComponents,
              components.count > root.count, Array(components.prefix(root.count)) == root
        else { return nil }
        return components[root.count]
    }

    nonisolated private static func wake() {
        Task { @MainActor in
            TransfersWatcher.current?.look()
        }
    }

    // MARK: - Looking

    /// One look at Downloads: feeds the tracker, reports finishes and changes, and keeps the
    /// 1 s refresh running only while it is needed.
    private func look() {
        guard isStarted, let folder else { return }
        let now = Self.clock
        let (samples, others) = readFolder(folder, now: now)
        let finishes = tracker.observe(samples, otherIDs: others, at: now)
        let next = tracker.live(at: now)
        let changed = next != live
        live = next
        if !finishes.isEmpty {
            log.info("Transfers: \(finishes.count) finished")
            onFinish?(finishes)
        }
        if changed {
            onChange?()
        }
        updateTick(now: now)
    }

    private func updateTick(now: Double) {
        let needsTick = tracker.needsRefresh(at: now)
        if needsTick, tickTask == nil {
            tickTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    self.look()
                }
            }
        } else if !needsTick {
            tickTask?.cancel()
            tickTask = nil
        }
    }

    /// Samples for marked and recently written files; the names of everything else.
    private func readFolder(_ folder: URL, now: Double) -> ([TransferSample], Set<String>) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])
        } catch {
            if !didLogReadError {
                didLogReadError = true
                log.error("Transfers: cannot read Downloads: \(error.localizedDescription, privacy: .public)")
            }
            return ([], [])
        }
        let progress = published.snapshot()
        var samples: [TransferSample] = []
        var others: Set<String> = []
        for url in entries {
            let name = url.lastPathComponent
            guard !TransferFiles.isIgnored(fileName: name) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let marker = TransferFiles.marker(forFileName: name)
            var sample = TransferSample(
                id: name, marker: marker, bytes: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)
            if values?.isDirectory == true {
                guard marker == .safari || progress[name] != nil else {
                    others.insert(name)
                    continue
                }
                if marker == .safari {
                    readSafariBundle(url, into: &sample)
                }
            }
            if let published = progress[name] {
                sample.isPublished = true
                sample.isCancellable = published.cancellable
                sample.bytes = max(sample.bytes, published.completed)
                sample.total = published.total ?? sample.total
            }
            if sample.isMarked || now - sample.modifiedAt < Self.recentSeconds {
                samples.append(sample)
            } else {
                others.insert(name)
            }
        }
        return (samples, others)
    }

    /// A Safari bundle: the Info.plist's counts, else the size and date of the files inside.
    private func readSafariBundle(_ bundle: URL, into sample: inout TransferSample) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let inner = (try? FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: Array(keys), options: [])) ?? []
        var bytes: Int64 = 0
        for file in inner where file.lastPathComponent != "Info.plist" {
            let values = try? file.resourceValues(forKeys: keys)
            bytes += Int64(values?.fileSize ?? 0)
            if let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate {
                sample.modifiedAt = max(sample.modifiedAt, modified)
            }
        }
        sample.bytes = bytes
        let plistURL = bundle.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return }
        if let soFar = (plist[Self.safariBytesKey] as? NSNumber)?.int64Value {
            sample.bytes = max(bytes, soFar)
        }
        if let total = (plist[Self.safariTotalKey] as? NSNumber)?.int64Value, total > 0 {
            sample.total = total
        }
    }
}

// MARK: - Published progress

/// Progress objects published for files in Downloads, by entry name. Written from Foundation's
/// queue, read on the main actor; a lock keeps them apart. `Progress` is thread-safe.
private final class PublishedProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int: (name: String, progress: Progress)] = [:]
    private var nextToken = 0

    func add(_ progress: Progress, name: String) -> Int {
        lock.withLock {
            nextToken += 1
            items[nextToken] = (name, progress)
            return nextToken
        }
    }

    func remove(_ token: Int) {
        lock.withLock { _ = items.removeValue(forKey: token) }
    }

    func removeAll() {
        lock.withLock { items = [:] }
    }

    /// Cancels every cancellable progress for the entry; false when there was none.
    func cancel(name: String) -> Bool {
        let targets = lock.withLock {
            items.values.filter { $0.name == name && $0.progress.isCancellable && !$0.progress.isCancelled }.map(\.progress)
        }
        // Outside the lock: cancelling may call back into the subscriber, which takes it.
        targets.forEach { $0.cancel() }
        return !targets.isEmpty
    }

    /// One entry's progress; a total of zero or less is unknown.
    struct Entry {
        var completed: Int64
        var total: Int64?
        var cancellable: Bool
    }

    /// Each entry's progress, by name.
    func snapshot() -> [String: Entry] {
        lock.withLock {
            var result: [String: Entry] = [:]
            for (name, progress) in items.values where !progress.isCancelled {
                let total = progress.totalUnitCount
                result[name] = Entry(
                    completed: max(0, progress.completedUnitCount), total: total > 0 ? total : nil, cancellable: progress.isCancellable)
            }
            return result
        }
    }
}
