import Testing
@testable import NotchKit

@Suite struct TransferFilesTests {
    @Test func browserMarkersAreRecognised() {
        #expect(TransferFiles.marker(forFileName: "report.pdf.download") == .safari)
        #expect(TransferFiles.marker(forFileName: "movie.mp4.crdownload") == .chromium)
        #expect(TransferFiles.marker(forFileName: "setup.dmg.part") == .firefox)
        #expect(TransferFiles.marker(forFileName: "a.zip.opdownload") == .opera)
        #expect(TransferFiles.marker(forFileName: "notes.txt") == nil)
        #expect(TransferFiles.marker(forFileName: ".download") == nil)
    }

    @Test func finalNamesDropTheMarker() {
        #expect(TransferFiles.finalName(forFileName: "report.pdf.download") == "report.pdf")
        #expect(TransferFiles.finalName(forFileName: "setup.dmg.part") == "setup.dmg")
        #expect(TransferFiles.finalName(forFileName: "Unconfirmed 81234.crdownload") == nil)
        #expect(TransferFiles.finalName(forFileName: "notes.txt") == nil)
    }

    @Test func hiddenFilesAreIgnored() {
        #expect(TransferFiles.isIgnored(fileName: ".DS_Store"))
        #expect(TransferFiles.isIgnored(fileName: ".localized"))
        #expect(!TransferFiles.isIgnored(fileName: "report.pdf"))
    }
}

@Suite struct TransferTrackerTests {
    private func file(_ id: String, _ bytes: Int64, total: Int64? = nil, at modified: Double, published: Bool = false) -> TransferSample {
        TransferSample(id: id, marker: TransferFiles.marker(forFileName: id), isPublished: published, bytes: bytes, total: total, modifiedAt: modified)
    }

    @Test func safariDownloadFinishesWhenTheFileAppears() {
        var tracker = TransferTracker()
        _ = tracker.observe([file("old.txt", 10, at: 0)], at: 100)
        let first = tracker.observe([file("old.txt", 10, at: 0), file("report.pdf.download", 100, total: 1000, at: 101)], at: 101)
        #expect(first.isEmpty)
        #expect(tracker.live(at: 101).map(\.name) == ["report.pdf"])
        #expect(tracker.live(at: 101).first?.fraction == 0.1)
        let done = tracker.observe([file("old.txt", 10, at: 0), file("report.pdf", 1000, at: 105)], at: 105)
        #expect(done == [TransferFinish(id: "report.pdf.download", name: "report.pdf")])
        #expect(tracker.transfers.isEmpty)
    }

    @Test func aCancelledDownloadDoesNotFinish() {
        var tracker = TransferTracker()
        _ = tracker.observe([file("setup.dmg.part", 50, at: 10)], at: 10)
        #expect(tracker.live(at: 10).count == 1)
        let gone = tracker.observe([], at: 12)
        #expect(gone.isEmpty)
        #expect(tracker.transfers.isEmpty)
    }

    @Test func chromeUnconfirmedFinishesUnderItsNewName() {
        var tracker = TransferTracker()
        _ = tracker.observe([], at: 0)
        _ = tracker.observe([file("Unconfirmed 42.crdownload", 5, at: 1)], at: 1)
        let done = tracker.observe([file("photo.jpg", 500, at: 3)], at: 3)
        #expect(done == [TransferFinish(id: "Unconfirmed 42.crdownload", name: "photo.jpg")])
    }

    @Test func aPlainFileCountsOnlyOnceItGrows() {
        var tracker = TransferTracker()
        _ = tracker.observe([], at: 0)
        _ = tracker.observe([file("big.iso", 100, at: 1)], at: 1)
        #expect(tracker.live(at: 1).isEmpty)
        #expect(tracker.needsRefresh(at: 1))
        _ = tracker.observe([file("big.iso", 300, at: 2)], at: 2)
        #expect(tracker.live(at: 2).map(\.name) == ["big.iso"])
        _ = tracker.observe([file("big.iso", 600, at: 3)], at: 3)
        #expect(tracker.observe([file("big.iso", 600, at: 3)], at: 4).isEmpty)
        let done = tracker.observe([file("big.iso", 600, at: 3)], at: 6)
        #expect(done == [TransferFinish(id: "big.iso", name: "big.iso")])
        #expect(!tracker.needsRefresh(at: 6))
    }

