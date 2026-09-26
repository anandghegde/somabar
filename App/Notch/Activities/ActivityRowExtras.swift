import NotchKit
import SwiftUI

// MARK: - Scrubber

/// A position a row can be moved through: Now Playing's place in the track.
struct ActivityScrubber {
    /// Seconds in, at the row's last refresh.
    var position: Double
    /// Seconds in all; above zero.
    var duration: Double
    /// Called once, when the person lets go (or after a keyboard step).
    var seek: @MainActor (Double) -> Void
}

/// A slider in place of the static progress bar. It follows the track until it is dragged, and
/// seeks only on release. Arrow keys step it; VoiceOver reads "1:23 of 3:45" and adjusts by 5 s.
struct ScrubberView: View {
    let scrubber: ActivityScrubber
    @State private var dragged: Double?
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 6) {
            Slider(value: value, in: 0...scrubber.duration, step: 1) { editing in
                isEditing = editing
                if !editing { commit() }
            }
            .controlSize(.mini)
            .tint(.white)
            .accessibilityLabel("Position")
            .accessibilityValue("\(ActivityText.elapsed(seconds: shown)) of \(ActivityText.elapsed(seconds: scrubber.duration))")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 5.0 : -5.0
                scrubber.seek(min(scrubber.duration, max(0, shown + step)))
            }
            Text(ActivityText.elapsed(seconds: shown))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .accessibilityHidden(true)
        }
    }

    private var shown: Double {
        dragged ?? min(scrubber.position, scrubber.duration)
    }

    /// A drag seeks when it ends; a keyboard step, which has no drag, seeks at once.
    private var value: Binding<Double> {
        Binding(get: { shown }, set: { newValue in
            dragged = newValue
            if !isEditing { commit() }
        })
    }

    private func commit() {
        guard let dragged else { return }
        scrubber.seek(dragged)
        self.dragged = nil
    }
}

// MARK: - Menu

/// A 44 pt button that opens a list to pick from: Now Playing's audio output.
struct ActivityMenu {
    struct Item: Identifiable {
        var id: UInt32
        var title: String
        var symbol: String
        var isSelected: Bool
    }

    var symbol: String
    var label: String
    var items: [Item]
    var select: @MainActor (Item.ID) -> Void
}

struct ActivityMenuView: View {
    let menu: ActivityMenu

    var body: some View {
        Menu {
            ForEach(menu.items) { item in
                Button {
                    menu.select(item.id)
                } label: {
                    Label(item.title, systemImage: item.isSelected ? "checkmark" : item.symbol)
                }
                .accessibilityAddTraits(item.isSelected ? .isSelected : [])
            }
        } label: {
            Image(systemName: menu.symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: ActivityRowView.controlSize, height: ActivityRowView.controlSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(menu.label)
        .help(menu.label)
    }
}

// MARK: - Lines

/// One item under a row that sums several up: a title, a detail, a thin progress bar, and its
/// own controls (one download: Show in Finder, Cancel).
struct ActivityLine: Identifiable {
    var id: String
    var title: String
    var detail: String
    var progress: Double?
    var controls: [ActivityControl] = []

    /// A line is as tall as its 44 pt controls; the footer is one line of small text.
    static let height: CGFloat = 44
    static let footerHeight: CGFloat = 16
    static let spacing: CGFloat = 4
}

extension ActivityRow {
    /// What the row's lines add to its height in Expanded.
    var linesHeight: CGFloat {
        guard !lines.isEmpty else { return 0 }
        let footer = linesFooter == nil ? 0 : ActivityLine.footerHeight + ActivityLine.spacing
        return ActivityLine.spacing + CGFloat(lines.count) * ActivityLine.height + footer
    }

    /// The most any row's lines can add: Transfers' full list and its footer.
    static let maxLinesHeight = ActivityLine.spacing + CGFloat(TransferLines.maxLines) * ActivityLine.height
        + ActivityLine.footerHeight + ActivityLine.spacing
}

/// The lines under a row, indented to line up with its title.
struct ActivityLinesView: View {
    let lines: [ActivityLine]
    let footer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                ActivityLineView(line: line)
            }
            if let footer {
                Text(footer)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(height: ActivityLine.footerHeight)
                    .padding(.top, ActivityLine.spacing)
            }
        }
        // The row's 32 pt glyph and 8 pt of spacing.
        .padding(.leading, 40)
    }
}

struct ActivityLineView: View {
    let line: ActivityLine

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(line.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(line.detail)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let progress = line.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .controlSize(.mini)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(line.title), \(line.detail)")
            ForEach(line.controls) { control in
                Button(action: control.action) {
                    Image(systemName: control.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: ActivityRowView.controlSize, height: ActivityLine.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(control.label) \(line.title)")
                .help(control.label)
            }
        }
        .frame(height: ActivityLine.height)
    }
}
