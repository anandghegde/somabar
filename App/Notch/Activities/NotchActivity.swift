import AppKit
import NotchKit
import SomabarCore
import SwiftUI

/// The colours an activity may use. Green and red keep their system meaning (microphone or
/// camera in use; recording or sharing) and are used for nothing else; there is no brand colour.
enum ActivityTint: Equatable {
    case primary
    case secondary
    /// A microphone or camera in use.
    case inUse
    /// The screen being shared or recorded.
    case recording

    var color: Color {
        switch self {
        case .primary: .white
        case .secondary: .white.opacity(0.6)
        case .inUse: .green
        case .recording: .red
        }
    }
}

/// What Compact draws: a glyph (or artwork) on the camera's left, SF Mono text on its right.
struct CompactPresentation: Equatable {
    var kind: ActivityKind
    var symbol: String
    var text: String
    var tint: ActivityTint = .primary
    /// A small dot in `tint` before the glyph, the way macOS marks the microphone and camera.
    var showsDot = false
    /// Album artwork or an app icon in place of the glyph.
    var image: NSImage?
    var accessibilityLabel: String
    /// A progress ring in place of the glyph (Transfers); `ringFraction` nil draws it unknown.
    var showsRing = false
    var ringFraction: Double?
}

/// A button in an Expanded row: at least 44 pt square, with a VoiceOver label.
struct ActivityControl: Identifiable {
    var id: String { label }
    var symbol: String
    var label: String
    var action: @MainActor () -> Void
}

/// One live activity listed in Expanded.
struct ActivityRow: Identifiable {
    var id: ActivityKind
    var symbol: String
    var title: String
    var detail: String
    var tint: ActivityTint = .primary
    var image: NSImage?
    /// 0...1 for a static progress bar, redrawn on the activity's own tick.
    var progress: Double?
    var controls: [ActivityControl] = []
    /// A slider in place of `progress` (Now Playing).
    var scrubber: ActivityScrubber?
    /// A pick-from-a-list button after the controls (Now Playing's output).
    var menu: ActivityMenu?
    /// Lines under the row, one per item it sums up (Transfers' downloads), and a last line
    /// for the ones left out ("and 3 more").
    var lines: [ActivityLine] = []
    var linesFooter: String?

    var accessibilityLabel: String {
        detail.isEmpty ? title : "\(title), \(detail)"
    }
}

/// A live activity: how it ranks, and how it looks in Compact and in Expanded.
struct NotchActivity {
    var kind: ActivityKind
    var rank: ActivityRank
    /// Seconds since the reference date; of two equal ranks the older wins Compact.
    var startedAt: Double
    var compact: CompactPresentation
    /// nil for an activity that has its own row in Expanded (the timer) or none.
    var row: ActivityRow?

    var live: LiveActivity {
        LiveActivity(kind: kind, rank: rank, startedAt: startedAt)
    }
}