    @Test func aFileSavedAtOnceIsNotATransfer() {
        var tracker = TransferTracker()
        _ = tracker.observe([], at: 0)
        _ = tracker.observe([file("saved.png", 100, at: 1)], at: 1)
        _ = tracker.observe([file("saved.png", 100, at: 1)], at: 2)
        let later = tracker.observe([file("saved.png", 100, at: 1)], at: 5)
        #expect(later.isEmpty)
        #expect(tracker.transfers.isEmpty)
        #expect(!tracker.needsRefresh(at: 5))
    }

    @Test func filesThereAtLaunchAreNotPlainTransfers() {
        var tracker = TransferTracker()
        _ = tracker.observe([file("log.txt", 100, at: 0)], at: 0)
        _ = tracker.observe([file("log.txt", 200, at: 1)], at: 1)
        #expect(tracker.transfers.isEmpty)
    }

    @Test func aLeftoverSafariBundleIsNotLive() {
        var tracker = TransferTracker()
        _ = tracker.observe([file("old.zip.download", 10, total: 100, at: 0)], at: 1000)
        #expect(tracker.transfers.count == 1)
        #expect(tracker.live(at: 1000).isEmpty)
        #expect(!tracker.needsRefresh(at: 1000))
    }

    @Test func aPublishedProgressIsLiveAndFinishesWhenUnpublished() {
        var tracker = TransferTracker()
        _ = tracker.observe([file("AirDrop.mov", 10, total: 40, at: 0, published: true)], at: 50)
        #expect(tracker.live(at: 50).first?.fraction == 0.25)
        let done = tracker.observe([file("AirDrop.mov", 40, at: 52)], at: 52)
        #expect(done == [TransferFinish(id: "AirDrop.mov", name: "AirDrop.mov")])
    }

    @Test func aStalledDownloadStopsBeingLive() {
        var tracker = TransferTracker()
        _ = tracker.observe([file("a.zip.crdownload", 10, at: 0)], at: 0)
        #expect(tracker.live(at: 10).count == 1)
        _ = tracker.observe([file("a.zip.crdownload", 10, at: 0)], at: 31)
        #expect(tracker.live(at: 31).isEmpty)
        _ = tracker.observe([file("a.zip.crdownload", 20, at: 40)], at: 40)
        #expect(tracker.live(at: 40).count == 1)
    }
}

@Suite struct TransferTextTests {
    private func transfer(_ name: String?, _ bytes: Int64, total: Int64?) -> Transfer {
        Transfer(id: name ?? "x", name: name, marker: .safari, isPublished: false, bytes: bytes, total: total, startedAt: 0, lastActivityAt: 0)
    }

    @Test func summaryNeedsEverySize() {
        var summary = TransferSummary([transfer("a", 25, total: 100), transfer("b", 25, total: 100)])
        #expect(summary.fraction == 0.25)
        summary = TransferSummary([transfer("a", 25, total: 100), transfer("b", 25, total: nil)])
        #expect(summary.fraction == nil)
        #expect(summary.bytes == 50)
        summary = TransferSummary([])
        #expect(summary.fraction == nil)
    }

    @Test func percentHoldsAt99UntilDone() {
        #expect(TransferText.percent(0.421) == "42 %")
        #expect(TransferText.percent(0.999) == "99 %")
        #expect(TransferText.percent(1) == "100 %")
        #expect(TransferText.percent(0) == "0 %")
    }

    @Test func sizesUseDecimalUnits() {
        #expect(TransferText.size(512) == "512 bytes")
        #expect(TransferText.size(820_000) == "820 KB")
        #expect(TransferText.size(4_230_000) == "4.2 MB")
        #expect(TransferText.size(12_400_000) == "12 MB")
        #expect(TransferText.size(9_990_000) == "10 MB")
        #expect(TransferText.size(1_300_000_000) == "1.3 GB")
    }

    @Test func detailAndTitle() {
        let one = [transfer("report.pdf", 12_000_000, total: 30_000_000)]
        #expect(TransferText.detail(TransferSummary(one)) == "40 % · 12 MB of 30 MB")
        #expect(TransferText.detail(TransferSummary([transfer("a", 4_200_000, total: nil)])) == "4.2 MB")
        #expect(TransferText.title(one, showsNames: true) == "report.pdf")
        #expect(TransferText.title(one, showsNames: false) == "Download")
        #expect(TransferText.title(one + one, showsNames: true) == "2 downloads")
    }

