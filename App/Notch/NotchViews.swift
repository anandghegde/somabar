import NotchKit
import SwiftUI

/// The whole canvas: transparent except for the black shape.
struct NotchRootView: View {
    let model: NotchModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.displayedState != .idle {
                NotchShapeView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(model.opacity)
    }
}

/// The black shape at `shapeRect`, flat on top and rounded below, holding the state's content.
struct NotchShapeView: View {
    let model: NotchModel

    private var rect: CGRect { model.shapeRect }

    private var cornerRadius: CGFloat {
        model.displayedState == .expanded ? 18 : min(10, rect.height / 3)
    }

    var body: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius, style: .continuous)
            .fill(.black)
            .overlay(alignment: .topLeading) {
                content
                    .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                    .clipped()
            }
            .frame(width: rect.width, height: rect.height)
            .contentShape(Rectangle())
            .onTapGesture { model.actions.click() }
            .offset(x: rect.minX, y: rect.minY)
            .foregroundStyle(.white)
    }

    @ViewBuilder private var content: some View {
        switch model.displayedState {
        case .idle:
            EmptyView()
        case .compact:
            if let compact = model.compact {
                // Keyed by kind, so a new winner cross-fades in.
                CompactActivityView(model: model, compact: compact)
                    .id(compact.kind)
                    .transition(.opacity)
            } else {
                legacyTimer
            }
        case .pulse:
            PulseView(model: model)
                .transition(.opacity)
        case .expanded:
            ExpandedView(model: model)
                .transition(.opacity)
        }
    }

    /// The timer on its own, before `ActivityCenter` has run.
    private var legacyTimer: some View {
        CameraSplitView(model: model) {
            Image(systemName: model.timerPaused ? "pause.circle" : "timer")
                .foregroundStyle(model.timerPaused ? ActivityTint.secondary.color : .white)
        } right: {
            Text(model.timerText ?? "")
                .monospacedDigit()
        }
        .transition(.opacity)
    }
}

/// Two views, one on each side of the camera. On a drawn notch the camera is the centre line.
struct CameraSplitView<Left: View, Right: View>: View {
    let model: NotchModel
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right

    var body: some View {
        let shape = model.shapeRect
        let camera = model.cameraRect
        let leftWidth = max(0, camera.minX - shape.minX)
        let rightWidth = max(0, shape.maxX - camera.maxX)
        let height = min(shape.height, max(camera.height, 1))
        HStack(spacing: 0) {
            left.frame(width: leftWidth, height: height)
            Spacer(minLength: 0)
            right.frame(width: rightWidth, height: height)
        }
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
    }
}

/// A one-off event. Beside a real camera the text sits on its right; on a drawn notch it runs
/// across the middle.
struct PulseView: View {
    let model: NotchModel

    var body: some View {
        if model.cameraRect.width > 0 {
            CameraSplitView(model: model) {
                Image(systemName: model.pulseSymbol)
            } right: {
                Text(model.pulseText)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 4)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: model.pulseSymbol)
                Text(model.pulseText)
                    .minimumScaleFactor(0.7)
            }
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(width: model.shapeRect.width, height: model.shapeRect.height)
        }
    }
}

/// The panel: profiles, the timer, and the Hidden items.
struct ExpandedView: View {
    let model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            profileRow
            timerRow
            ForEach(model.activities.prefix(NotchSurface.maxActivityRows)) { row in
                ActivityRowView(row: row)
            }
            hiddenRow
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 18)
        .padding(.top, model.cameraRect.maxY - model.shapeRect.minY + 8)
        .padding(.bottom, 12)
        .frame(width: model.shapeRect.width, alignment: .leading)
    }

    private var profileRow: some View {
        HStack(spacing: 6) {
            label("Profile", systemImage: "person.crop.rectangle.stack")
            ForEach(model.profiles, id: \.self) { name in
                let isActive = name == model.activeProfile
                Button { model.actions.switchProfile(name) } label: {
                    Text(name)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(isActive ? Color.white.opacity(0.25) : Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var timerRow: some View {
        HStack(spacing: 6) {
            label("Timer", systemImage: "timer")
            if let text = model.timerText {
                Text(text)
                    .monospacedDigit()
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.timerPaused ? ActivityTint.secondary.color : .white)
                    .frame(minWidth: 44, alignment: .leading)
                pill(model.timerPaused ? "Resume" : "Pause", action: model.actions.togglePause)
                pill("Cancel", action: model.actions.cancelTimer)
            } else {
                ForEach([5, 25, 50], id: \.self) { minutes in
                    pill("\(minutes) min") { model.actions.startTimer(minutes) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var hiddenRow: some View {
        Button { model.actions.revealHidden() } label: {
            HStack(spacing: 6) {
                label("Hidden items", systemImage: "eye.slash")
                if model.hiddenIcons.isEmpty {
                    Text(model.hiddenCount == 0 ? "None" : "\(model.hiddenCount)")
                        .foregroundStyle(.white.opacity(0.6))
                }
                ForEach(Array(model.hiddenIcons.prefix(12).enumerated()), id: \.offset) { _, icon in
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.white.opacity(0.6))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func label(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(.white.opacity(0.6))
            .frame(width: 104, alignment: .leading)
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}
