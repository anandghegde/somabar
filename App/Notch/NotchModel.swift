import AppKit
import NotchKit
import Observation

/// What the notch views draw. `NotchSurface` owns it and changes it inside animations; the
/// views only read it and call the actions.
@MainActor
@Observable
final class NotchModel {
    /// The state being drawn. Lags the machine while the surface fades out to idle.
    var displayedState: NotchState = .idle
    /// The black shape, in the window's coordinates with the origin at its top left.
    var shapeRect: CGRect = .zero
    /// The camera housing in the same coordinates. Zero-width on a drawn notch, where there is
    /// no camera to keep clear and the gap between the two sides is the centre line.
    var cameraRect: CGRect = .zero
    var opacity: Double = 0

    var pulseText = ""
    var pulseSymbol = "bell.fill"
    /// 0...1 for a pulse drawn as a slim bar (the volume HUD); nil for a plain one.
    var pulseLevel: Double?
    /// The live activity that won Compact (`ActivityCenter`); nil when none did.
    var compact: CompactPresentation?
    /// The live activities listed in Expanded, highest priority first. The timer has its own row.
    var activities: [ActivityRow] = []
    /// m:ss while the timer is running or paused; nil when there is none.
    var timerText: String?
    var timerPaused = false

    var profiles: [String] = []
    var activeProfile = ""
    var hiddenIcons: [NSImage] = []
    var hiddenCount = 0

    @ObservationIgnored var actions = NotchActions()
}

/// What a tap in the notch does. Set by `NotchSurface`.
@MainActor
struct NotchActions {
    var click: () -> Void = {}
    var switchProfile: (String) -> Void = { _ in }
    var revealHidden: () -> Void = {}
    var startTimer: (Int) -> Void = { _ in }
    var cancelTimer: () -> Void = {}
    var togglePause: () -> Void = {}
}