    @Test func finishedPulse() {
        let finish = TransferFinish(id: "a.download", name: "a.pdf")
        #expect(TransferText.finished([finish], showsNames: true) == "Downloaded · a.pdf")
        #expect(TransferText.finished([finish], showsNames: false) == "Downloaded · file")
        #expect(TransferText.finished([TransferFinish(id: "x", name: nil)], showsNames: true) == "Downloaded · file")
        #expect(TransferText.finished([finish, finish], showsNames: true) == "Downloaded · 2 files")
        #expect(TransferText.finished([], showsNames: true) == nil)
    }
}

@Suite struct TransferLinesTests {
    private func transfer(
        _ id: String, _ bytes: Int64, total: Int64? = nil, startedAt: Double = 0, bytesAtStart: Int64 = 0, cancellable: Bool = false
    ) -> Transfer {
        Transfer(
            id: id, name: TransferFiles.finalName(forFileName: id) ?? id, marker: .safari, isPublished: cancellable,
            bytes: bytes, total: total, startedAt: startedAt, lastActivityAt: startedAt, bytesAtStart: bytesAtStart,
            isCancellable: cancellable)
    }

    @Test func rateAndTimeLeftWaitForAFewSeconds() {
        let item = transfer("a.zip.download", 6_000_000, total: 30_000_000, startedAt: 100, bytesAtStart: 0)
        #expect(item.rate(at: 101) == nil)
        #expect(item.rate(at: 106) == 1_000_000)
        #expect(item.secondsLeft(at: 106) == 24)
        #expect(transfer("b", 10, startedAt: 0, bytesAtStart: 10).rate(at: 10) == nil)
        #expect(transfer("c", 10, startedAt: 0).secondsLeft(at: 10) == nil)
    }

    @Test func timeLeftRoundsUp() {
        #expect(TransferText.timeLeft(seconds: 0.2) == "1 s left")
        #expect(TransferText.timeLeft(seconds: 7.4) == "8 s left")
        #expect(TransferText.timeLeft(seconds: 61) == "2 min left")
        #expect(TransferText.timeLeft(seconds: 3600) == "1 h left")
        #expect(TransferText.timeLeft(seconds: 3900) == "1 h 5 min left")
    }

    @Test func lineDetailAddsTheTimeLeft() {
        let item = transfer("a.zip.download", 12_000_000, total: 30_000_000, startedAt: 0)
        #expect(TransferText.detail(item, at: 1) == "40 % · 12 MB of 30 MB")
        #expect(TransferText.detail(item, at: 12) == "40 % · 12 MB of 30 MB · 18 s left")
        #expect(TransferText.detail(transfer("b", 4_200_000), at: 12) == "4.2 MB")
    }

    @Test func aSingleDownloadHasNoLines() {
        let result = TransferLines.build([transfer("a.zip.download", 1)], showsNames: true, at: 0)
        #expect(result.lines.isEmpty)
        #expect(result.more == 0)
    }

    @Test func linesAreOldestFirstAndStable() {
        let live = [
            transfer("c.zip.download", 1, startedAt: 5),
            transfer("b.zip.download", 1, startedAt: 2),
            transfer("a.zip.download", 1, startedAt: 5, cancellable: true),
        ]
        let result = TransferLines.build(live, showsNames: true, at: 10)
        #expect(result.lines.map(\.title) == ["b.zip", "a.zip", "c.zip"])
        #expect(result.lines.map(\.canCancel) == [false, true, false])
        #expect(result.more == 0)
    }

    @Test func linesAreCappedWithACount() {
        let live = (0..<7).map { transfer("f\($0).download", 1, startedAt: Double($0)) }
        let result = TransferLines.build(live, showsNames: true, at: 10)
        #expect(result.lines.count == TransferLines.maxLines)
        #expect(result.lines.map(\.id) == ["f0.download", "f1.download", "f2.download", "f3.download"])
        #expect(result.more == 3)
        #expect(TransferText.more(result.more) == "and 3 more")
        #expect(TransferText.more(0) == nil)
    }

    @Test func hiddenNamesAreNumbered() {
        let live = [transfer("secret.pdf.download", 1), transfer("plan.key.download", 1, startedAt: 1)]
        let result = TransferLines.build(live, showsNames: false, at: 10)
        #expect(result.lines.map(\.title) == ["Download 1", "Download 2"])
    }

    @Test func trackerCarriesCancellabilityAndStartingBytes() {
        var tracker = TransferTracker()
        let sample = TransferSample(id: "AirDrop.mov", isPublished: true, isCancellable: true, bytes: 10, total: 40, modifiedAt: 0)
        _ = tracker.observe([sample], at: 50)
        let live = tracker.live(at: 50)
        #expect(live.first?.isCancellable == true)
        #expect(live.first?.bytesAtStart == 10)
    }
}
