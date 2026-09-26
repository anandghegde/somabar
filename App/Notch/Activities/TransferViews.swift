import NotchKit
import SomabarCore
import SwiftUI

// MARK: - N6 Transfers

/// Compact's progress ring for downloads: a thin track and a white arc from twelve o'clock.
/// With no known size it draws a quarter arc, still, as a sign that something is loading.
struct ProgressRing: View {
    let fraction: Double?
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, fraction ?? 0.25))
                .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension NotchActivity {
    /// The Transfers activity for the live downloads, or nil when there are none. Compact is a
    /// ring and the percent (or bytes so far). In Expanded one download is the row itself, with
    /// the time left, Show in Finder and (when its progress allows) Cancel; several are a summary
    /// row with a line each under it, capped by `TransferLines`. File names only when the
    /// profile shows them.
    static func transfers(
        _ live: [Transfer], startedAt: Double, now: Double, settings: NotchSettings, watcher: TransfersWatcher
    ) -> NotchActivity? {
        guard !live.isEmpty else { return nil }
        let showsNames = settings.showsArtworkAndFileNames
        let summary = TransferSummary(live)
        let text = summary.fraction.map(TransferText.percent) ?? TransferText.size(summary.bytes)
        let title = TransferText.title(live, showsNames: showsNames)
        let (built, more) = TransferLines.build(live, showsNames: showsNames, at: now)
        let lines = built.map { line in
            ActivityLine(
                id: line.id, title: line.title, detail: line.detail, progress: line.fraction,
                controls: controls(id: line.id, canCancel: line.canCancel, watcher: watcher))
        }
        var row = ActivityRow(
            id: .transfers, symbol: "arrow.down.circle", title: title, detail: TransferText.detail(summary),
            progress: summary.fraction, lines: lines, linesFooter: TransferText.more(more))
        if live.count == 1, let only = live.first {
            row.detail = TransferText.detail(only, at: now)
            row.controls = controls(id: only.id, canCancel: only.isCancellable, watcher: watcher)
        } else {
            row.controls = [ActivityControl(symbol: "magnifyingglass", label: "Show in Finder") { watcher.showInFinder() }]
        }
        return NotchActivity(
            kind: .transfers, rank: .transfer, startedAt: startedAt,
            compact: CompactPresentation(
                kind: .transfers, symbol: "arrow.down.circle", text: text,
                accessibilityLabel: "Downloading \(title), \(row.detail)", showsRing: true, ringFraction: summary.fraction),
            row: row)
    }

    /// One download's buttons: Show in Finder always, Cancel only when its progress can be.
    private static func controls(id: String, canCancel: Bool, watcher: TransfersWatcher) -> [ActivityControl] {
        var controls = [ActivityControl(symbol: "magnifyingglass", label: "Show in Finder") { watcher.reveal(id) }]
        if canCancel {
            controls.append(ActivityControl(symbol: "xmark.circle", label: "Cancel download") { watcher.cancel(id) })
        }
        return controls
    }
}

// MARK: - N7 Volume HUD

/// The volume pulse: the speaker on the camera's left; a slim bar and the percent on its right.
/// On a drawn notch the three sit in a row across the middle.
struct VolumePulseView: View {
    let model: NotchModel
    let level: Double

    private var muted: Bool { model.pulseSymbol == "speaker.slash.fill" }

    var body: some View {
        Group {
            if model.cameraRect.width > 0 {
                CameraSplitView(model: model) {
                    speaker
                } right: {
                    HStack(spacing: 6) {
                        bar
                        percent
                    }
                    .padding(.horizontal, 6)
                }
            } else {
                HStack(spacing: 8) {
                    speaker
                    bar
                    percent
                }
                .padding(.horizontal, 12)
                .frame(width: model.shapeRect.width, height: model.shapeRect.height)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(muted ? "Volume muted" : "Volume \(model.pulseText)")
    }

    private var speaker: some View {
        Image(systemName: model.pulseSymbol)
            .font(.system(size: 13, weight: .semibold))
            .contentTransition(.symbolEffect(.replace))
    }

    private var bar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule()
                    .fill(Color.white.opacity(muted ? 0.4 : 1))
                    .frame(width: proxy.size.width * min(1, max(0, level)))
            }
        }
        .frame(height: 4)
    }

    private var percent: some View {
        Text(model.pulseText)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .fixedSize()
    }
}
