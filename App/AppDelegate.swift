import AppKit
import os

@main
enum SomabarMain {
    static func main() {
        // The process starts on the main thread, which is the main actor.
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
            withExtendedLifetime(delegate) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: SomabarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would each install a glyph and dividers, and learn the other's as items.
        if let other = Self.otherRunningCopy() {
            let pid = other.processIdentifier
            Logger(subsystem: "app.somabar", category: "Controller").error("Somabar is already running as pid \(pid); this copy is quitting")
            FileHandle.standardError.write(Data("Somabar is already running (pid \(pid)).\n".utf8))
            NSApp.terminate(nil)
            return
        }
        let controller = SomabarController()
        self.controller = controller
        controller.start()
    }

    /// Another Somabar with this bundle identifier, however it was launched.
    static func otherRunningCopy() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { $0.processIdentifier != me }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // M19, fail visible: every item is back in view before the process ends.
        controller?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            // Agent reports come often and are not commands, so they skip the URL log.
            if url.host()?.lowercased() == "agent" {
                controller?.handleAgentURL(url)
            } else {
                controller?.handle(url)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showItems()
        return false
    }
}
