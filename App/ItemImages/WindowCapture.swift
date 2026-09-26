import AppKit
import CoreGraphics
import os
import ScreenCaptureKit
import SomabarCore

/// One-shot screenshots of status item windows through ScreenCaptureKit. No stream is ever
/// started, so the purple indicator only flickers for the moment of a capture, and only when
/// the person turned on a feature that needs it.
@MainActor
enum WindowCapture {
    private static let log = Logger(subsystem: "app.somabar", category: "icons")

    /// An image per window that could be captured, sized in points. Hidden items' windows sit
    /// off screen; they are captured too, and the caller treats a blank result as a failure.
    ///
    /// Callers check `ScreenRecordingPermission` first; this checks again, because asking
    /// ScreenCaptureKit without the permission would put up the system prompt.
    static func images(of windowIDs: Set<CGWindowID>) async -> [CGWindowID: CGImage] {
        guard !windowIDs.isEmpty, CGPreflightScreenCaptureAccess() else { return [:] }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            log.error("Could not list windows to capture: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        var images: [CGWindowID: CGImage] = [:]
        for window in content.windows where windowIDs.contains(window.windowID) {
            let size = window.frame.size
            guard size.width >= 1, size.height >= 1 else { continue }
            let configuration = SCStreamConfiguration()
            configuration.width = Int((size.width * scale).rounded())
            configuration.height = Int((size.height * scale).rounded())
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.captureResolution = .best
            configuration.scalesToFit = false
            configuration.backgroundColor = .clear
            let filter = SCContentFilter(desktopIndependentWindow: window)
            do {
                images[window.windowID] = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            } catch {
                log.info("Could not capture window \(window.windowID): \(error.localizedDescription, privacy: .public)")
            }
        }
        return images
    }

    /// The image squeezed to 16 × 16 as coverage and colourfulness planes; nil when it cannot be
    /// drawn.
    static func fingerprint(of image: CGImage) -> IconFingerprint? {
        let side = IconFingerprint.side
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var coverage = [UInt8](repeating: 0, count: side * side)
        var colour = [UInt8](repeating: 0, count: side * side)
        for index in 0..<(side * side) {
            let red = pixels[index * 4], green = pixels[index * 4 + 1], blue = pixels[index * 4 + 2]
            coverage[index] = pixels[index * 4 + 3]
            // Premultiplied, so the spread is already weighted by coverage.
            colour[index] = max(red, green, blue) - min(red, green, blue)
        }
        return IconFingerprint(bytes: coverage + colour)
    }
}
