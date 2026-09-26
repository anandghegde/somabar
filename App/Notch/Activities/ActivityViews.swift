import SwiftUI

/// Compact for any activity: the glyph or artwork left of the camera, the time right of it in
/// SF Mono.
struct CompactActivityView: View {
    let model: NotchModel
    let compact: CompactPresentation

    var body: some View {
        CameraSplitView(model: model) {
            HStack(spacing: 4) {
                if compact.showsDot {
                    Circle()
                        .fill(compact.tint.color)
                        .frame(width: 6, height: 6)
                }
                glyph
            }
        } right: {
            Text(compact.text)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .minimumScaleFactor(0.7)
                .foregroundStyle(compact.showsDot ? Color.white : compact.tint.color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(compact.accessibilityLabel)
    }

    @ViewBuilder private var glyph: some View {
        if compact.showsRing {
            ProgressRing(fraction: compact.ringFraction)
        } else if let image = compact.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: compact.symbol)
                .foregroundStyle(compact.showsDot ? Color.white : compact.tint.color)
        }
    }
}

/// One live activity in Expanded: what it is, a detail line, and its controls. Controls are
/// 44 pt square and carry VoiceOver labels; they are buttons, so the keyboard reaches them.
struct ActivityRowView: View {
    static let controlSize: CGFloat = 44

    let row: ActivityRow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !row.lines.isEmpty {
                ActivityLinesView(lines: row.lines, footer: row.linesFooter)
                    .padding(.top, ActivityLine.spacing)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    if row.scrubber == nil, let progress = row.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .controlSize(.mini)
                            .accessibilityLabel("Progress")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(row.accessibilityLabel)
                // Outside the combined label, so VoiceOver can adjust it.
                if let scrubber = row.scrubber {
                    ScrubberView(scrubber: scrubber)
                }
            }
            Spacer(minLength: 0)
            ForEach(row.controls) { control in
                Button(action: control.action) {
                    Image(systemName: control.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: Self.controlSize, height: Self.controlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(control.label)
                .help(control.label)
            }
            if let menu = row.menu {
                ActivityMenuView(menu: menu)
            }
        }
        .frame(minHeight: Self.controlSize)
    }

    @ViewBuilder private var leading: some View {
        if let image = row.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image(systemName: row.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(row.tint.color)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
        }
    }
}
